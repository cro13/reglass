import Foundation

// Flattens Meta's arbitrary Bloks view tree into the short list of native controls ReGlass renders. Server labels,
// account choices, and event handlers are preserved; layout and decoration are dropped. Images are kept only as an
// address and a size: nothing here fetches them. A tappable row keeps the images and texts found anywhere inside it,
// so an account choice can be drawn with its picture whatever shape Meta's row takes.

struct BloksEvent {
    let handler: BloksLambda
    let args: [Any?]
    init(_ handler: BloksLambda, _ args: [Any?]) { self.handler = handler; self.args = args }
}

struct BloksSpan {
    let text: String
    let size: Double?
    let error: Bool
    let event: BloksEvent?
    init(text: String, size: Double? = nil, error: Bool = false, event: BloksEvent? = nil) {
        self.text = text; self.size = size; self.error = error; self.event = event
    }
}

struct BloksInput {
    let node: BloksNode
    let editRevision: UInt64
    let text: String
    let hint: String
    let label: String
    let keyboard: String?
    let secret: Bool
    let maxLength: Int
    let enabled: Bool
    let onChange: BloksEvent?
    let onSubmit: BloksEvent?
    let onFocus: BloksEvent?
    let onBlur: BloksEvent?
}

/// An image in Meta's tree: its address as Meta gave it (any scheme or host; `MetaSignIn` decides what may load) and
/// its laid-out size in points, when Meta states one.
struct BloksImage {
    let url: String?
    let width: Double?
    let height: Double?

    /// A glyph rather than a picture: drawn at icon size, or one of Meta's static resource sprites.
    var isIconLike: Bool {
        if let width, let height, max(width, height) <= 24 { return true }
        return url?.contains("/rsrc.php/") == true
    }
}

indirect enum BloksUi {
    case box([BloksUi], BloksEvent?, Bool, Bool, Bool)
    case text([BloksSpan], BloksEvent?)
    case input(BloksInput)
    case image(BloksImage)
    case spinner
}

/// Something to tap: a button, a tappable line, or a row such as an account choice.
struct BloksAction {
    /// Every distinct text inside, joined: what a plain button shows.
    let label: String
    let event: BloksEvent
    let primary: Bool
    let enabled: Bool
    /// The distinct texts inside, in reading order. A row's first one is its title, the rest its detail.
    let texts: [String]
    /// The visible images inside, in reading order (an avatar, a badge, a chevron).
    let images: [BloksImage]
}

enum BloksItem {
    case heading(String)
    case paragraph(String, Bool, [BloksSpan])
    case field(BloksInput, String)
    case action(BloksAction)
}

struct BloksScreen {
    let back: BloksEvent?
    let items: [BloksItem]
    let loading: Bool
    /// Visible images that are not inside anything tappable (logos, headers). Counted for the shape log only.
    var looseImages = 0
}

@MainActor
final class UiBuilder {
    let interpreter: Interpreter
    let screen: BloksSession.Screen
    let dark: Bool
    let text: (BloksNode) -> String
    var ranLifecycle = false
    /// Component types that drew nothing ReGlass understands (no children, no text, no image). Type numbers only, for
    /// the shape log: they tell which Meta component to support next, and never carry content.
    private(set) var undrawn: Set<Int> = []
    private var nodes = 0

    init(interpreter: Interpreter, screen: BloksSession.Screen, dark: Bool, text: @escaping (BloksNode) -> String) {
        self.interpreter = interpreter; self.screen = screen; self.dark = dark; self.text = text
    }

    func resolve(_ node: BloksNode, _ ctx: BloksContext) throws -> [Int: Any] {
        var out = node.attrs
        let bindings = blist(node[135])
        for i in stride(from: 0, to: max(0, bindings.count - 1), by: 2) {
            if let key = bindings[i] as? String, key.utf16.count == 1, let code = key.utf16.first, let script = bindings[i + 1] as? BloksScript {
                out[Int(code)] = try interpreter.run(script.expr(), ctx) ?? NSNull()
            }
        }
        for (key, value) in screen.attrs[ObjectIdentifier(node)] ?? [:] { out[key] = value }
        return out
    }

