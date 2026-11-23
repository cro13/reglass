import Foundation

// MARK: - The choice and the key's status (public: the app shows and changes them)

/// Which recognizer hears the wearer, and whether ElevenLabs can do it right now.
///
/// Apple's on-device recognizer is the default. ElevenLabs Scribe v2 Realtime, chosen in the app, copes far better
/// with accents, names and local places; it uses the ElevenLabs key (the same one as the ElevenLabs voice), which
/// needs the Speech to Text permission. When the key can't transcribe, ReGlass listens on the iPhone until the key
/// changes or a check (`checkKey()`) passes. After a passing failure (network, busy) it rests for a short while.
public enum SpeechRecognition {
    /// What ReGlass knows about the ElevenLabs key and speech to text, since it started.
    public enum CloudStatus: Sendable, Equatable {
        /// Not tried yet.
        case unknown
        case works
        case noKey
        /// ElevenLabs turned the key away for speech to text: it lacks the Speech to Text permission (or isn't valid).
        case keyCannotTranscribe
        /// ElevenLabs wants its speech to text terms accepted once, in its dashboard.
        case termsNotAccepted
        case quotaUsed

        /// Something about the key or the account keeps ReGlass on the iPhone's recognizer.
        public var keepsRecognitionOnIPhone: Bool { self != .unknown && self != .works }
    }

    private static let choiceKey = "reglass.assistant.speechRecognition"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = CloudStatus.unknown
    nonisolated(unsafe) private static var restUntil: Date?
    nonisolated(unsafe) private static var rejections = 0
    nonisolated(unsafe) private static var keytermProvider: (@Sendable () -> [String])?
    nonisolated(unsafe) private static var statusObserver: (@Sendable (CloudStatus) -> Void)?

    /// The owner's choice (Settings → Assistant → Voice and speech): the iPhone unless they chose another recognizer.
    /// Saved by the provider's ID ("iPhone", "elevenLabs", the same values as before providers existed); one no
    /// provider has any more reads as the iPhone.
    public static var choice: SpeechProvider {
        get { UserDefaults.standard.string(forKey: choiceKey).flatMap(SpeechProvider.with(id:)) ?? .iPhone }
        set {
            guard newValue != choice else { return }
            UserDefaults.standard.set(newValue.id, forKey: choiceKey)
            AssistantLog.add("Speech recognition: \(newValue.logName)")
        }
    }

    public static var cloudStatus: CloudStatus { lock.withLock { status } }

    /// Words for ElevenLabs to expect besides the wake phrase and the app's name (local place names). It's called as each
    /// request starts, so it must answer at once from a cached list, never with a lookup.
    public static func setKeytermProvider(_ provider: @escaping @Sendable () -> [String]) {
        lock.withLock { keytermProvider = provider }
    }

    /// Called, on any thread, whenever `cloudStatus` changes.
    public static func setStatusObserver(_ observer: @escaping @Sendable (CloudStatus) -> Void) {
        lock.withLock { statusObserver = observer }
    }

