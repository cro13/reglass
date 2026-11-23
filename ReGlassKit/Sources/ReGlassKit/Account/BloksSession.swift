import Foundation

/// Runs one Meta "Bloks" login conversation: fetch a screen bundle, interpret its scripts, keep the screen stack
/// and script state, service asynchronous actions, and report a terminal outcome.
///
/// Everything here runs on the main actor — the interpreter and its view tree are plain reference types touched
/// only from here, and screens are consumed on the main actor — so there is no separate serial queue. The only
/// off-actor work is the HTTPS request inside each `BloksClient` call.
@MainActor
final class BloksSession {
    enum Outcome { case code(String); case token(String); case failed(String); case cancelled }

    var onScreen: ((MetaSignIn.Screen) -> Void)?
    var onOutcome: ((Outcome) -> Void)?

    let client: BloksClient
    let deviceID: String
    let interpreter = Interpreter()

    var screens: [Screen] = []
    var globals: [String: Any] = [:]
    let sessionStore = BloksMap()
    let prefs = BloksMap()
    var dialog: BloksDialog?
    var focus: BloksNode?
    var dismissCount = 0
    var message: String?
    var timers: [String: BloksTimer] = [:]
    var animations: [String: BloksAnimation] = [:]
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var delayed: [UUID: Task<Void, Never>] = [:]
    var done = false
    private var started = false
    /// Numbers each pushed screen, so the app can tell a new screen from an update and forward from back.
    private var screenSerial = 0
    /// Meta component types the last render couldn't draw, for the shape log.
    private var lastUndrawn: Set<Int> = []
    /// The last shape line logged, so each screen's shape is logged once rather than on every keystroke.
    private var loggedShape: String?

    init(client: BloksClient, deviceID: String) {
        self.client = client
        self.deviceID = deviceID
    }

    func start(next: String) {
        apply {
            guard !self.started else { return }
            self.started = true
            let first = BloksMap([
                ("logging_session_id", UUID().uuidString), ("logging_user_intent", "meta_ai"),
                ("spi_profile_pic_url", nil), ("spi_frl_email", nil), ("spi_name", nil), ("id_for_aymh", nil),
                ("should_show_explicit_oxygen_preload_tos", false), ("waterfall_id", UUID().uuidString), ("next", next),
            ])
            let params = try BloksJson.encode(first)
            self.request(.action(Self.rootAppID, params), then: { try self.runAction($0, nil, nil) })
        }
    }

    func invoke(_ event: BloksEvent) { apply { _ = try self.interpreter.call(event.handler, event.args) } }

    func setText(_ input: BloksInput, _ text: String, revision: UInt64) {
        apply {
            guard let screen = self.screens.last, input.enabled else { return }
            guard input.keyboard != "password" else { throw BloksError("Password login is not supported by this email-code flow.") }
            guard revision >= screen.editRevisions[ObjectIdentifier(input.node), default: 0] else { return }
            screen.editRevisions[ObjectIdentifier(input.node)] = revision
            let value = input.maxLength > 0 ? String(text.prefix(input.maxLength)) : String(text.prefix(4096))
            screen.texts[ObjectIdentifier(input.node)] = value
            if let change = input.onChange { _ = try self.interpreter.call(change.handler, change.args) }
        }
    }

    func dismissDialog() { apply { self.dialog = nil } }

    func chooseDialog(_ index: Int) {
        apply {
            let button = self.dialog?.buttons.indices.contains(index) == true ? self.dialog?.buttons[index] : nil
            self.dialog = nil
            if let handler = button?.handler { _ = try self.interpreter.call(handler) }
        }
    }

    func back() {
        apply {
            if self.dialog != nil { self.dialog = nil }
            else if let override = self.screens.last?.backOverride { _ = try self.interpreter.call(override, [self.screens.last]) }
            else { try self.pop() }
        }
    }

    func close() {
        guard !done else { return }
        done = true
        clear()
        onScreen = nil
        onOutcome = nil
    }

    // MARK: Turn handling

