import Foundation

/// The real-time interpreter's listener: the iPhone's microphone, streamed without a break into one long-lived
/// ElevenLabs Scribe v2 Realtime session, cut here into sentence-sized segments. Normal requests never use it.
///
/// - **One socket, many commits.** `commit_strategy=manual` as for requests, and one commit per segment. ElevenLabs
///   documents that "a session can have multiple committed transcripts" and that each commit "will clear the processed
///   accumulated transcript and start a new segment without losing context". The interpreter fixes the
///   session to the language it interprets (`languageCode`); with no language given, Scribe detects it
///   (`include_language_detection=true`). Keyterms as for requests.
/// - **Where a segment ends** (decided here, on Scribe's partial text and a small level detector):
///   - the words so far end a sentence and `sentencePause` (1.0 s) of quiet follows;
///   - `pause` (1.2 s) of quiet, sentence end or not;
///   - `segmentCap` (24 s) after its first words, whatever they are.
///   When the detector can't tell voice from noise, no new words for 1 s after a sentence end (1.8 s otherwise) will
///   do.
/// - **After a commit**, the committed transcript is awaited (1.2 s at most, then the last partial stands), and then
///   its detected language (0.35 s at most). Partials in between belong to the old segment and are dropped. Segments
///   come out in order.
/// - **The assistant's own voice** (the glasses' open-ear speakers, heard faintly by the iPhone): nothing is muted.
///   Each segment says whether it overlapped the app's playback, for the app's echo check, which compares words.
/// - **Reconnects** by itself when the socket drops: the audio since the last commit (up to 15 s) is replayed into
///   the new session, so no words are lost. Six failures in a row without a working session end it. A key problem
///   (turned away, terms, quota) ends it at once, and is recorded for normal requests too.
/// - The server closes after 15 s without audio. The microphone streams all the time (gated frames as silence), so
///   that never happens. If ElevenLabs commits by itself (after about 36 s of audio with no commit), that's a segment
///   too.
///
/// Nothing here logs. The caller logs kinds, counts and timings, never text.
public final class LiveTranscriber: @unchecked Sendable {
    public struct Settings: Sendable {
        /// Quiet after a sentence end that commits Scribe's buffer when speech has stopped.
        public var sentencePause: TimeInterval = 1.0
        /// Quiet that commits Scribe's buffer when speech has stopped.
        public var pause: TimeInterval = 1.2
        /// The longest unemitted run before Scribe commits, from its first words.
        public var segmentCap: TimeInterval = 24
        /// Earliest speech duration before a mid-utterance clause cut at punctuation.
        public var clauseMinimumSeconds: TimeInterval = 2.0
        /// Brief pause at a clause or sentence mark that lets it cut locally without resetting Scribe.
        public var clausePause: TimeInterval = 0.24
        /// Speech duration before an unpunctuated clause cuts on stabilized words.
        public var clauseHorizonSeconds: TimeInterval = 2.8
        /// Stabilized words needed for an unpunctuated horizon cut (with lookahead words after them).
        public var clauseHorizonWords: Int = 8
        /// While the voice plays (and 0.5 s after), quieter frames are sent as silence.
        public var playbackGateDB: Double = -48
        /// Without the detector: no new words for this long after a sentence end.
        public var noNewWordsAfterSentence: TimeInterval = 1.2
        /// Without the detector: no new words for this long.
        public var noNewWords: TimeInterval = 1.8

        public init() {}
    }

    public enum CutReason: String, Sendable {
        case clause = "live clause"
        case sentence = "sentence end"
        case pause = "pause"
        case cap = "length cap"
        /// ElevenLabs committed by itself.
        case server = "committed by ElevenLabs"
    }

    /// One segment: what was said and how it was cut. Its text is content: never log it.
    public struct Segment: Sendable {
        public let number: Int
        public let text: String
        /// As Scribe spelled it ("fra", "en"); nil when it didn't say.
        public let language: String?
        public let reason: CutReason
        /// From the first words to the cut or commit.
        public let speechSeconds: Double
        /// From the commit to the committed transcript; nil for a live clause or when the last partial stood.
        public let commitSeconds: Double?
        /// The loudest 20 ms frame that went out (not gated), in dBFS.
        public let loudestDB: Double
        /// The voice was playing (or had just stopped) while it was said.
        public let overlappedPlayback: Bool
        /// True when an earlier clause of the same utterance was already emitted before this segment.
        public let isContinuation: Bool
        /// True when cut mid-utterance while the speaker is still talking.
        public let continues: Bool

        public init(number: Int, text: String, language: String?, reason: CutReason, speechSeconds: Double,
                    commitSeconds: Double?, loudestDB: Double, overlappedPlayback: Bool,
                    isContinuation: Bool = false, continues: Bool = false) {
            self.number = number
            self.text = text
            self.language = language
            self.reason = reason
            self.speechSeconds = speechSeconds
            self.commitSeconds = commitSeconds
            self.loudestDB = loudestDB
            self.overlappedPlayback = overlappedPlayback
            self.isContinuation = isContinuation
            self.continues = continues
        }
    }

    public enum Failure: Sendable, Equatable {
        case noKey
        case keyLocked
        case keyCannotTranscribe
        case termsNotAccepted
        case quota
        /// ElevenLabs couldn't be reached, again and again (the last failure's kind).
        case unreachable(String)