    func event(_ value: Any?, _ ctx: BloksContext, _ node: BloksNode) throws -> BloksEvent? {
        if let script = value as? BloksScript { return BloksEvent(BloksLambda(try script.expr(), [], ctx), [node, screen]) }
        if let lambda = value as? BloksLambda { return BloksEvent(lambda, [node, screen]) }
        return nil
    }

    private func lifecycle(_ node: BloksNode, _ a: [Int: Any], _ ctx: BloksContext) throws {
        for ext in blist(a[133]).compactMap({ $0 as? BloksNode }) {
            let scripts: [Any?]
            switch ext.type {
            case 13914: scripts = [ext[41], ext[42]]
            case 16529: scripts = [ext[35]]
            default: continue
            }
            let key = "\(ObjectIdentifier(ext)):\(ObjectIdentifier(ctx))"
            guard screen.started.insert(key).inserted else { continue }
            for script in scripts {
                if let e = try event(script, ctx, node) { _ = try interpreter.call(e.handler, e.args); ranLifecycle = true }
            }
        }
    }

    func build(_ node: BloksNode, _ ctx: BloksContext, _ depth: Int = 0) throws -> BloksUi? {
        nodes += 1
        guard depth < 128, nodes < 20_000 else { throw BloksError("Login render limit") }
        let a = try resolve(node, ctx)
        try lifecycle(node, a, ctx)
        if a[49] as? String == "gone" { return nil }
        func value(_ key: Int) -> Any? { let v = a[key]; return v is NSNull ? nil : v }
        func child(_ v: Any?) throws -> BloksUi? {
            if let n = v as? BloksNode { return try build(n, ctx, depth + 1) }
            if let inst = v as? BloksSession.Instance, let n = inst.payload.tree { return try build(n, inst.ctx, depth + 1) }
            if let array = v as? BloksArray, let first = array.items.first { return try child(first) }
            return nil
        }
        func children(_ supplied: Any?) throws -> [BloksUi] {
            let list = screen.children[ObjectIdentifier(node)] ?? node[33].flatMap { screen.replaced[bstr($0)] } ?? (supplied is BloksArray ? blist(supplied) : supplied.map { [$0] } ?? [])
            return try list.flatMap { value -> [Any?] in if let n = value as? BloksNode, n.type == 13346 { return blist(n[32]) }; return [value] }.compactMap(child)
        }
        let hidden = value(49) as? String == "invisible" || (value(141) as? NSNumber)?.doubleValue ?? 1 < 0.05
        switch node.type {
        case 14093: return .box(try [child(value(40)), child(value(36))].compactMap { $0 }, nil, true, false, hidden)
        case 16675: return try child(value(36))
        case 13320:
            let deco = value(38) as? BloksNode, filled = deco?.type == 13314 && deco?[35] != nil
            return .box(try children(value(32)), try event(value(45), ctx, node), !isFalse(value(40)), filled, hidden)
        case 13317: return .box(try children(value(32)), nil, true, false, hidden)
        case 13329: return hidden ? nil : .text(try spans(node, a, ctx), try event(value(41), ctx, node))
        case 13335:
            let color = (value(48) as? BloksNode).flatMap(color) ?? hex(value(43))
            let span = BloksSpan(text: value(41).map(bstr) ?? "", size: Self.dim(value(45)), error: Self.reddish(color))
            return hidden ? nil : .text([span], try event(value(40), ctx, node))
        case 13336:
            let keyboard = value(56) as? String, label = try label(a, ctx), hint = value(36).map(bstr) ?? ""
            // A masked numeric passcode is an OTP, not a password. Never render an actual password field.
            if keyboard == "password" || (label + " " + hint).lowercased().contains("password") {
                throw BloksError("Meta requested a password. This implementation supports account selection and email codes only.")
            }
            return .input(BloksInput(
                node: node,
                editRevision: screen.editRevisions[ObjectIdentifier(node), default: 0],
                text: text(node),
                hint: hint,
                label: label,
                keyboard: keyboard,
                secret: Interpreter.truthy(value(99)) || keyboard == "passcode",
                maxLength: (value(40) as? NSNumber)?.intValue ?? -1,
                enabled: !isFalse(value(74)),
                onChange: try event(value(48), ctx, node),
                onSubmit: try event(value(46), ctx, node),
                onFocus: try event(value(42), ctx, node),
                onBlur: try event(value(45), ctx, node)
            ))
        case 23990, 15728: return hidden ? nil : .spinner
        case 13323: return hidden ? nil : .image(image(a, value))   // address only: never fetched here
        case 15778: return nil // A decorative loading skeleton.
        default:
            let kids = try children(value(32))
            if !kids.isEmpty { return .box(kids, nil, true, false, hidden) }
            // An image component ReGlass doesn't know by number still shows itself by a Meta CDN address.
            if !hidden, let url = Self.addresses(in: a).first(where: Self.isCDNAddress) {
                return .image(BloksImage(url: url, width: nil, height: nil))
            }
            if undrawn.count < 32 { undrawn.insert(node.type) }
            return nil
        }
    }