    /// One main-actor turn: run `block`, then publish the new screen, or fail the whole flow on a thrown error.
    func apply(_ block: () throws -> Void) {
        guard !done else { return }
        do {
            try block()
            if !done { try publish() }
        } catch {
            fail(error)
        }
    }

    /// Runs `block` after a delay, as its own cancellable turn.
    func later(_ millis: Int, _ block: @escaping @MainActor () throws -> Void) {
        guard delayed.count < 64 else { fail(BloksError("Callback queue limit")); return }
        let id = UUID()
        let delay = min(3_600_000, max(1, millis))
        delayed[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.delayed[id] = nil
            self.apply { try block() }
        }
    }

    enum Call {
        case action(String, String), screen(String, String), component(String, String)

        /// The kind and Meta's screen id (a fixed name such as `com.bloks.www…`), never the parameters.
        var logName: String {
            switch self {
            case .action(let appId, _): return "action " + BloksSession.loggable(appId)
            case .screen(let appId, _): return "screen " + BloksSession.loggable(appId)
            case .component(let appId, _): return "component " + BloksSession.loggable(appId)
            }
        }
    }

    /// Meta's screen ids are fixed dotted names; anything else is not logged.
    nonisolated static func loggable(_ appId: String) -> String {
        let plain = appId.count <= 160 && appId.hasPrefix("com.bloks.")
            && appId.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }
        return plain ? appId : "(unnamed)"
    }

    /// Issues one Bloks request. `then` runs on success, `failed` (if given) when the request errors; without a
    /// `failed`, an error fails the flow. Cancellation drops the callback silently.
    func request(_ call: Call,
                 then: @escaping @MainActor (BloksPayload) throws -> Void,
                 failed: (@MainActor () throws -> Void)? = nil) {
        guard !done, requests.count < 8 else { fail(BloksError("Too many login requests")); return }
        let id = UUID()
        kitLog("account", "sign-in request: \(call.logName)")
        let client = self.client
        requests[id] = Task { [weak self] in
            do {
                let bundle: String
                switch call {
                case .action(let appId, let params): bundle = try await client.action(appId, params)
                case .screen(let appId, let params): bundle = try await client.screen(appId, params)
                case .component(let appId, let params): bundle = try await client.component(appId, params)
                }
                try Task.checkCancellation()
                let payload = try BloksPayload.parse(bundle)
                guard let self else { return }
                self.apply {
                    self.requests[id] = nil
                    kitLog("account", "sign-in response received")
                    try then(payload)
                }
            } catch {
                guard let self else { return }
                self.apply {
                    self.requests[id] = nil
                    if error is CancellationError { return }
                    kitLog("account", "sign-in request failed (private details withheld)")
                    if let failed { try failed() } else { throw error }
                }
            }
        }
    }

    func fail(_ error: Error) {
        let technical: String
        if let error = error as? BloksError { technical = error.message }
        else if let error = error as? URLError { technical = "network error \(error.code.rawValue)" }
        else { technical = String(describing: type(of: error)) }
        kitLog("account", "sign-in stopped (\(technical))")
        let reason = error is URLError
            ? "Can’t reach Meta. Check your connection and try again."
            : "Meta sign-in couldn’t be completed. Try again."
        finish(.failed(reason))
    }

    func finish(_ outcome: Outcome) {
        guard !done else { return }
        done = true
        let callback = onOutcome
        clear()
        onOutcome = nil
        onScreen = nil
        callback?(outcome)
    }

    private func clear() {
        for task in requests.values { task.cancel() }
        requests.removeAll()
        for timer in timers.values { timer.task?.cancel() }
        timers.removeAll()
        for task in delayed.values { task.cancel() }
        delayed.removeAll()
        // Break cycles, and drop typed emails/codes and transient server state.
        for screen in screens { screen.clear() }
        screens.removeAll()
        globals.removeAll()
        sessionStore.pairs.removeAll()
        prefs.pairs.removeAll()
        animations.removeAll()
        dialog = nil
        focus = nil
        message = nil
    }

    private func publish() throws {
        let ui = try render()
        guard !done else { return }
        let flat = Flat.of(ui)
        let top = screens.last
        let content = MetaSignIn.Screen.content(of: flat, appId: top?.appId)
        let screen = MetaSignIn.Screen(
            id: MetaSignIn.ScreenID(serial: top?.serial ?? 0),
            kind: content.kind,
            items: content.items,
            back: flat.back.map(MetaSignIn.Action.init),
            canGoBack: screens.count > 0,
            isBusy: !requests.isEmpty,
            isLoading: flat.loading,
            dialog: dialog.map(Self.publicDialog),
            message: message.map { SignInCopy.display($0) },
            focusedField: focus.map { MetaSignIn.FieldID(node: ObjectIdentifier($0)) },
            keyboardDismissals: dismissCount
        )
        logShape(screen, flat)
        onScreen?(screen)
    }

    /// Logs the screen's shape (counts only, see `shapeDescription`) when it differs from the last one logged.
    private func logShape(_ screen: MetaSignIn.Screen, _ flat: BloksScreen) {
        let line = screen.shapeDescription(flat: flat, undrawn: lastUndrawn)
        let key = "\(screen.id.serial) \(line)"
        guard key != loggedShape else { return }
        loggedShape = key
        kitLog("account", line)
    }

    /// Formats the dialog for display while preserving legal and policy wording.
    private static func publicDialog(_ dialog: BloksDialog) -> MetaSignIn.Dialog {
        let legal = SignInCopy.isLegal((dialog.title ?? "") + " " + (dialog.message ?? ""))
        return MetaSignIn.Dialog(title: dialog.title.map { SignInCopy.display($0, legal: legal) },
                                 message: dialog.message.map { SignInCopy.display($0, legal: legal) },
                                 buttons: dialog.buttons.enumerated().map { .init(label: SignInCopy.display($1.label, legal: legal), index: $0) })
    }

    private func render() throws -> BloksUi? {
        lastUndrawn = []
        guard let screen = screens.last, let tree = screen.payload.tree else { return nil }
        var ui: BloksUi?
        for _ in 0..<4 {
            let builder = UiBuilder(interpreter: interpreter, screen: screen, dark: true, text: { self.text(screen, $0) })
            ui = try builder.build(tree, screen)
            lastUndrawn = builder.undrawn
            if done { return nil }
            if screens.last !== screen { return try render() }
            if !builder.ranLifecycle { break }
        }
        if let title = screen.title, let content = ui {
            return .box([.text([BloksSpan(text: title, size: 22)], nil), content], nil, true, false, false)
        }
        return ui
    }

    // MARK: Screen stack

    @MainActor
    final class Screen: BloksContext {
        unowned let session: BloksSession
        let appId: String
        let payload: BloksPayload
        let params: BloksMap
        /// Order of opening within the session (see `MetaSignIn.ScreenID`).
        let serial: Int
        var vars: [String: Any] = [:]
        var globalKeys: [String: String] = [:]
        var texts: [ObjectIdentifier: String] = [:]
        var started: Set<String> = []
        var editRevisions: [ObjectIdentifier: UInt64] = [:]
        var instances: [String: Nested] = [:]
        var replaced: [String: [Any?]] = [:]
        var children: [ObjectIdentifier: [Any?]] = [:]
        var attrs: [ObjectIdentifier: [Int: Any]] = [:]
        var title: String?
        var onClose: BloksLambda?
        var backOverride: BloksLambda?
        var name: String?
        var values: [String: Any] = [:]

        init(_ session: BloksSession, _ appId: String, _ payload: BloksPayload, _ params: BloksMap, serial: Int) {
            self.session = session; self.appId = appId; self.payload = payload; self.params = params; self.serial = serial
        }

        func script(_ id: String) throws -> BloksLambda {
            guard let script = payload.scripts[id] else { throw BloksError("Missing screen script") }
            return BloksLambda(try script.expr(), [], self)
        }
        func extensionCall(_ interpreter: Interpreter, _ name: String, _ args: [Any?]) throws -> Any? {
            try session.action(self, self, name, args)
        }
        func childrenOf(_ n: BloksNode) -> [Any?] {
            children[ObjectIdentifier(n)] ?? n[33].flatMap { replaced[bstr($0)] } ?? blist(n[BloksSession.primaryChildren(n.type)])
        }
        func clear() {
            vars.removeAll(); texts.removeAll(); editRevisions.removeAll(); instances.removeAll(); replaced.removeAll()
            children.removeAll(); attrs.removeAll(); values.removeAll(); onClose = nil; backOverride = nil
        }
    }

    @MainActor
    final class Nested: BloksContext {
        unowned let session: BloksSession
        let payload: BloksPayload
        weak var screen: Screen?
        let parent: BloksContext?
        var templateArgs: BloksMap
        let clientParams: BloksMap

        init(_ session: BloksSession, _ payload: BloksPayload, _ screen: Screen?, _ parent: BloksContext?,
             _ templateArgs: BloksMap = BloksMap(), _ clientParams: BloksMap = BloksMap()) {
            self.session = session; self.payload = payload; self.screen = screen; self.parent = parent
            self.templateArgs = templateArgs; self.clientParams = clientParams
        }
        func script(_ id: String) throws -> BloksLambda {
            if let script = payload.scripts[id] { return BloksLambda(try script.expr(), [], self) }
            guard let parent else { throw BloksError("Missing nested script") }
            return try parent.script(id)
        }
        func extensionCall(_ interpreter: Interpreter, _ name: String, _ args: [Any?]) throws -> Any? {
            try session.action(screen, self, name, args)
        }
        func templateArg(_ name: String) -> Any? { templateArgs.get(name) ?? (parent as? Nested)?.templateArg(name) }
        func clientParam(_ name: String) -> Any? { clientParams.get(name) ?? (parent as? Nested)?.clientParam(name) }
    }

    final class Instance {
        let payload: BloksPayload
        let ctx: BloksContext
        init(_ payload: BloksPayload, _ ctx: BloksContext) { self.payload = payload; self.ctx = ctx }
    }

    func declare(_ payload: BloksPayload, _ ctx: BloksContext) throws {
        guard let screen = (ctx as? Screen) ?? (ctx as? Nested)?.screen else { return }
        for variable in payload.variables {
            if variable.type == "gs", let key = variable.key {
                screen.globalKeys[variable.id] = key
                if variable.mode == "p" || globals[key] == nil { globals[key] = variable.initial ?? NSNull() }
            } else if screen.vars[variable.id] == nil {
                screen.vars[variable.id] = try variable.initialScript.map { try interpreter.run($0.expr(), ctx) } ?? variable.initial ?? NSNull()
            }
        }
    }

    func variable(_ screen: Screen?, _ id: String) -> Any? {
        guard let screen else { return nil }
        let value = screen.globalKeys[id].map { globals[$0] } ?? screen.vars[id]
        return value is NSNull ? nil : value
    }

    func push(_ appId: String, _ payload: BloksPayload, _ params: BloksMap) throws {
        guard screens.count < 32 else { throw BloksError("Login screen limit") }
        screenSerial += 1
        let screen = Screen(self, appId, payload, params, serial: screenSerial)
        screens.append(screen)
        try declare(payload, screen)
        kitLog("account", "sign-in screen opened (depth \(screens.count)): \(Self.loggable(appId))")
        if let action = payload.action { _ = try interpreter.run(action.expr(), screen, [screen]) }
        try fetchComponents(payload, screen, screen)
    }

    func pop() throws {
        guard let screen = screens.popLast() else { finish(.cancelled); return }
        for (id, timer) in timers where timer.screen === screen { timer.task?.cancel(); timers.removeValue(forKey: id) }
        if let onClose = screen.onClose { _ = try interpreter.call(onClose) }
        screen.clear()
        if screens.isEmpty { finish(.cancelled) }
    }

    func fetchComponents(_ payload: BloksPayload, _ screen: Screen, _ ctx: BloksContext) throws {
        for query in payload.componentQueries {
            guard let target = query.target, let appScript = query.appId,
                  let appId = try interpreter.run(appScript.expr(), ctx) as? String else { continue }
            let params = try query.params.map { try interpreter.run($0.expr(), ctx) } as? BloksMap ?? BloksMap()
            let clientParams = try query.clientParams.map { try interpreter.run($0.expr(), ctx) } as? BloksMap ?? BloksMap()
            let sent = try BloksJson.encode(BloksMap([("params", params)]))
            request(.component(appId, sent), then: { answer in
                guard self.screens.contains(where: { $0 === screen }) else { return }
                let nested = Nested(self, answer, screen, ctx, BloksMap(), clientParams)
                try self.declare(answer, nested)
                screen.replaced[target] = [Instance(answer, nested)]
                if let action = answer.action { _ = try self.interpreter.run(action.expr(), nested, [screen]) }
                try self.fetchComponents(answer, screen, nested)
            })
        }
    }

    func runAction(_ payload: BloksPayload, _ screen: Screen?, _ props: BloksMap?) throws {
        if let screen, !screens.contains(where: { $0 === screen }) { return }
        let ctx = Nested(self, payload, screen, screen)
        try declare(payload, ctx)
        if let screen {
            for (key, value) in props?.pairs ?? [] { let name = bstr(key); screen.vars[payload.props[name] ?? name] = value ?? NSNull() }
        }
        if let action = payload.action { _ = try interpreter.run(action.expr(), ctx, screen.map { [$0] } ?? []) }
    }

    func text(_ screen: Screen?, _ node: BloksNode) -> String { screen?.texts[ObjectIdentifier(node)] ?? node[50] as? String ?? "" }

    func find(_ screen: Screen, _ root: BloksNode, _ id: String, parent: Bool = false) -> BloksNode? {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: BloksNode, _ depth: Int) -> BloksNode? {
            guard depth < 128, seen.count < 10_000, seen.insert(ObjectIdentifier(node)).inserted else { return nil }
            if !parent && bstr(node[33]) == id { return node }
            let kids = screen.childrenOf(node)
            if parent && kids.contains(where: { ($0 as? BloksNode)?[33].map(bstr) == id }) { return node }
            for value in kids + node.attrs.values.map({ Optional<Any>($0) }) {
                let list = value is BloksArray ? blist(value) : [value]
                for child in list {
                    if let n = child as? BloksNode, let found = walk(n, depth + 1) { return found }
                    if let inst = child as? Instance, let n = inst.payload.tree, let found = walk(n, depth + 1) { return found }
                }
            }
            return nil
        }
        return walk(root, 0)
    }

    static let rootAppID = "com.bloks.www.meta.access.aymh_with_nta_fallback.async"
    static let machineID = UUID().uuidString
    static func primaryChildren(_ type: Int) -> Int {
        switch type { case 13327: return 35; case 13708: return 41; case 14093, 16675: return 36; case 16444: return 42; default: return 32 }
    }
}

struct BloksDialog {
    struct Button { let label: String; let handler: BloksLambda? }
    let title: String?
    let message: String?
    let buttons: [Button]
}

final class BloksTimer {
    let id: String
    let interval: Int
    let repeats: Bool
    let callback: Any?
    weak var screen: BloksSession.Screen?
    var stopped = false
    var task: Task<Void, Never>?
    init(_ id: String, _ interval: Int, _ repeats: Bool, _ callback: Any?, _ screen: BloksSession.Screen?) {
        self.id = id; self.interval = interval; self.repeats = repeats; self.callback = callback; self.screen = screen
    }
}

final class BloksAnimation {
    var value: Any?
    var to: Any?
    let update: Any?
    var listeners: [Any?]
    let linear: Bool
    var done = false
    var children: [BloksAnimation] = []
    init(_ from: Any?, _ to: Any?, _ update: Any?, _ end: Any?, linear: Bool = false) {
        value = from; self.to = to; self.update = update; listeners = end.map { [$0] } ?? []; self.linear = linear
    }
}
