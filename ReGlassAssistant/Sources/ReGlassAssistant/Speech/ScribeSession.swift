import Foundation

/// One ElevenLabs Scribe v2 Realtime session: 16 kHz mono speech in, partial and committed transcripts out.
///
/// The API, as ElevenLabs documents it:
/// - `wss://api.elevenlabs.io/v1/speech-to-text/realtime`, with the key in the `xi-api-key` header.
///   https://elevenlabs.io/docs/api-reference/speech-to-text/v-1-speech-to-text-realtime
/// - Query: `model_id=scribe_v2_realtime` (the only value), `audio_format=pcm_16000`, `commit_strategy=manual` (so
///   Scribe's own voice detection never ends a request: ReGlass decides when the wearer has finished),
///   `language_code=en`, and `keyterms` repeated once per term (realtime takes at most 50, 20 characters each).
/// - The server opens with `session_started`. ReGlass then sends `{"message_type": "input_audio_chunk",
///   "audio_base_64": …, "commit": false, "sample_rate": 16000}` in pieces of 0.1 to 1 s (the docs' range), and at
///   the end the same message with no audio and `"commit": true`.
///   https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/server-side-streaming
/// - The server answers with `partial_transcript` (`text`; each one replaces the last) and, after the commit,
///   `committed_transcript` (`text`, final for the segment). It starts transcribing once about 2 s of audio is in.
///   https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/transcripts-and-commit-strategies
/// - Errors arrive as a message whose `message_type` names them (`auth_error`, `quota_exceeded`, `unaccepted_terms`,
///   `rate_limited`, `invalid_request`, …, with an `error` string) just before the server closes. A key without the
///   Speech to Text permission may instead be turned away at the handshake (HTTP 401 or 403).
///   https://elevenlabs.io/docs/eleven-api/guides/how-to/speech-to-text/realtime/event-reference
/// - The server closes after 15 s without audio. ReGlass streams the whole time, so that never happens.
/// - `enable_logging=false` (zero retention) is for Enterprise plans only, so ReGlass doesn't send it.
///
/// Foundation only, on purpose: the command-line test harness compiles this same file, so it talks to Scribe exactly
/// as ReGlass does. Nothing here logs; callers log kinds and timings, never text.
final class ScribeSession: @unchecked Sendable {
    static let modelID = "scribe_v2_realtime"
    static let sampleRate = 16_000
    /// Audio goes out in pieces of 0.1 s to 1 s.
    static let smallestChunk = 1_600
    static let largestChunk = 16_000
    static let keytermLimit = 50
    static let keytermLength = 20
    /// How long ReGlass waits for `session_started` before the iPhone's recognizer takes over.
    static let connectTimeout: TimeInterval = 1.5
    /// How long ReGlass waits for the committed transcript after the commit.
    static let commitTimeout: TimeInterval = 1.2
    /// Words to expect in every request: the wake phrase (so it's spelled the way ReGlass removes it) and the app's
    /// name (said partway through a request, it starts a new instruction).
    static let standardKeyterms = ["Hey Meta", "ReGlass"]

    struct Options: Sendable {
        /// An ISO 639-1 code, or nil to let Scribe detect the language.
        var languageCode: String? = "en"
        /// Other languages Scribe may pick besides `languageCode` (`secondary_languages`). It's in ElevenLabs'
        /// schema but not described, so only the harness tries it.
        var secondaryLanguages: [String] = []
        /// `include_language_detection=true`: after each committed transcript Scribe also sends
        /// `committed_transcript_with_timestamps`, whose `language_code` is handed to `onLanguage` (the interpreter).
        var includeLanguageDetection = false
        var keyterms: [String] = []
        var host = "api.elevenlabs.io"
    }

    enum Event: Sendable, Equatable {
        /// `session_started`: the socket is open and taking audio.
        case started
        case partial(String)
        case committed(String)
        /// The session is over; nothing follows.
        case failed(Failure)
    }

    enum Failure: Error, Sendable, Equatable {
        /// The key was turned away, or it can't do speech to text (HTTP 401 or 403, `auth_error`).
        case unauthorized
        /// Scribe's terms haven't been accepted in the ElevenLabs dashboard (`unaccepted_terms`).
        case termsNotAccepted
        /// The quota is used up (`quota_exceeded`, HTTP 402).
        case quota
        /// ElevenLabs is too busy right now (`rate_limited`, `queue_overflow`, `resource_exhausted`,
        /// `commit_throttled`, HTTP 429).
        case busy(String)
        /// ElevenLabs refused what ReGlass sent (`invalid_request`, `input_error`, `chunk_size_exceeded`, other 4xx).
        case rejected(String)
        /// Something failed on ElevenLabs' side (`transcriber_error`, `error`, HTTP 5xx, …).
        case server(String)
        /// No connection, or it dropped.
        case network
        /// The server closed the socket without saying why (the close code).
        case closed(Int)