    /// An image's address is in field 41, with a dark-mode variant in field 36. Fall back to another web address
    /// on the node so a renumbered attribute can still supply the image.
    private func image(_ a: [Int: Any], _ value: (Int) -> Any?) -> BloksImage {
        let preferred = (dark ? [36, 41] : [41, 36]).compactMap { Self.address(value($0)) }.first
        let style = value(132) as? BloksNode
        return BloksImage(url: preferred ?? Self.addresses(in: a).first, width: Self.dim(style?[68]), height: Self.dim(style?[42]))
    }

    /// A web address held directly, or in a `{uri|url|src: …}` map.
    private static func address(_ v: Any?) -> String? {
        if let string = v as? String {
            let lower = string.prefix(8).lowercased()
            return lower.hasPrefix("https://") || lower.hasPrefix("http://") ? string : nil
        }
        if let map = v as? BloksMap {
            for key in ["uri", "url", "src"] { if let found = address(map.get(key)) { return found } }
        }
        return nil
    }

    /// Every web address among a node's own attributes, in attribute order.
    private static func addresses(in a: [Int: Any]) -> [String] {
        a.keys.sorted().compactMap { address(a[$0]) }
    }

    /// Meta's media CDNs, which only ever serve pictures.
    private static func isCDNAddress(_ string: String) -> Bool {
        guard let host = URL(string: string)?.host?.lowercased() else { return false }
        return ["fbcdn.net", "cdninstagram.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private func isFalse(_ v: Any?) -> Bool { Interpreter.isBool(v) && !Interpreter.truthy(v) }

    private func label(_ a: [Int: Any], _ ctx: BloksContext) throws -> String {
        let extensions = blist(a[133]).compactMap { $0 as? BloksNode }
        let node = extensions.first { $0.type == 14001 } ?? extensions.first { $0.type == 13313 }
        guard let node else { return "" }
        let na = try resolve(node, ctx)
        return (na[node.type == 14001 ? 35 : 36] ?? na[50]).map(bstr)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",")) ?? ""
    }

    private func spans(_ node: BloksNode, _ a: [Int: Any], _ ctx: BloksContext) throws -> [BloksSpan] {
        var out: [BloksSpan] = []
        var count = 0
        func add(_ v: Any?, _ inherited: [BloksNode], _ depth: Int) throws {
            guard let n = v as? BloksNode else { return }
            count += 1
            guard depth < 64, count < 10_000 else { throw BloksError("Rich text limit") }
            let na = try resolve(n, ctx)
            if n.type == 16887 { for value in blist(na[36]) { try add(value, inherited + blist(na[38]).compactMap { $0 as? BloksNode }, depth + 1) }; return }
            if n.type == 16880 {
                let styles = try (inherited + blist(na[36]).compactMap { $0 as? BloksNode }).map { BloksNode($0.type, try resolve($0, ctx)) }
                let font = styles.last { $0.type == 16870 }, c = styles.last { $0.type == 16875 }?[35] as? BloksNode, link = styles.last { $0.type == 16873 }
                out.append(BloksSpan(text: na[38].map(bstr) ?? "", size: Self.dim(font?[41]), error: Self.reddish(c.flatMap(color)), event: try event(link?[36], ctx, node)))
            } else if n.type == 13339 {
                out.append(BloksSpan(text: na[38].map(bstr) ?? "", size: Self.dim(na[42]), error: Self.reddish((na[44] as? BloksNode).flatMap(color)), event: try event(na[36], ctx, node)))
            }
        }
        for value in blist(Interpreter.truthy(a[68]) ? a[69] : a[32]) { try add(value, [], 0) }
        return out.filter { !$0.text.isEmpty }
    }