        /// For the log.
        public var kind: String {
            switch self {
            case .noKey: return "no ElevenLabs key"
            case .keyLocked: return "Keychain locked"
            case .keyCannotTranscribe: return "key can't transcribe"
            case .termsNotAccepted: return "terms not accepted"
            case .quota: return "quota used up"
            case .unreachable(let kind): return "unreachable (\(kind))"
            }
        }

        /// One plain sentence for the owner.
        public var explanation: String {
            switch self {
            case .noKey: return "ReGlass needs your ElevenLabs key to listen in real time."
            case .keyLocked: return "Unlock your iPhone once, then start again."
            case .keyCannotTranscribe: return "Your ElevenLabs key can't turn speech into text."
            case .termsNotAccepted: return "ElevenLabs wants its speech to text terms accepted first."
            case .quota: return "Your ElevenLabs quota is used up."
            case .unreachable: return "ReGlass lost its connection to ElevenLabs."
            }
        }
    }

    public enum Event: Sendable {
        /// The session is open (`reconnects` > 0: again, after a drop).
        case connected(seconds: Double, reconnects: Int)
        /// The segment being heard, so far ("" once it's committed).
        case partial(String)
        case segment(Segment)
        /// The socket dropped (log-safe kind); reconnecting.
        case reconnecting(String)
        /// Over for good; `events` ends after it.
        case failed(Failure)
    }

    public struct Totals: Sendable {
        public let sentSeconds: Double
        /// Audio sent as silence while the voice played.
        public let gatedSeconds: Double
        public let reconnects: Int
    }

    public let events: AsyncStream<Event>

    private static let rate = 16_000.0
    private static let frame = 320
    private static let languageGrace: Duration = .milliseconds(120)
    private static let continuationLanguageGrace: Duration = .milliseconds(50)
    private static let connectTimeout: Duration = .seconds(5)
    private static let attempts = 6
    private static let replayLimit = 15 * 16_000
    /// The gate stays on this long after the voice stops (the glasses' buffer and the room).
    private static let gateTail = Int(0.5 * rate)
    /// A frame above the gate keeps it open this long.
    private static let gateHold = Int(0.3 * rate)
    /// A segment overlapped the voice if it played up to this long before its first words were recognised.
    private static let overlapLookback = Int(1.5 * rate)

    private let settings: Settings
    private let languageCode: String?
    private let continuation: AsyncStream<Event>.Continuation
    private let clock = ContinuousClock()
    private let lock = NSLock()

    // Connection (under `lock`).
    private var key: String?
    private var session: ScribeSession?
    private var generation = 0
    private var opened = false
    private var connectStarted = ContinuousClock.now
    private var failuresInARow = 0
    private var reconnects = 0
    private var started = false
    private var stopped = false

    // The segment being heard (unemitted tail of the active Scribe accumulation).
    private var fullPartial = ""
    private var partial = ""
    private var partialChangedAt = ContinuousClock.now
    private var firstWordsAt: ContinuousClock.Instant?
    private var firstWordsSample = 0
    private var segmentLoudest = -120.0
    private var levels = Levels()
    /// Normalized words already emitted as live `.clause` segments in the active Scribe accumulation.
    private var emittedWords: [String] = []
    /// CJK / unspaced characters already emitted in the active Scribe accumulation.
    private var emittedCJKCount = 0
    /// How many live `.clause` segments have been emitted in the active Scribe accumulation.
    private var emittedInUtterance = 0
    /// Previous snapshot of normalized words in `partial`, for local-agreement stability checks.
    private var previousTailTokens: [String] = []
    private var currentTailTokens: [String] = []
    private var tokensSnapshotAt = ContinuousClock.now

    // Audio.
    private var carry: [Int16] = []
    private var sampleClock = 0
    /// What went out since the last commit, for a reconnect.
    private var replay: [Int16] = []
    private var playbackActive = false
    private var playbackEndedSample: Int?
    private var lastPlaybackSample = Int.min / 2
    private var gateOpenUntil = 0
    private var gatedSamples = 0
    private var sentSamples = 0

    // Commits.
    /// Committed transcripts expected, oldest first.
    private var awaiting: [Commit] = []
    /// Segments to hand out, in order.
    private var outbox: [Commit] = []
    /// The next detected language belongs to this one.
    private var lastAnswered: Commit?
    private var number = 0

    public init(settings: Settings = Settings(), languageCode: String? = nil) {
        self.settings = settings
        self.languageCode = languageCode
        (events, continuation) = AsyncStream<Event>.makeStream()
    }

    // MARK: Use

    /// Opens the session; audio appended meanwhile goes out once it's open. Nil when it's on its way, else why it
    /// can't start.
    public func start() -> Failure? {
        let key: String?
        do {
            key = try KeyStore.shared.read(.elevenLabs)
        } catch {
            return .keyLocked
        }
        guard let key, !key.isEmpty else { return .noKey }
        switch SpeechRecognition.cloudStatus {
        case .keyCannotTranscribe: return .keyCannotTranscribe
        case .termsNotAccepted: return .termsNotAccepted
        case .quotaUsed: return .quota
        default: break
        }
        lock.withLock {
            guard !started, !stopped else { return }
            self.key = key
            started = true
            connectLocked()
        }
        return nil
    }