        /// For the log: a kind, never a message.
        var kind: String {
            switch self {
            case .unauthorized: return "key turned away"
            case .termsNotAccepted: return "terms not accepted"
            case .quota: return "quota used up"
            case .busy(let kind), .rejected(let kind), .server(let kind): return kind
            case .network: return "network"
            case .closed(let code): return "closed \(code)"
            }
        }
    }

    private let task: URLSessionWebSocketTask
    private let onEvent: @Sendable (Event) -> Void
    private let onLanguage: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private let born = ProcessInfo.processInfo.systemUptime
    private var pending: [Int16] = []
    private var opened = false
    private var over = false
    private var commitWanted = false
    private var commitSentAt: TimeInterval?
    private var openedAt: TimeInterval?
    private var committedAt: TimeInterval?
    private var sent = 0

    private static let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    /// `onEvent` is called from the session's own threads, one event at a time. `onLanguage` gets the detected
    /// language code (as Scribe spells it, e.g. "fra" or "fr") when `includeLanguageDetection` is on.
    init(key: String, options: Options, onLanguage: (@Sendable (String) -> Void)? = nil,
         onEvent: @escaping @Sendable (Event) -> Void) {
        var request = URLRequest(url: Self.url(for: options))
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        task = Self.urlSession.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        self.onEvent = onEvent
        self.onLanguage = onLanguage
    }

    // MARK: Use

    /// Opens the socket. Audio appended before `session_started` waits here and goes out as soon as it arrives.
    func connect() {
        task.resume()
        Task.detached(priority: .userInitiated) { [self] in await receive() }
    }