    private func color(_ n: BloksNode) -> UInt32? { hex(dark ? n[35] ?? n[36] : n[36] ?? n[35]) }
    private func hex(_ v: Any?) -> UInt32? {
        guard let string = v as? String else { return nil }
        let raw = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard let color = UInt32(raw, radix: 16) else { return nil }
        return raw.count == 6 ? 0xff000000 | color : raw.count == 8 ? color : nil
    }
    private static func reddish(_ color: UInt32?) -> Bool { guard let c = color else { return false }; return (c >> 16) & 255 > 180 && (c >> 8) & 255 < 110 && c & 255 < 110 }
    static func dim(_ v: Any?) -> Double? {
        if let number = v as? NSNumber { return number.doubleValue }
        guard let string = v as? String else { return nil }
        if string.hasSuffix("px") { return Double(string.dropLast(2)).map { $0 / 3 } }
        if string.hasSuffix("dp") || string.hasSuffix("sp") { return Double(string.dropLast(2)) }
        return Double(string)
    }
}

enum Flat {
    static func of(_ ui: BloksUi?) -> BloksScreen {
        var items: [BloksItem] = []
        var back: BloksEvent?
        var primaryTaken = false
        var spinners = 0
        var looseImages = 0
        func words(_ u: BloksUi) -> [String] {
            switch u {
            case .text(let spans, _): let s = spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines); return s.isEmpty ? [] : [s]
            case .box(let kids, _, _, _, let invisible): return invisible ? [] : kids.flatMap(words)
            default: return []
            }
        }
        func inputs(_ u: BloksUi) -> [BloksInput] {
            switch u {
            case .input(let input): return [input]
            case .box(let kids, _, _, _, _): return kids.flatMap(inputs)
            default: return []
            }
        }
        func images(_ u: BloksUi) -> [BloksImage] {
            switch u {
            case .image(let image): return [image]
            case .box(let kids, _, _, _, let invisible): return invisible ? [] : kids.flatMap(images)
            default: return []
            }
        }
        func filled(_ u: BloksUi) -> Bool { if case .box(let kids, _, _, let fill, _) = u { return fill || kids.contains(where: filled) }; return false }
        func walk(_ u: BloksUi) {
            switch u {
            case .box(let kids, let click, let enabled, _, let invisible):
                let fields = inputs(u)
                if invisible && fields.isEmpty { return }
                if let click {
                    let labels = words(u)
                    if !fields.isEmpty { for f in fields { items.append(.field(f, f.label.isEmpty ? labels.first ?? "" : f.label)) }; return }
                    if !labels.isEmpty && labels.allSatisfy({ $0.count <= 1 }) { return }
                    var seen = Set<String>()
                    let distinct = labels.filter { seen.insert($0).inserted }
                    let label = distinct.joined(separator: " ")
                    if label.isEmpty { if back == nil && items.isEmpty { back = click } }
                    else {
                        let primary = filled(u) && !primaryTaken
                        if primary { primaryTaken = true }
                        items.append(.action(BloksAction(label: label, event: click, primary: primary, enabled: enabled,
                                                         texts: distinct, images: images(u))))
                    }
                    return
                }
                kids.forEach(walk)
            case .text(let spans, let click):
                let label = spans.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { return }
                let event = click ?? (spans.count == 1 ? spans.first?.event : nil)
                if let event { items.append(.action(BloksAction(label: label, event: event, primary: false, enabled: true, texts: [label], images: []))) }
                else if spans.compactMap(\.size).max() ?? 0 >= 20 && !spans.contains(where: \.error) { items.append(.heading(label)) }
                else { items.append(.paragraph(label, spans.contains(where: \.error), spans)) }
            case .input(let f): items.append(.field(f, f.label))
            case .image: looseImages += 1
            case .spinner: spinners += 1
            }
        }
        if let ui { walk(ui) }
        let labels = Set(items.compactMap { item -> String? in if case .field(_, let label) = item { return label.trimmingCharacters(in: .whitespacesAndNewlines) }; return nil })
        var seen = Set<String>()
        items = items.filter { item in
            switch item {
            case .paragraph(let text, _, _): return !labels.contains(text) && seen.insert("p:" + text).inserted
            case .heading(let text): return seen.insert("h:" + text).inserted
            default: return true
            }
        }
        if !items.contains(where: { if case .heading = $0 { return true }; return false }) {
            for i in items.indices {
                if case .field = items[i] { break }
                if case .paragraph(let text, false, _) = items[i] { items[i] = .heading(text); break }
            }
        }
        return BloksScreen(back: back, items: items, loading: items.isEmpty && (spinners > 0 || ui == nil), looseImages: looseImages)
    }
}