    /// Asks ElevenLabs whether the key can transcribe: opens a session and closes it as soon as it starts, before
    /// any audio is sent (Scribe bills per second of audio). Returns the new status, or nil when the answer was
    /// unclear (no network, the iPhone not unlocked since a restart), in which case the status stays as it was.
    public static func checkKey() async -> CloudStatus? {
        let key: String?
        do {
            key = try KeyStore.shared.read(.elevenLabs)
        } catch {
            return nil
        }
        guard let key else {
            set(.noKey)
            return .noKey
        }
        let watch = Stopwatch()
        let answer = Answer()
        let session = ScribeSession(key: key, options: ScribeSession.Options()) { event in
            switch event {
            case .started, .failed: answer.give(event)
            case .partial, .committed: break
            }
        }
        session.connect()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(6))
            answer.give(nil)
        }
        let event = await answer.value()
        timeout.cancel()
        session.close()
        let result: CloudStatus?
        switch event {
        case .started?: result = .works
        case .failed(.unauthorized)?: result = .keyCannotTranscribe
        case .failed(.termsNotAccepted)?: result = .termsNotAccepted
        case .failed(.quota)?: result = .quotaUsed
        default: result = nil
        }
        let kind: String
        switch event {
        case .failed(let failure)?: kind = failure.kind
        case .started?: kind = "works"
        default: kind = "no answer"
        }
        AssistantLog.add("Speech: ElevenLabs key check: \(kind) after \(watch.elapsed.seconds)")
        if let result {
            if result == .works { clearRest() }
            set(result)
        }
        return result
    }

    /// The ElevenLabs key was saved, replaced or removed: forget what was learnt about the old one.
    public static func keyChanged() {
        lock.withLock {
            restUntil = nil
            rejections = 0
        }
        set(.unknown)
    }

    // MARK: For ScribeEngine

    /// The key, when the next request should try ElevenLabs. Nil (logging why, except when the owner chose the iPhone)
    /// otherwise.
    static func keyForNextRequest() -> String? {
        guard choice == .elevenLabs else { return nil }
        let (current, resting): (CloudStatus, Bool) = lock.withLock {
            (status, restUntil.map { Date() < $0 } ?? false)
        }
        if current == .keyCannotTranscribe || current == .termsNotAccepted {
            AssistantLog.add("Speech: on the iPhone (the ElevenLabs key can't transcribe yet)")
            return nil
        }
        if resting {
            AssistantLog.add("Speech: on the iPhone for now (ElevenLabs failed a moment ago)")
            return nil
        }
        let key: String?
        do {
            key = try KeyStore.shared.read(.elevenLabs)
        } catch {
            AssistantLog.add("Speech: on the iPhone (the iPhone hasn't been unlocked since it restarted)")
            return nil
        }
        guard let key else {
            set(.noKey)
            AssistantLog.add("Speech: on the iPhone (no ElevenLabs key)")
            return nil
        }
        return key
    }

    static func sessionOptions() -> ScribeSession.Options {
        var options = ScribeSession.Options()
        // English: see ScribeEngine for why the language is fixed.
        options.languageCode = "en"
        let (provider, useLocal) = lock.withLock { (keytermProvider, rejections == 0) }
        options.keyterms = ScribeSession.standardKeyterms + (useLocal ? provider?() ?? [] : [])
        return options
    }

    static func recordSuccess() {
        clearRest()
        set(.works)
    }

    /// What a failure means for the requests after this one.
    static func record(_ failure: ScribeSession.Failure) {
        switch failure {
        case .unauthorized:
            set(.keyCannotTranscribe)
            AssistantLog.add("Speech: the ElevenLabs key can't transcribe; ReGlass listens on the iPhone until that changes")
        case .termsNotAccepted:
            set(.termsNotAccepted)
            AssistantLog.add("Speech: ElevenLabs wants its speech to text terms accepted; ReGlass listens on the iPhone")
        case .quota:
            set(.quotaUsed)
            rest(for: 15 * 60)
        case .rejected:
            // The first refusal drops the local place names (the likeliest cause); a second one keeps ReGlass on the
            // iPhone until it restarts, rather than failing over on every request.
            let count: Int = lock.withLock {
                rejections += 1
                return rejections
            }
            if count >= 2 { rest(for: .infinity) }
            AssistantLog.add(count >= 2 ? "Speech: ElevenLabs refused ReGlass's request twice; on the iPhone until ReGlass restarts"
                                        : "Speech: ElevenLabs refused ReGlass's request; trying without local place names next")
        case .busy, .server, .network, .closed:
            rest(for: 30)
        }
    }

    // MARK: Private

    private static func set(_ new: CloudStatus) {
        let observer: (@Sendable (CloudStatus) -> Void)? = lock.withLock {
            guard status != new else { return nil }
            status = new
            return statusObserver
        }
        observer?(new)
    }

    private static func rest(for seconds: TimeInterval) {
        lock.withLock { restUntil = seconds.isFinite ? Date().addingTimeInterval(seconds) : .distantFuture }
    }

    private static func clearRest() {
        lock.withLock { restUntil = nil }
    }

    /// The first event (or nil for a timeout) of a key check.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var given: ScribeSession.Event??
        private var waiter: CheckedContinuation<ScribeSession.Event?, Never>?

        func give(_ event: ScribeSession.Event?) {
            let waiter: CheckedContinuation<ScribeSession.Event?, Never>? = lock.withLock {
                guard given == nil else { return nil }
                given = .some(event)
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume(returning: event)
        }

        func value() async -> ScribeSession.Event? {
            await withCheckedContinuation { continuation in
                let ready: ScribeSession.Event?? = lock.withLock {
                    if let given { return given }
                    waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }
}

// MARK: - The engine

/// ElevenLabs Scribe v2 Realtime as ReGlass's recognizer, with Apple's on-device one standing by
/// (`SpeechProvider.elevenLabs` registers it).
///
/// - **Start:** the socket opens as the request starts; audio waits in the session until `session_started`, so none
///   is lost while it connects. Every sample is also kept here (up to 40 s) for a replay.
/// - **Stand-in:** if the socket isn't open within 1.5 s, or it fails or closes before `finish()`, Apple's
///   recognizer is made and handed everything heard so far, then the live audio. Scribe's unfinished words are
///   cleared first, so the stand-in's words replace them rather than add to them.
/// - **End:** `Transcriber` decides when the wearer has finished (Scribe's own voice detection is off). `finish()`
///   commits and waits up to 1.2 s for the committed transcript, so the last word isn't lost; without one, the last
///   partial stands. A failure while finishing keeps the last partial, or, if Scribe had heard nothing yet, hands
///   the request to the stand-in.
/// - **Language:** fixed to English (`language_code=en`). The wearer may speak English with an accent, and local
///   place names come in through keyterms instead. Automatic detection could take a short accented request, or a
///   bare place name, for another language and spell the whole request in it. The live interpreter is the
///   exception: it fixes the session to the language it interprets.
/// - **Keyterms:** the wake phrase, "ReGlass", and the app's local place names
///   (`SpeechRecognition.setKeytermProvider`), at most 50 of at most 20 characters.
///
/// Logged: which engine, connect and commit timings, failure kinds. Never text.
final class ScribeEngine: RecognitionEngine, @unchecked Sendable {
    private enum Stage {
        /// The socket is opening; audio waits in the session.
        case connecting
        case streaming
        /// The stand-in is being made; audio waits in `heard`.
        case switching
        case onDevice(RecognitionEngine)
        case done
    }

    /// What a failure means for this request.
    private enum Response {
        case ignore, keepPartial, switchOver
    }

    private static let replayLimit = 130 * ScribeSession.sampleRate
    private static let baseName = "ElevenLabs Scribe v2 Realtime"

    private weak var owner: Transcriber?
    private let makeStandIn: @Sendable () async -> RecognitionEngine?
    private let lock = NSLock()
    private let watch = Stopwatch()
    private var session: ScribeSession?
    private var stage = Stage.connecting
    private var heard: [[Int16]] = []
    private var heardSamples = 0
    private var lastPartial = ""
    private var finishing = false
    private var commitAnswered = false
    /// Language detection is on (no fixed language): the commit counts as answered once the detected language is
    /// in too, or `languageGrace` after the committed transcript.
    private let wantsLanguage: Bool
    private var committedSeen = false
    private var languageSeen = false
    /// `finish()`'s wait for the committed transcript is over.
    private var deadlinePassed = false
    private var label = ScribeEngine.baseName + " (connecting)"
    private var connectTimer: Task<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    private var poked = false

    /// How long to wait for the detected language after the committed transcript (it's sent right after).
    private static let languageGrace: Duration = .milliseconds(350)

    var name: String { lock.withLock { label } }

    private init(owner: Transcriber, wantsLanguage: Bool, standIn: @escaping @Sendable () async -> RecognitionEngine?) {
        self.owner = owner
        self.wantsLanguage = wantsLanguage
        makeStandIn = standIn
    }

    /// A connecting engine, or nil when ElevenLabs isn't chosen or can't be used now (no key, a key problem, a
    /// recent failure): the caller then uses the iPhone's recognizer directly. `language`: an ISO 639-1 code, or nil
    /// to let Scribe work out each request's language and report it to `owner.languageDetected`.
    static func make(owner: Transcriber, language: String? = "en",
                     standIn: @escaping @Sendable () async -> RecognitionEngine?) -> ScribeEngine? {
        guard let key = SpeechRecognition.keyForNextRequest() else { return nil }
        var options = SpeechRecognition.sessionOptions()
        if language != "en" {
            options.languageCode = language
            options.includeLanguageDetection = language == nil
        }
        let engine = ScribeEngine(owner: owner, wantsLanguage: options.includeLanguageDetection, standIn: standIn)
        let session = ScribeSession(key: key, options: options, onLanguage: { [weak engine] code in
            engine?.languageDetected(code)
        }) { [weak engine] event in
            engine?.handle(event)
        }
        let timer = Task { [weak engine] in
            do {
                try await Task.sleep(for: .seconds(ScribeSession.connectTimeout))
            } catch {
                return
            }
            engine?.connectTimedOut()
        }
        engine.lock.withLock {
            engine.session = session
            engine.connectTimer = timer
        }
        session.connect()
        return engine
    }

    // MARK: RecognitionEngine

    func append(_ samples: [Int16]) {
        // Under the lock, so a replay into the stand-in always comes before newer audio.
        lock.withLock {
            switch stage {
            case .connecting, .streaming:
                rememberLocked(samples)
                session?.append(samples)
            case .switching:
                rememberLocked(samples)
            case .onDevice(let engine):
                engine.append(samples)
            case .done:
                break
            }
        }
    }

    func finish() async {
        let (session, opened): (ScribeSession?, Bool) = lock.withLock {
            finishing = true
            switch stage {
            case .streaming: return (self.session, true)
            case .connecting: return (self.session, false)
            default: return (nil, false)
            }
        }
        session?.commit()
        let commitStarted = watch.elapsed
        // Still connecting: the connect limit's remainder first, then the commit's own wait.
        let limit = ScribeSession.commitTimeout + (opened ? 0 : max(0, ScribeSession.connectTimeout - commitStarted))
        let alarm = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(limit))
            } catch {
                return
            }
            self?.deadlineReached()
        }
        defer { alarm.cancel() }
        while true {
            let now: Stage = lock.withLock { stage }
            switch now {
            case .onDevice(let engine):
                await engine.finish()
                return
            case .done:
                return
            case .switching:
                await waitForPoke()
            case .connecting, .streaming:
                if lock.withLock({ commitAnswered }) {
                    let timings = session?.timings
                    let audio = session?.sentSeconds ?? 0
                    AssistantLog.add("Speech: ElevenLabs committed \((watch.elapsed - commitStarted).seconds) after the "
                                     + "commit (\(String(format: "%.1f", audio)) s of audio)")
                    closeSession(label: Self.baseName + " (connected in \(timings?.opened?.seconds ?? "?"), "
                                 + "committed in \(timings?.committed?.seconds ?? "?"))")
                    return
                }
                if lock.withLock({ deadlinePassed }) {
                    AssistantLog.add("Speech: ElevenLabs sent no committed transcript within \(limit.seconds); "
                                     + "its last words stand")
                    closeSession(label: Self.baseName + " (no committed transcript)")
                    return
                }
                await waitForPoke()
            }
        }
    }

    func cancel() {
        let (session, previous, timer): (ScribeSession?, Stage, Task<Void, Never>?) = lock.withLock {
            defer {
                stage = .done
                heard.removeAll()
            }
            return (self.session, stage, connectTimer)
        }
        timer?.cancel()
        session?.close()
        if case .onDevice(let engine) = previous { engine.cancel() }
        poke()
    }

    // MARK: Session events

    private func handle(_ event: ScribeSession.Event) {
        switch event {
        case .started:
            let after = watch.elapsed
            let live: Bool = lock.withLock {
                guard case .connecting = stage else { return false }
                stage = .streaming
                connectTimer?.cancel()
                label = Self.baseName + " (connected in \(after.seconds))"
                return true
            }
            guard live else { return }
            SpeechRecognition.recordSuccess()
            AssistantLog.add("Speech: ElevenLabs connected in \(after.seconds)")
            poke()
        case .partial(let text):
            let live: Bool = lock.withLock {
                guard isScribeLocked else { return false }
                lastPartial = text
                return true
            }
            if live { owner?.update(text, isFinal: false) }
        case .committed(let text):
            let final: String? = lock.withLock {
                guard isScribeLocked else { return nil }
                defer { lastPartial = "" }
                // An empty commit after words were heard would wipe them: keep the partial instead.
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? lastPartial : text
            }
            guard let final else { return }
            owner?.update(final, isFinal: true)
            let waitForLanguage: Bool = lock.withLock {
                committedSeen = true
                let waiting = wantsLanguage && !languageSeen
                if finishing, !waiting { commitAnswered = true }
                return waiting
            }
            if waitForLanguage {
                // The detected language follows the committed transcript; don't hold the request long for it.
                Task { [weak self] in
                    try? await Task.sleep(for: Self.languageGrace)
                    guard let self else { return }
                    self.lock.withLock { if self.finishing { self.commitAnswered = true } }
                    self.poke()
                }
            }
            poke()
        case .failed(let failure):
            SpeechRecognition.record(failure)
            let response: Response = lock.withLock {
                guard isScribeLocked else { return .ignore }
                if finishing, !lastPartial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    stage = .done
                    label = Self.baseName + " (failed while finishing: \(failure.kind))"
                    return .keepPartial
                }
                return .switchOver
            }
            switch response {
            case .ignore:
                return
            case .keepPartial:
                AssistantLog.add("Speech: ElevenLabs failed while finishing (\(failure.kind)); its last words stand")
                lock.withLock { session }?.close()
                poke()
            case .switchOver:
                switchToStandIn(because: failure.kind)
            }
        }
    }

    /// Scribe's detected language for the committed transcript (language detection on).
    private func languageDetected(_ code: String) {
        guard lock.withLock({ isScribeLocked }) else { return }
        // The owner has the language before `finish()` can see the commit as answered.
        owner?.languageDetected(code)
        lock.withLock {
            languageSeen = true
            if finishing, committedSeen { commitAnswered = true }
        }
        poke()
    }

    private func connectTimedOut() {
        let late: Bool = lock.withLock {
            if case .connecting = stage { return true }
            return false
        }
        guard late else { return }
        SpeechRecognition.record(.network)
        switchToStandIn(because: "no connection in \(ScribeSession.connectTimeout.seconds)")
    }

    // MARK: The stand-in

    private func switchToStandIn(because reason: String) {
        let session: ScribeSession?? = lock.withLock {
            guard isScribeLocked else { return nil }
            stage = .switching
            connectTimer?.cancel()
            defer { self.session = nil }
            return .some(self.session)
        }
        guard let session else { return }
        session?.close()
        let replay = Double(lock.withLock { heardSamples }) / Double(ScribeSession.sampleRate)
        AssistantLog.add("Speech: ElevenLabs failed (\(reason)) after \(watch.elapsed.seconds); the iPhone's "
                         + "recognizer takes over with \(String(format: "%.1f", replay)) s of audio replayed")
        Task { [weak self] in
            guard let self else { return }
            let standIn = await self.makeStandIn()
            // Scribe's unfinished words go: the stand-in hears the whole request again.
            self.owner?.update("", isFinal: false)
            let cancelled: Bool = self.lock.withLock {
                guard case .switching = self.stage else { return true }
                if let standIn {
                    self.stage = .onDevice(standIn)
                    self.label = "\(standIn.name), after ElevenLabs failed (\(reason))"
                    // Under the lock: audio arriving meanwhile queues behind the replay.
                    for chunk in self.heard { standIn.append(chunk) }
                } else {
                    self.stage = .done
                    self.label = Self.baseName + " (failed: \(reason); no stand-in)"
                }
                self.heard.removeAll()
                return false
            }
            if cancelled {
                standIn?.cancel()
                return
            }
            self.poke()
            if standIn == nil {
                self.owner?.engineStopped("ElevenLabs failed and no on-device recognizer is ready")
            }
        }
    }

    // MARK: Private

    private var isScribeLocked: Bool {
        switch stage {
        case .connecting, .streaming: return true
        default: return false
        }
    }

    private func rememberLocked(_ samples: [Int16]) {
        guard heardSamples < Self.replayLimit else { return }
        heard.append(samples)
        heardSamples += samples.count
    }

    private func closeSession(label newLabel: String) {
        let session: ScribeSession? = lock.withLock {
            stage = .done
            label = newLabel
            heard.removeAll()
            defer { self.session = nil }
            return self.session
        }
        session?.close()
    }

    private func deadlineReached() {
        lock.withLock { deadlinePassed = true }
        poke()
    }

    /// Wakes `finish()` to look again; remembered if it isn't waiting yet.
    private func poke() {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            guard let waiter else {
                poked = true
                return nil
            }
            self.waiter = nil
            return waiter
        }
        waiter?.resume()
    }

    private func waitForPoke() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if poked {
                    poked = false
                    return true
                }
                waiter = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }
}