    /// 16 kHz mono Int16. Ignored after the commit.
    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        lock.withLock {
            guard !over, commitWanted == false else { return }
            pending.append(contentsOf: samples)
            if opened { flushLocked(everything: false) }
        }
    }

    /// Sends what's left and asks for the committed transcript. Before `session_started`, it happens right after.
    func commit() {
        lock.withLock {
            guard !over, !commitWanted else { return }
            commitWanted = true
            if opened { commitLocked() }
        }
    }

    /// Live use (the real-time interpreter, `LiveTranscriber`): sends what's left and commits it as one segment, but
    /// keeps the session open for more audio and more commits ("A session can have multiple committed transcripts";
    /// each commit starts a new segment without losing context). Each answer arrives as `.committed`. False before
    /// `session_started`, after `commit()`, or once the session is over.
    @discardableResult
    func commitSegment() -> Bool {
        lock.withLock {
            guard !over, opened, !commitWanted else { return false }
            commitLocked()
            return true
        }
    }

    /// Closes the socket. No events follow.
    func close() {
        lock.withLock { over = true }
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// Seconds from `connect()` to `session_started`, and from the commit to the committed transcript.
    var timings: (opened: TimeInterval?, committed: TimeInterval?) {
        lock.withLock {
            (openedAt, committedAt.flatMap { done in commitSentAt.map { done - $0 } })
        }
    }

    /// Audio sent so far, in seconds.
    var sentSeconds: Double { lock.withLock { Double(sent) / Double(Self.sampleRate) } }

    // MARK: Messages

    static func url(for options: Options) -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = options.host
        components.path = "/v1/speech-to-text/realtime"
        var items = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
        ]
        if let language = options.languageCode { items.append(URLQueryItem(name: "language_code", value: language)) }
        items += options.secondaryLanguages.map { URLQueryItem(name: "secondary_languages", value: $0) }
        if options.includeLanguageDetection { items.append(URLQueryItem(name: "include_language_detection", value: "true")) }
        items += cleanKeyterms(options.keyterms).map { URLQueryItem(name: "keyterms", value: $0) }
        components.queryItems = items
        return components.url!
    }

    /// At most 50 distinct terms of at most 20 characters, made of letters, digits, spaces, apostrophes, hyphens and
    /// full stops. Anything else is dropped rather than cut (a cut name would mislead the model).
    static func cleanKeyterms(_ terms: [String]) -> [String] {
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: " '’-."))
        var seen = Set<String>()
        var result: [String] = []
        for term in terms {
            let cleaned = term.precomposedStringWithCanonicalMapping
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !cleaned.isEmpty, cleaned.count <= keytermLength,
                  cleaned.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  seen.insert(cleaned.lowercased()).inserted else { continue }
            result.append(cleaned)
            if result.count == keytermLimit { break }
        }
        return result
    }

    private static func audioMessage(_ samples: ArraySlice<Int16>) -> String {
        // Apple's chips are little-endian, like Scribe's PCM.
        let audio = samples.withUnsafeBytes { Data($0).base64EncodedString() }
        return #"{"message_type":"input_audio_chunk","audio_base_64":""# + audio
            + #"","commit":false,"sample_rate":16000}"#
    }

    private static let commitMessage =
        #"{"message_type":"input_audio_chunk","audio_base_64":"","commit":true,"sample_rate":16000}"#

    /// Sends whole pieces of 0.1 to 1 s; with `everything`, the remainder too.
    private func flushLocked(everything: Bool) {
        while pending.count >= Self.smallestChunk || (everything && !pending.isEmpty) {
            let count = min(pending.count, Self.largestChunk)
            sendLocked(Self.audioMessage(pending[0..<count]))
            pending.removeFirst(count)
            sent += count
        }
    }

    private func commitLocked() {
        flushLocked(everything: true)
        sendLocked(Self.commitMessage)
        commitSentAt = now
    }

    /// Sends in order (called under the lock). A failed send ends the session, off this thread.
    private func sendLocked(_ text: String) {
        task.send(.string(text)) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.global().async { self?.fail(.network) }
        }
    }

    // MARK: Receiving

    private func receive() async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                disconnected()
                return
            }
            let data: Data
            switch message {
            case .string(let text): data = Data(text.utf8)
            case .data(let bytes): data = bytes
            @unknown default: continue
            }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = object["message_type"] as? String else { continue }
            handle(type, object)
            if lock.withLock({ over }) { return }
        }
    }

    private func handle(_ type: String, _ object: [String: Any]) {
        let text = object["text"] as? String ?? ""
        switch type {
        case "session_started":
            let first: Bool = lock.withLock {
                guard !over, !opened else { return false }
                opened = true
                openedAt = now
                flushLocked(everything: false)
                if commitWanted { commitLocked() }
                return true
            }
            if first { onEvent(.started) }
        case "partial_transcript":
            if lock.withLock({ !over }) { onEvent(.partial(text)) }
        case "committed_transcript":
            let live: Bool = lock.withLock {
                if commitSentAt != nil, committedAt == nil { committedAt = now }
                return !over
            }
            if live { onEvent(.committed(text)) }
        case "committed_transcript_with_timestamps":
            // Sent after `committed_transcript` when timestamps or language detection are on; only its language is used.
            if let code = object["language_code"] as? String, !code.isEmpty, lock.withLock({ !over }) { onLanguage?(code) }
        case "committed_transcript_entities", "edited_transcript", "warning":
            break
        default:
            guard object["error"] != nil else { break }
            fail(Self.failure(type: type, error: object["error"] as? String ?? ""))
        }
    }

    /// The socket ended without an error message: the handshake was refused, or the connection dropped or closed.
    private func disconnected() {
        let failure: Failure? = lock.withLock {
            guard !over else { return nil }
            if !opened, let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
                return Self.failure(status: status)
            }
            let code = task.closeCode
            guard code != .invalid else { return .network }
            let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) }?.lowercased() ?? ""
            if code == .policyViolation, ["auth", "permission", "key"].contains(where: { reason.contains($0) }) {
                return .unauthorized
            }
            return .closed(code.rawValue)
        }
        if let failure { fail(failure) }
    }

    private func fail(_ failure: Failure) {
        let first: Bool = lock.withLock {
            guard !over else { return false }
            over = true
            return true
        }
        guard first else { return }
        task.cancel(with: .normalClosure, reason: nil)
        onEvent(.failed(failure))
    }

    static func failure(type: String, error: String) -> Failure {
        switch type {
        case "auth_error": return .unauthorized
        case "unaccepted_terms": return .termsNotAccepted
        case "quota_exceeded": return .quota
        case "rate_limited", "queue_overflow", "resource_exhausted", "commit_throttled": return .busy(type)
        case "invalid_request", "input_error", "chunk_size_exceeded": return .rejected(type)
        default:
            let lowered = error.lowercased()
            if ["permission", "api key", "api_key", "unauthori"].contains(where: { lowered.contains($0) }) { return .unauthorized }
            // Keep known kinds for diagnostics and use a fixed label for unrecognized provider input.
            return .server(type == "transcriber_error" || type == "error" ? type : "server error")
        }
    }

    static func failure(status: Int) -> Failure {
        switch status {
        case 401, 403: return .unauthorized
        case 402: return .quota
        case 429: return .busy("HTTP 429")
        case 400..<500: return .rejected("HTTP \(status)")
        default: return .server("HTTP \(status)")
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime - born }
}