// MARK: Mapping to the public screen model

/// Sign-in copy displays ReGlass as the app storing the encrypted login on this iPhone.
/// Legal and policy text retains Meta's original wording.
enum SignInCopy {
    static func isLegal(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["terms", "policy", "policies", "privacy", "cookie", "legal", "consent", "agree"].contains { lower.contains($0) }
    }

    /// `legal` lets a paragraph decide once for all its runs, so a policy link and its sentence stay consistent.
    static func display(_ text: String, legal: Bool? = nil) -> String {
        guard text.range(of: "meta", options: .caseInsensitive) != nil, !(legal ?? isLegal(text)) else { return text }
        return text.replacingOccurrences(of: #"\bMeta\s+AI\b"#, with: "ReGlass", options: [.regularExpression, .caseInsensitive])
    }
}

extension MetaSignIn.Span {
    init(_ span: BloksSpan, legal: Bool) {
        self.init(text: SignInCopy.display(span.text, legal: legal), isError: span.error, action: span.event.map(MetaSignIn.Action.init))
    }
}

extension MetaSignIn.Kind {
    /// What a screen asks for, from what it contains first and Meta's fixed screen name second.
    static func of(appId: String?, loading: Bool, fields: [MetaSignIn.Field], pictured: Bool) -> Self {
        if loading { return .loading }
        let id = appId?.lowercased() ?? ""
        func named(_ words: [String]) -> Bool { words.contains { id.contains($0) } }
        if fields.contains(where: \.isOneTimeCode) || named(["otp", "confirmation_code", "enter_code", "code_entry", "verify_code"]) {
            return .code
        }
        if !fields.isEmpty { return .email }
        if named(["save_login", "save_credential", "save_password", "save_info"]) { return .saveLogin }
        if pictured || named(["account_selector", "account_picker", "choose_account", "select_account", "account_list",
                              "accounts_list", "aymh"]) {
            return .chooseAccount
        }
        return .other
    }

    var logName: String {
        switch self {
        case .loading: return "loading"
        case .email: return "email"
        case .code: return "code"
        case .chooseAccount: return "account choice"
        case .saveLogin: return "save login"
        case .other: return "other"
        }
    }
}

extension MetaSignIn.Button {
    init(_ action: BloksAction, onAccountPicker: Bool) {
        let legal = SignInCopy.isLegal(action.label)
        let pictures = Self.pictures(in: action.images)
        let detail = action.texts.dropFirst().joined(separator: " · ")
        self.init(label: SignInCopy.display(action.label, legal: legal),
                  isPrimary: action.primary,
                  isEnabled: action.enabled,
                  action: .init(event: action.event),
                  title: SignInCopy.display(action.texts.first ?? action.label, legal: legal),
                  subtitle: detail.isEmpty ? nil : SignInCopy.display(detail, legal: legal),
                  imageURLs: pictures,
                  isAccountChoice: !pictures.isEmpty || (onAccountPicker && Self.namesAnAccount(action.label)))
    }

    /// The pictures worth drawing: not icon-size glyphs, and only from Meta's own hosts over HTTPS.
    static func pictures(in images: [BloksImage]) -> [URL] {
        images.filter { !$0.isIconLike }.compactMap { $0.url.flatMap(URL.init(string:)) }.filter(isMetaImageURL)
    }