    /// 16 kHz mono Int16 from the microphone, all the time. Never zeroes out frames while the voice plays so continuous
    /// foreign speech (a conversation or video) is never chopped while it speaks.
    public func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        var out: [Event] = []
        lock.withLock {
            guard started, !stopped else { return }
            carry.append(contentsOf: samples)
            var outgoing: [Int16] = []
            outgoing.reserveCapacity(carry.count)
            var index = 0
            while index + Self.frame <= carry.count {
                let slice = carry[index..<(index + Self.frame)]
                let level = Self.level(slice)
                let gateOn = playbackActive || (playbackEndedSample.map { sampleClock - $0 < Self.gateTail } ?? false)
                if gateOn { lastPlaybackSample = sampleClock }
                outgoing.append(contentsOf: slice)
                levels.frame(level, samples: Self.frame)
                segmentLoudest = max(segmentLoudest, level)
                sampleClock += Self.frame
                index += Self.frame
            }
            carry.removeFirst(index)
            guard !outgoing.isEmpty else { return }
            sentSamples += outgoing.count
            replay.append(contentsOf: outgoing)
            if replay.count > Self.replayLimit { replay.removeFirst(replay.count - Self.replayLimit) }
            session?.append(outgoing)
            decideLocked(&out)
        }
        emit(out)
    }

    /// The voice started (true) or stopped (false) playing on the glasses.
    public func setPlaybackActive(_ active: Bool) {
        lock.withLock {
            if playbackActive, !active { playbackEndedSample = sampleClock }
            if active { lastPlaybackSample = sampleClock }
            playbackActive = active
        }
    }

    /// Closes the session. `events` ends; segments still on their way are dropped.
    public func stop() {
        let session: ScribeSession? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            generation += 1
            defer { self.session = nil }
            return self.session
        }
        session?.close()
        continuation.finish()
    }

    public var totals: Totals {
        lock.withLock {
            Totals(sentSeconds: Double(sentSamples) / Self.rate, gatedSeconds: Double(gatedSamples) / Self.rate,
                   reconnects: reconnects)
        }
    }

    // MARK: Connection

    private func connectLocked() {
        guard let key, !stopped else { return }
        generation += 1
        let gen = generation
        opened = false
        connectStarted = clock.now
        var options = SpeechRecognition.sessionOptions()
        options.languageCode = languageCode
        options.includeLanguageDetection = languageCode == nil
        let session = ScribeSession(key: key, options: options, onLanguage: { [weak self] code in
            self?.languageDetected(code, generation: gen)
        }) { [weak self] event in
            self?.handle(event, generation: gen)
        }
        self.session = session
        // After a drop: what was said since the last commit, again (it waits in the session until it's open).
        if !replay.isEmpty { session.append(replay) }
        session.connect()
        Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            self?.connectTimedOut(generation: gen)
        }
    }

    private func handle(_ event: ScribeSession.Event, generation gen: Int) {
        var out: [Event] = []
        var finish = false
        lock.withLock {
            guard gen == generation, !stopped else { return }
            switch event {
            case .started:
                opened = true
                failuresInARow = 0
                out.append(.connected(seconds: Self.seconds(connectStarted.duration(to: clock.now)), reconnects: reconnects))
            case .partial(let text):
                guard !awaitingAnswerLocked else { return }   // still the committed segment's
                takeLocked(partial: text, &out)
                decideLocked(&out)
            case .committed(let text):
                committedLocked(text, &out)
            case .failed(let failure):
                finish = failedLocked(failure, &out)
            }
        }
        emit(out, finish: finish)
    }

    private func connectTimedOut(generation gen: Int) {
        var out: [Event] = []
        var finish = false
        let late: ScribeSession? = lock.withLock {
            guard gen == generation, !opened, !stopped else { return nil }
            defer { finish = failedLocked(.network, &out) }
            return session
        }
        late?.close()
        emit(out, finish: finish)
    }

    /// The socket failed: its unanswered commits keep their last partial, and either a reconnect is scheduled or it's
    /// over. True when it's over.
    private func failedLocked(_ failure: ScribeSession.Failure, _ out: inout [Event]) -> Bool {
        session = nil
        opened = false
        generation += 1
        for commit in awaiting where !commit.answered && !commit.resolved {
            commit.timedOut = true
            commit.text = commit.fallback
            commit.resolved = true
        }
        if let commit = lastAnswered, !commit.resolved { commit.resolved = true }
        lastAnswered = nil
        awaiting.removeAll()
        flushLocked(&out)
        // The replay brings the segment's words back in the new session; keep `emittedWords` so replayed clauses
        // aren't emitted a second time.
        partial = ""
        firstWordsAt = nil
        previousTailTokens = []
        currentTailTokens = []
        out.append(.partial(""))
        switch failure {
        case .unauthorized, .termsNotAccepted, .quota:
            SpeechRecognition.record(failure)
            stopped = true
            let mapped: Failure = failure == .unauthorized ? .keyCannotTranscribe
                : failure == .termsNotAccepted ? .termsNotAccepted : .quota
            out.append(.failed(mapped))
            return true
        default:
            failuresInARow += 1
            guard failuresInARow < Self.attempts else {
                stopped = true
                out.append(.failed(.unreachable(failure.kind)))
                return true
            }
            reconnects += 1
            out.append(.reconnecting(failure.kind))
            let delay = min(3.0, 0.3 * pow(2, Double(failuresInARow - 1)))
            let gen = generation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                self?.reconnect(generation: gen)
            }
            return false
        }
    }

    private func reconnect(generation gen: Int) {
        lock.withLock {
            guard gen == generation, !stopped, session == nil else { return }
            connectLocked()
        }
    }

    // MARK: Segments

    private var awaitingAnswerLocked: Bool {
        awaiting.contains { !$0.answered && !$0.timedOut }
    }

    private func takeLocked(partial text: String, _ out: inout [Event]) {
        let now = clock.now
        fullPartial = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unemitted = Self.unemittedTail(from: fullPartial, emittedWords: emittedWords, emittedCJKCount: emittedCJKCount)
        guard unemitted != partial else {
            // Identical partial update: if enough time passed since the last snapshot, all current words have now
            // agreed across two updates.
            if Self.seconds(tokensSnapshotAt.duration(to: now)) >= 0.15 {
                previousTailTokens = currentTailTokens
                tokensSnapshotAt = now
            }
            return
        }
        let nextTokens = Self.normalizedWords(unemitted)
        if Self.seconds(tokensSnapshotAt.duration(to: now)) >= 0.15 || previousTailTokens.isEmpty {
            previousTailTokens = currentTailTokens
            tokensSnapshotAt = now
        }
        currentTailTokens = nextTokens
        partial = unemitted
        partialChangedAt = now
        if unemitted.isEmpty {
            firstWordsAt = nil
        } else if firstWordsAt == nil {
            firstWordsAt = now
            firstWordsSample = sampleClock
        }
        out.append(.partial(unemitted))
    }

    private func decideLocked(_ out: inout [Event]) {
        guard opened, !stopped, !awaitingAnswerLocked else { return }
        let now = clock.now
        let stale = Self.seconds(partialChangedAt.duration(to: now))
        let quiet = Double(levels.silenceSamples) / Self.rate

        // When earlier live clauses already emitted every word of the utterance and the speaker has now paused,
        // commit on Scribe to clear its server-side accumulator for the next utterance.
        if partial.isEmpty {
            guard emittedInUtterance > 0, (levels.voiced && quiet >= settings.pause) || stale >= settings.noNewWords,
                  let session, session.commitSegment() else { return }
            let commit = Commit(number: 0, sentAt: now, reason: .pause, fallback: "", speechSeconds: 0,
                                loudestDB: segmentLoudest, overlapped: false, isContinuation: true, continues: false,
                                emittedWords: emittedWords, emittedCJKCount: emittedCJKCount)
            commit.language = languageCode
            awaiting.removeAll { $0.timedOut && Self.seconds($0.sentAt.duration(to: now)) > 4 }
            awaiting.append(commit)
            outbox.append(commit)
            newSegmentLocked()
            let gen = generation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(ScribeSession.commitTimeout))
                self?.commitTimedOut(commit, generation: gen)
            }
            return
        }

        guard let first = firstWordsAt else { return }
        let spoken = Self.seconds(first.duration(to: now))
        let overlapped = lastPlaybackSample >= firstWordsSample - Self.overlapLookback

        // 1. Simultaneous live clause cut while the speaker is still talking (no Scribe commit needed).
        if let cut = Self.clauseCut(in: partial, previousTokens: previousTailTokens, spoken: spoken, stale: stale,
                                    quiet: quiet, voiced: levels.voiced, settings: settings) {
            let fullWords = Self.normalizedWords(fullPartial)
            let remWords = Self.normalizedWords(cut.remainder)
            if !fullWords.isEmpty, fullWords.count >= remWords.count {
                emittedWords = Array(fullWords.prefix(fullWords.count - remWords.count))
            } else {
                emittedWords.append(contentsOf: Self.normalizedWords(cut.clause))
            }
            let fullCJK = Self.cjkCount(fullPartial)
            let remCJK = Self.cjkCount(cut.remainder)
            emittedCJKCount = fullCJK >= remCJK ? (fullCJK - remCJK) : (emittedCJKCount + Self.cjkCount(cut.clause))

            number += 1
            let clause = Commit(number: number, sentAt: now, reason: .clause, fallback: cut.clause,
                                speechSeconds: spoken, loudestDB: segmentLoudest, overlapped: overlapped,
                                isContinuation: emittedInUtterance > 0, continues: true,
                                emittedWords: [], emittedCJKCount: 0)
            clause.text = cut.clause
            clause.language = languageCode
            clause.answered = true
            clause.resolved = true
            outbox.append(clause)
            flushLocked(&out)
            emittedInUtterance += 1
            partial = cut.remainder
            let remainderTokens = Self.normalizedWords(cut.remainder)
            previousTailTokens = remainderTokens
            currentTailTokens = remainderTokens
            tokensSnapshotAt = now
            partialChangedAt = now
            if cut.remainder.isEmpty {
                firstWordsAt = nil
                segmentLoudest = -120
            } else {
                firstWordsAt = now
                firstWordsSample = sampleClock
            }
            out.append(.partial(cut.remainder))
            return
        }

        // 2. End of utterance (pause, sentence end, or segment length cap): commit on Scribe.
        let sentence = Transcriber.endsSentence(partial)
        let detected = levels.voiced && stale >= 0.16
        let reason: CutReason?
        if spoken >= settings.segmentCap {
            reason = .cap
        } else if detected, sentence, quiet >= settings.sentencePause {
            reason = .sentence
        } else if detected, quiet >= settings.pause {
            reason = .pause
        } else if sentence, stale >= settings.noNewWordsAfterSentence {
            reason = .sentence
        } else if stale >= settings.noNewWords {
            reason = .pause
        } else {
            reason = nil
        }
        guard let reason, let session, session.commitSegment() else { return }
        number += 1
        let commit = Commit(number: number, sentAt: now, reason: reason, fallback: partial, speechSeconds: spoken,
                            loudestDB: segmentLoudest, overlapped: overlapped,
                            isContinuation: emittedInUtterance > 0, continues: false,
                            emittedWords: emittedWords, emittedCJKCount: emittedCJKCount)
        commit.language = languageCode
        // Commits whose answer never came (their last partial stood) are forgotten once they're old.
        awaiting.removeAll { $0.timedOut && Self.seconds($0.sentAt.duration(to: now)) > 4 }
        awaiting.append(commit)
        outbox.append(commit)
        newSegmentLocked()
        out.append(.partial(""))
        let gen = generation
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ScribeSession.commitTimeout))
            self?.commitTimedOut(commit, generation: gen)
        }
    }

    private func committedLocked(_ text: String, _ out: inout [Event]) {
        let now = clock.now
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let head = awaiting.first {
            awaiting.removeFirst()
            guard !head.timedOut else {
                // Late: its last partial already stood.
                lastAnswered = nil
                return
            }
            head.answered = true
            head.commitSeconds = Self.seconds(head.sentAt.duration(to: now))
            let tail = cleaned.isEmpty ? head.fallback
                : Self.unemittedTail(from: cleaned, emittedWords: head.emittedWords, emittedCJKCount: head.emittedCJKCount)
            head.text = tail.isEmpty && !head.fallback.isEmpty ? head.fallback : tail
            if (head.text ?? "").isEmpty {
                head.resolved = true
            } else {
                waitForLanguageLocked(head)
            }
        } else {
            // ElevenLabs committed by itself (about 36 s of audio with no commit).
            let raw = cleaned.isEmpty ? fullPartial : cleaned
            let words = Self.unemittedTail(from: raw, emittedWords: emittedWords, emittedCJKCount: emittedCJKCount)
            guard !words.isEmpty else {
                newSegmentLocked()
                return
            }
            number += 1
            let commit = Commit(number: number, sentAt: now, reason: .server, fallback: words,
                                speechSeconds: firstWordsAt.map { Self.seconds($0.duration(to: now)) } ?? 0,
                                loudestDB: segmentLoudest,
                                overlapped: lastPlaybackSample >= firstWordsSample - Self.overlapLookback,
                                isContinuation: emittedInUtterance > 0, continues: false,
                                emittedWords: emittedWords, emittedCJKCount: emittedCJKCount)
            commit.language = languageCode
            commit.answered = true
            commit.text = words
            outbox.append(commit)
            newSegmentLocked()
            out.append(.partial(""))
            waitForLanguageLocked(commit)
        }
        flushLocked(&out)
    }

    private func waitForLanguageLocked(_ commit: Commit) {
        if let languageCode {
            commit.language = languageCode
            commit.resolved = true
            return
        }
        lastAnswered = commit
        let grace = commit.isContinuation ? Self.continuationLanguageGrace : Self.languageGrace
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.languageGraceOver(commit)
        }
    }

    private func languageDetected(_ code: String, generation gen: Int) {
        var out: [Event] = []
        lock.withLock {
            guard gen == generation, !stopped, let commit = lastAnswered, !commit.resolved else { return }
            commit.language = code
            commit.resolved = true
            lastAnswered = nil
            flushLocked(&out)
        }
        emit(out)
    }

    private func languageGraceOver(_ commit: Commit) {
        var out: [Event] = []
        lock.withLock {
            guard !stopped, !commit.resolved else { return }
            commit.resolved = true
            if lastAnswered === commit { lastAnswered = nil }
            flushLocked(&out)
        }
        emit(out)
    }

    private func commitTimedOut(_ commit: Commit, generation gen: Int) {
        var out: [Event] = []
        lock.withLock {
            guard gen == generation, !stopped, !commit.answered, !commit.resolved else { return }
            commit.timedOut = true
            commit.text = commit.fallback
            commit.resolved = true
            flushLocked(&out)
            decideLocked(&out)
        }
        emit(out)
    }

    /// Hands out the finished segments at the front, in order.
    private func flushLocked(_ out: inout [Event]) {
        while let first = outbox.first, first.resolved {
            outbox.removeFirst()
            let text = first.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty {
                if first.isContinuation, !first.continues {
                    out.append(.segment(Segment(number: first.number, text: "", language: first.language,
                                                reason: first.reason, speechSeconds: first.speechSeconds,
                                                commitSeconds: first.commitSeconds, loudestDB: first.loudestDB,
                                                overlappedPlayback: first.overlapped, isContinuation: true,
                                                continues: false)))
                }
                continue
            }
            let segmentNumber: Int
            if first.number > 0 {
                segmentNumber = first.number
            } else {
                number += 1
                segmentNumber = number
            }
            out.append(.segment(Segment(number: segmentNumber, text: text, language: first.language, reason: first.reason,
                                        speechSeconds: first.speechSeconds, commitSeconds: first.commitSeconds,
                                        loudestDB: first.loudestDB, overlappedPlayback: first.overlapped,
                                        isContinuation: first.isContinuation, continues: first.continues)))
        }
    }

    private func newSegmentLocked() {
        fullPartial = ""
        partial = ""
        firstWordsAt = nil
        segmentLoudest = -120
        emittedWords.removeAll(keepingCapacity: true)
        emittedCJKCount = 0
        emittedInUtterance = 0
        previousTailTokens.removeAll(keepingCapacity: true)
        currentTailTokens.removeAll(keepingCapacity: true)
        levels.newSegment()
        replay.removeAll(keepingCapacity: true)
    }

    private func emit(_ out: [Event], finish: Bool = false) {
        for event in out { continuation.yield(event) }
        if finish { continuation.finish() }
    }

    // MARK: Live Clause Cutting & Alignment

    private static let clausePunctuation: Set<Character> = [
        ".", "?", "!", "…", ",", ";", ":", "—", "–", "،", "、", "。", "？", "！", "；", "：",
    ]

    private static let leadingPunctuation: Set<Character> = [
        ".", "?", "!", "…", ",", ";", ":", "—", "–", "-", "،", "、", "。", "？", "！", "；", "：",
    ]

    /// Words that naturally start a new clause when cutting a long unpunctuated run.
    private static let clauseStarters: Set<String> = [
        // English
        "and", "but", "because", "so", "or", "since", "while", "when", "where", "if", "although", "though", "that", "which",
        // French
        "et", "mais", "parce", "donc", "car", "ou", "quand", "comme", "si", "puisque", "lorsque", "tandis", "qui", "que", "où", "pour",
        // German
        "und", "aber", "weil", "denn", "oder", "wenn", "als", "obwohl", "während", "dass", "damit", "wo",
        // Spanish
        "y", "pero", "porque", "aunque", "cuando", "donde", "mientras", "si", "como", "para", "que",
        // Italian
        "e", "ma", "perche", "quando", "mentre", "se", "come", "dove", "che",
        // Portuguese
        "mas", "porque", "quando", "onde", "enquanto", "como",
        // Romanian
        "si", "dar", "pentru", "cand", "unde", "daca", "deoarece", "fiindca", "ca",
    ]

    private struct WordSlice {
        let range: Range<String.Index>
        let norm: String
    }

    /// Strips the prefix already emitted as live `.clause` segments from Scribe's cumulative transcript.
    static func unemittedTail(from full: String, emittedWords: [String], emittedCJKCount: Int) -> String {
        let cleaned = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }
        guard !emittedWords.isEmpty || emittedCJKCount > 0 else { return cleaned }

        if emittedCJKCount > 0, isMostlyUnspacedCJK(cleaned) {
            var seen = 0
            var cutIndex = cleaned.startIndex
            for index in cleaned.indices {
                if isUnspacedScript(cleaned[index]) {
                    seen += 1
                    if seen >= emittedCJKCount {
                        cutIndex = cleaned.index(after: index)
                        break
                    }
                }
            }
            if seen < emittedCJKCount { return "" }
            return trimClauseLead(String(cleaned[cutIndex...]))
        }

        let slices = wordSlices(in: cleaned)
        guard !slices.isEmpty else { return "" }
        let target = emittedWords.count
        guard target > 0 else { return cleaned }

        let low = max(0, target - 8)
        let high = min(slices.count - 1, target + 8)
        var bestEnd: Int?

        if low <= high {
            let lastNorm = emittedWords[target - 1]
            let prevNorm = target >= 2 ? emittedWords[target - 2] : nil
            let prev2Norm = target >= 3 ? emittedWords[target - 3] : nil
            // 1. Exact three-word suffix match closest to `target - 1`.
            if let prevNorm, let prev2Norm {
                var bestDistance = Int.max
                for idx in low...high where idx >= 2 {
                    if slices[idx].norm == lastNorm && slices[idx - 1].norm == prevNorm
                        && slices[idx - 2].norm == prev2Norm {
                        let distance = abs(idx - (target - 1))
                        if distance < bestDistance {
                            bestDistance = distance
                            bestEnd = idx
                        }
                    }
                }
            }
            // 2. Exact two-word suffix match closest to `target - 1`.
            if bestEnd == nil, let prevNorm {
                var bestDistance = Int.max
                for idx in low...high where idx >= 1 {
                    if slices[idx].norm == lastNorm && slices[idx - 1].norm == prevNorm {
                        let distance = abs(idx - (target - 1))
                        if distance < bestDistance {
                            bestDistance = distance
                            bestEnd = idx
                        }
                    }
                }
            }
            // 3. Single-word suffix match closest to `target - 1`.
            if bestEnd == nil {
                var bestDistance = Int.max
                for idx in low...high where slices[idx].norm == lastNorm {
                    let distance = abs(idx - (target - 1))
                    if distance < bestDistance {
                        bestDistance = distance
                        bestEnd = idx
                    }
                }
            }
        }

        let endIndex = bestEnd ?? (target - 1)
        guard endIndex < slices.count - 1 else { return "" }
        let tailStart = slices[endIndex].range.upperBound
        return trimClauseLead(String(cleaned[tailStart...]))
    }

    /// Returns `(clause, remainder)` when the unemitted partial has a stabilized clause ready to translate right away.
    static func clauseCut(in text: String, previousTokens: [String], spoken: Double, stale: Double,
                          quiet: Double, voiced: Bool, settings: Settings) -> (clause: String, remainder: String)? {
        guard spoken >= settings.clauseMinimumSeconds else { return nil }
        let slices = wordSlices(in: text)
        let cjk = cjkCount(text)

        // 1. Clause or sentence punctuation (comma, semicolon, period, question mark…) once ≥ 3 words (or ≥ 8 CJK
        // characters) precede it and either Scribe has moved on to the next word or the speaker paused briefly.
        if slices.count >= 3 || cjk >= 8 {
            if let cut = punctuationClauseCut(in: text, slices: slices, stale: stale, quiet: quiet,
                                              voiced: voiced, settings: settings) {
                return cut
            }
        }

        // 2. Rolling word-horizon cut during continuous unpunctuated speech: once `clauseHorizonSeconds` has elapsed
        // and at least `clauseHorizonWords` leading words have stabilized with ≥ 2 lookahead words after them.
        guard spoken >= settings.clauseHorizonSeconds else { return nil }
        if cjk >= 14, isMostlyUnspacedCJK(text), stale >= 0.15 {
            // Unspaced script: cut at ~10 CJK characters leaving at least 4 characters of lookahead.
            var seen = 0
            for index in text.indices {
                if isUnspacedScript(text[index]) {
                    seen += 1
                    if seen == 10 {
                        let next = text.index(after: index)
                        let clause = String(text[..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let remainder = trimClauseLead(String(text[next...]))
                        if !clause.isEmpty, !remainder.isEmpty { return (clause, remainder) }
                        break
                    }
                }
            }
        }

        let lookahead = stale >= 0.28 ? 1 : 2
        guard slices.count >= settings.clauseHorizonWords + lookahead else { return nil }
        var agreed = 0
        let limit = min(slices.count - lookahead, previousTokens.count)
        while agreed < limit, slices[agreed].norm == previousTokens[agreed] {
            agreed += 1
        }
        // During fast non-stop speech (a video or lecture), Scribe emits partials every ~100 ms and may refine the
        // first word: words sitting at least 3 lookahead words behind Scribe's frontier are already settled.
        if slices.count >= settings.clauseHorizonWords + 3 {
            agreed = max(agreed, slices.count - 3)
        } else if stale >= 0.28 {
            agreed = max(agreed, slices.count - lookahead)
        }
        guard agreed >= settings.clauseHorizonWords else { return nil }

        // Prefer cutting right before a natural conjunction or clause starter near the end of the stabilized prefix.
        let minWords = max(4, settings.clauseHorizonWords - 1)
        let maxWords = min(agreed, settings.clauseHorizonWords + 3)
        var chosenCount = maxWords
        if minWords < maxWords {
            for candidate in (minWords..<maxWords).reversed() {
                if clauseStarters.contains(slices[candidate].norm) {
                    chosenCount = candidate
                    break
                }
            }
        }
        let splitAt = slices[chosenCount - 1].range.upperBound
        let clause = String(text[..<splitAt]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = trimClauseLead(String(text[splitAt...]))
        guard !clause.isEmpty else { return nil }
        return (clause, remainder)
    }

    private static func punctuationClauseCut(in text: String, slices: [WordSlice], stale: Double, quiet: Double,
                                             voiced: Bool, settings: Settings) -> (clause: String, remainder: String)? {
        var bestSplit: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if clausePunctuation.contains(ch) {
                // Skip decimal/thousands separators inside numbers (e.g. "3,5" or "12.30").
                let prevIsDigit = index > text.startIndex && text[text.index(before: index)].isNumber
                let nextIndex = text.index(after: index)
                let nextIsDigit = nextIndex < text.endIndex && text[nextIndex].isNumber
                if !(prevIsDigit && nextIsDigit) {
                    var endOfPunct = nextIndex
                    while endOfPunct < text.endIndex,
                          clausePunctuation.contains(text[endOfPunct]) || text[endOfPunct] == "\"" || text[endOfPunct] == "”" {
                        endOfPunct = text.index(after: endOfPunct)
                    }
                    let prefix = String(text[..<endOfPunct])
                    let prefixWords = slices.filter { $0.range.upperBound <= endOfPunct }.count
                    let prefixCJK = cjkCount(prefix)
                    let isMidSentenceMark = ch == "," || ch == ";" || ch == ":" || ch == "—" || ch == "–"
                        || ch == "،" || ch == "、" || ch == "；" || ch == "："
                    let minWords = isMidSentenceMark ? 6 : 5
                    let minCJK = isMidSentenceMark ? 14 : 10
                    if prefixWords >= minWords || prefixCJK >= minCJK {
                        let remainder = trimClauseLead(String(text[endOfPunct...]))
                        let hasLookahead = !remainder.isEmpty
                        let settledPause = (voiced && quiet >= settings.clausePause) || stale >= settings.clausePause
                        // Cut locally without resetting Scribe whenever Scribe has already moved on to the next word
                        // after the punctuation, or when the speaker paused briefly at the mark.
                        if hasLookahead || settledPause {
                            bestSplit = endOfPunct
                        }
                    }
                    index = endOfPunct
                    continue
                }
            }
            index = text.index(after: index)
        }
        guard let split = bestSplit else { return nil }
        let clause = String(text[..<split]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = trimClauseLead(String(text[split...]))
        guard !clause.isEmpty else { return nil }
        return (clause, remainder)
    }

    private static func trimClauseLead(_ text: String) -> String {
        var slice = Substring(text)
        while let first = slice.first, first.isWhitespace || leadingPunctuation.contains(first) {
            slice.removeFirst()
        }
        return String(slice).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWordSeparator(_ ch: Character) -> Bool {
        ch.isWhitespace || ch == "-" || ch == "'" || ch == "’"
    }

    private static func wordSlices(in text: String) -> [WordSlice] {
        var result: [WordSlice] = []
        var tokenStart: String.Index?
        for index in text.indices {
            if !isWordSeparator(text[index]) {
                if tokenStart == nil { tokenStart = index }
            } else if let start = tokenStart {
                // Include trailing punctuation attached to the last sub-word when the separator is whitespace.
                let range = start..<index
                let norm = normalizeWord(String(text[range]))
                if !norm.isEmpty { result.append(WordSlice(range: range, norm: norm)) }
                tokenStart = nil
            }
        }
        if let start = tokenStart {
            let range = start..<text.endIndex
            let norm = normalizeWord(String(text[range]))
            if !norm.isEmpty { result.append(WordSlice(range: range, norm: norm)) }
        }
        return result
    }

    static func normalizedWords(_ text: String) -> [String] {
        wordSlices(in: text).map(\.norm)
    }

    private static func normalizeWord(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func cjkCount(_ text: String) -> Int {
        text.filter(isUnspacedScript).count
    }

    private static func isMostlyUnspacedCJK(_ text: String) -> Bool {
        let cjk = cjkCount(text)
        return cjk >= 4 && !text.contains(" ")
    }

    private static func isUnspacedScript(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0x0E00...0x0E7F).contains(scalar.value)
        }
    }

    // MARK: Helpers

    private static func level(_ samples: ArraySlice<Int16>) -> Double {
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        let rms = (sum / Double(max(1, samples.count))).squareRoot()
        return 20 * log10(max(rms, 1) / 32768)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    private final class Commit {
        let number: Int
        let sentAt: ContinuousClock.Instant
        let reason: CutReason
        let fallback: String
        let speechSeconds: Double
        let loudestDB: Double
        let overlapped: Bool
        let isContinuation: Bool
        let continues: Bool
        let emittedWords: [String]
        let emittedCJKCount: Int
        var text: String?
        var language: String?
        var commitSeconds: Double?
        /// The committed transcript arrived.
        var answered = false
        /// It didn't in time: the last partial stood.
        var timedOut = false
        /// Ready to hand out.
        var resolved = false

        init(number: Int, sentAt: ContinuousClock.Instant, reason: CutReason, fallback: String, speechSeconds: Double,
             loudestDB: Double, overlapped: Bool, isContinuation: Bool, continues: Bool,
             emittedWords: [String], emittedCJKCount: Int) {
            self.number = number
            self.sentAt = sentAt
            self.reason = reason
            self.fallback = fallback
            self.speechSeconds = speechSeconds
            self.loudestDB = loudestDB
            self.overlapped = overlapped
            self.isContinuation = isContinuation
            self.continues = continues
            self.emittedWords = emittedWords
            self.emittedCJKCount = emittedCJKCount
        }
    }

    /// The same small level detector as `VoiceActivity` (a frame is voice 10 dB above a floor that follows the quietest
    /// frames, and above -58 dBFS; two in a row reset the quiet), plus gated frames, which count as quiet and leave
    /// the floor alone (they're zeros).
    private struct Levels {
        static let marginDB = 10.0
        static let minimumDB = -58.0
        static let floorRisePerFrame = 0.02

        var floorDB = -60.0
        var started = false
        var run = 0
        /// Audio since the last voice, in samples.
        var silenceSamples = 0
        /// Voice was heard since the segment began.
        var voiced = false

        mutating func frame(_ level: Double, samples: Int) {
            if !started {
                started = true
                floorDB = level
            } else if level < floorDB {
                floorDB = level
            } else {
                floorDB += Self.floorRisePerFrame
            }
            if level > floorDB + Self.marginDB, level > Self.minimumDB {
                run += 1
                if run >= 2 {
                    voiced = true
                    silenceSamples = 0
                    return
                }
            } else {
                run = 0
            }
            silenceSamples += samples
        }

        mutating func gated(_ samples: Int) {
            run = 0
            silenceSamples += samples
        }

        mutating func newSegment() {
            voiced = false
        }
    }
}