    /// On the account picker, a row names an account (an email, a username, a name) unless it reads as a command
    /// such as "Log into another account" or "Create new account".
    static func namesAnAccount(_ label: String) -> Bool {
        if label.contains("@") { return true }
        let commands: Set<String> = ["another", "other", "login", "log", "sign", "create", "new", "continue", "cancel", "not",
                                     "use", "switch", "add", "forgot", "remove", "manage", "help", "options", "back", "try",
                                     "resend", "send", "next", "done", "save", "close", "skip", "learn"]
        let words = label.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        return !words.contains(where: commands.contains)
    }
}

extension MetaSignIn.Screen {
    /// The sign-in step and its display items, including account choices as rows.
    static func content(of flat: BloksScreen, appId: String?) -> (kind: MetaSignIn.Kind, items: [MetaSignIn.Item]) {
        var items: [MetaSignIn.Item?] = []
        var actions: [(index: Int, action: BloksAction)] = []   // finished once the kind is known
        for item in flat.items {
            switch item {
            case .heading(let text):
                items.append(.heading(SignInCopy.display(text)))
            case .paragraph(let text, let error, let spans):
                let legal = SignInCopy.isLegal(text)
                items.append(.paragraph(.init(text: SignInCopy.display(text, legal: legal), isError: error,
                                              spans: spans.map { MetaSignIn.Span($0, legal: legal) })))
            case .field(let input, let label):
                items.append(.field(.init(input, label: label)))
            case .action(let action):
                actions.append((items.count, action))
                items.append(nil)
            }
        }
        let fields = items.compactMap { item -> MetaSignIn.Field? in if case .field(let field)? = item { return field }; return nil }
        let pictured = actions.contains { !MetaSignIn.Button.pictures(in: $0.action.images).isEmpty }
        let kind = MetaSignIn.Kind.of(appId: appId, loading: flat.loading && flat.items.isEmpty, fields: fields, pictured: pictured)
        for (index, action) in actions {
            items[index] = .button(MetaSignIn.Button(action, onAccountPicker: kind == .chooseAccount))
        }
        return (kind, items.compactMap { $0 })
    }

    /// One privacy-safe line describing the screen's shape: counts, the kind, and Meta's component type numbers.
    /// Never text, names, emails, usernames or addresses. If pictures don't show, this says where they went.
    func shapeDescription(flat: BloksScreen, undrawn: Set<Int>) -> String {
        var headings = 0, paragraphs = 0, fields = 0, buttons = 0, rows = 0, pictured = 0, detailed = 0
        for item in items {
            switch item {
            case .heading: headings += 1
            case .paragraph: paragraphs += 1
            case .field: fields += 1
            case .button(let button):
                if button.isAccountChoice {
                    rows += 1
                    if button.avatarURL != nil { pictured += 1 }
                    if button.subtitle != nil { detailed += 1 }
                } else {
                    buttons += 1
                }
            }
        }
        var inRows = 0, cdn = 0, otherHost = 0, insecure = 0, noAddress = 0, iconSize = 0
        for case .action(let action) in flat.items {
            for image in action.images {
                inRows += 1
                if image.isIconLike { iconSize += 1 }
                guard let raw = image.url, let url = URL(string: raw) else { noAddress += 1; continue }
                if url.scheme?.lowercased() != "https" { insecure += 1 }
                else if MetaSignIn.Button.isMetaImageURL(url) { cdn += 1 }
                else { otherHost += 1 }
            }
        }
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        var parts = [count(headings, "heading"), count(paragraphs, "paragraph"), count(fields, "field"), count(buttons, "button"),
                     count(rows, "account row") + " (\(pictured) with picture, \(detailed) with detail)",
                     "images: \(inRows) in tappable items (\(cdn) Meta CDN, \(otherHost) other host, \(insecure) not https, "
                        + "\(noAddress) no address; \(iconSize) icon-size), \(flat.looseImages) elsewhere"]
        if !undrawn.isEmpty { parts.append("undrawn components: " + undrawn.sorted().prefix(16).map(String.init).joined(separator: " ")) }
        return "sign-in screen shape (\(kind.logName)): " + parts.joined(separator: ", ")
    }
}
