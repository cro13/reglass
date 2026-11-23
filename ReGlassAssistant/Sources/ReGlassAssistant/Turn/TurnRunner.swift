import Foundation

/// One request to answer.
public struct TurnRequest: Sendable {
    public var transcript: String
    /// The conversation so far, exactly as sent and received. Follow-ups reuse the previous outcome's
    /// `conversation` and its pinned route settings.
    public var conversation: ClaudeConversation
    public var context: ClaudeTurnContext
    /// How many instructions `transcript` holds (`Addressing`: the user said ReGlass's name partway through). With more
    /// than one, the turn takes the standard route, runs each round's tool calls one after another in the calls'
    /// order, and speaks tools' own words as they come without ending the turn, so every instruction gets done.
    public var instructions: Int

    public init(transcript: String, conversation: ClaudeConversation = ClaudeConversation(), context: ClaudeTurnContext,
                instructions: Int = 1) {
        self.transcript = transcript
        self.conversation = conversation
        self.context = context
        self.instructions = instructions
    }
}

/// What happens during a turn, for the chat record and the screen. Queries and text are for those only, never the
/// log.
public enum TurnEvent: Sendable {
    /// Which route (quick or standard) and settings the request uses.
    case routed(EffortRouter.Decision)
    case searchStarted(id: String, query: String)
    case searchFinished(id: String, resultCount: Int)
    /// `reason` is a plain sentence ("The search service was busy.").
    case searchFailed(id: String, reason: String)
    /// Claude is reading a web page (web fetch). `url` is for the chat record and the screen only, never the log.
    case fetchStarted(id: String, url: String)
    case fetchFinished(id: String, url: String)
    /// `reason` is a plain sentence ("The page couldn't be opened.").
    case fetchFailed(id: String, reason: String)
    /// Claude called an iPhone tool (`name` as defined, e.g. "set_timer"); it's running now. Calls of one round start
    /// together and run concurrently.
    case toolStarted(id: String, name: String)
    /// The call finished, worked or not (`result.isError`). Chats shows `result.action`, or the tool's name without
    /// one. `result.content` is for Claude only: never show or log it.
    case toolFinished(id: String, name: String, result: ToolResult)
    /// A sentence handed to the voice, as it will be spoken.
    case sentence(String)
    /// The first reply audio exists (the moment to dip other audio).
    case firstAudio
    /// Which voice is speaking (again whenever it changes, e.g. a fallback).
    case voice(VoiceRoute)
    case finished(TurnOutcome)
}

public struct TurnOutcome: Sendable {
    public enum Kind: Sendable, Equatable {
        case answered
        /// Claude declined; a short note was spoken.
        case refused
        /// The reply hit its length limit.
        case cutShort
        /// Claude returned nothing to say.
        case empty
        /// Claude or the network failed; an apology was spoken in the fallback voice.
        case failed(ClaudeError)
        case cancelled
    }

    public let kind: Kind
    /// Everything handed to the voices, apology included: what was actually spoken.
    public let spokenText: String
    public let firstTextAfter: TimeInterval?
    public let firstAudioAfter: TimeInterval?
    public let audioSeconds: TimeInterval
    public let usage: ClaudeUsage?
    /// The conversation including this turn (nil when Claude didn't complete it): what a follow-up replays.
    public let conversation: ClaudeConversation?
}

/// A running turn: consume `audio` (to the glasses or the phone) and `events` (for the record). `cancel` stops
/// Claude and the voice at once.
public final class TurnRun: Sendable {
    public let events: AsyncStream<TurnEvent>
    public let audio: AsyncThrowingStream<[Int16], Error>
    private let task: Task<Void, Never>

    init(events: AsyncStream<TurnEvent>, audio: AsyncThrowingStream<[Int16], Error>, task: Task<Void, Never>) {
        self.events = events
        self.audio = audio
        self.task = task
    }

    public func cancel() {
        task.cancel()
    }
}

/// Transcript → Claude (streamed, with web search and the iPhone tools) → sentence chunker → spoken-text cleanup →
/// voice → PCM.
///
/// The voice starts on Claude's first sentence while the rest is still streaming. If Claude or the network fails,
/// a short apology follows in the fallback voice; refusals and cut-off replies get a short note in the main voice.
///
/// The tool loop: the iPhone tools are fetched once per turn from `tools` and sent with every request of the turn
/// (a continuing conversation keeps the definitions its first request pinned). When Claude stops for tool use, any
/// lead-in sentence is spoken at once, the round's calls run concurrently (each gets `toolTimeout`; a timeout becomes
/// a failure result), their results go back in one user message in the calls' order, and Claude continues. At most
/// `maxToolRounds` rounds per turn. When every call of a round returns a `spokenReply` (a tool that answers in its own
/// words), those words are spoken as the reply and the turn ends there. Everything honours cancellation (a new wake,
/// the link dropping, Stop).
public final class TurnRunner: Sendable {
    private let claude: ClaudeClient
    private let voice: any Voice
    private let fallbackVoice: any Voice
    private let tools: (any ToolProvider)?

    public init(claude: ClaudeClient, voice: any Voice, fallbackVoice: any Voice, tools: (any ToolProvider)? = nil) {
        self.claude = claude
        self.voice = voice
        self.fallbackVoice = fallbackVoice
        self.tools = tools
    }

    public func start(_ request: TurnRequest, tuning: AssistantTuning = .current) -> TurnRun {
        let (events, eventSink) = AsyncStream<TurnEvent>.makeStream()
        let (audio, audioSink) = AsyncThrowingStream<[Int16], Error>.makeStream()
        let task = Task {
            await self.run(request, tuning: tuning, events: eventSink, audio: audioSink)
        }
        audioSink.onTermination = { termination in
            // The audio's consumer went away (the link dropped, playback stopped): stop working on the turn.
            if case .cancelled = termination { task.cancel() }
        }
        return TurnRun(events: events, audio: audio, task: task)
    }

    // MARK: Private

    private func run(_ request: TurnRequest, tuning: AssistantTuning, events: AsyncStream<TurnEvent>.Continuation,
                     audio: AsyncThrowingStream<[Int16], Error>.Continuation) async {
        let watch = Stopwatch()
        var decision = EffortRouter(tuning: tuning).decide(request.transcript)
        let several = request.instructions > 1
        if several {
            decision = EffortRouter.Decision(route: .standard, reason: "\(request.instructions) instructions",
                                             settings: tuning.standard)
        }
        if let pinned = request.conversation.settings {
            // A continuing conversation keeps its first turn's settings (cache and thinking blocks stay valid).
            decision = EffortRouter.Decision(route: decision.route, reason: "conversation", settings: pinned)
        }
        events.yield(.routed(decision))
        AssistantLog.add("Turn: \(decision.route.rawValue) route (\(decision.reason)), \(decision.settings.logDescription)")

        // The voice runs alongside Claude, fed sentence by sentence.
        let (sentences, sentenceSink) = AsyncStream<String>.makeStream()
        let replyAudio = ReplyAudio(watch: watch, sink: audio)
        let voice = self.voice
        let voiceTask = Task { () -> Error? in
            do {
                for try await chunk in voice.speak(sentences, onRoute: { events.yield(.voice($0)) }) {
                    if replyAudio.speak(chunk) { events.yield(.firstAudio) }
                }
                return nil
            } catch {
                return error
            }
        }

        var spoken: [String] = []
        var spokenCharacters = 0
        var capped = false
        func say(_ piece: String) {
            let text = SpokenText.clean(piece)
            guard !text.isEmpty, !capped else { return }
            // The hard stop: no sentence starts once the reply would run past about 30 s of speech. The prompt asks
            // for about 20 s; this catches answers that ignore it. The first sentence always goes.
            if !spoken.isEmpty,
               Double(spokenCharacters + text.count) / Self.charactersPerSecond > Self.maxSpokenSeconds {
                capped = true
                AssistantLog.add("Turn: reply stopped at about \(Int(Self.maxSpokenSeconds)) s of speech")
                return
            }
            spokenCharacters += text.count
            spoken.append(text)
            replyAudio.release()
            sentenceSink.yield(text)
            events.yield(.sentence(text))
        }

        // The iPhone tools for this turn, fetched once so every request of the turn offers the same ones.
        let toolbox = await Toolbox.load(from: tools)

        var chunker = SentenceChunker()
        var completion: ClaudeCompletion?
        var failure: ClaudeError?
        var firstTextAfter: TimeInterval?
        var usage = ClaudeUsage()
        /// The conversation so far, tool results included: what the outcome hands to a follow-up.
        var conversation: ClaudeConversation?
        var rounds = 0
        var toolsWorked = 0
        var toolRoundsExhausted = false
        do {
            var stream = claude.respond(to: request.transcript, conversation: request.conversation,
                                        context: request.context, settings: decision.settings,
                                        tools: toolbox.definitions)
            while true {
                completion = nil
                for try await event in stream {
                    switch event {
                    case .text(let text):
                        if firstTextAfter == nil { firstTextAfter = watch.elapsed }
                        for sentence in chunker.add(text) { say(sentence) }
                    case .searchStarted(let id, let query):
                        // Speak any lead-in ("Let me check.") now rather than after the search, and keep the reply
                        // alive while the search runs (ReGlassKit ends a reply after 2.5 s without audio).
                        if let lead = chunker.flush() { say(lead) }
                        replyAudio.hold()
                        events.yield(.searchStarted(id: id, query: query))
                    case .searchFinished(let id, let count):
                        events.yield(.searchFinished(id: id, resultCount: count))
                    case .searchFailed(let id, let code):
                        AssistantLog.add("Web search failed: \(code)")
                        events.yield(.searchFailed(id: id, reason: Self.searchReason(code)))
                    case .fetchStarted(let id, let url):
                        // As for a search: the lead-in now, and the reply kept alive while the page is read.
                        if let lead = chunker.flush() { say(lead) }
                        replyAudio.hold()
                        events.yield(.fetchStarted(id: id, url: url))
                    case .fetchFinished(let id, let url):
                        events.yield(.fetchFinished(id: id, url: url))
                    case .fetchFailed(let id, let code):
                        AssistantLog.add("Web fetch failed: \(code)")
                        events.yield(.fetchFailed(id: id, reason: Self.fetchReason(code)))
                    case .completed(let done):
                        completion = done
                    }
                }
                guard let done = completion else { break }
                usage.add(done.usage)
                conversation = done.conversation
                guard case .toolUse(let calls) = done.stop else { break }

                // Speak any lead-in now rather than after the tools, and keep the reply alive while they run.
                if let lead = chunker.flush() { say(lead) }
                replyAudio.hold()
                var next = done.conversation
                guard rounds < Self.maxToolRounds else {
                    // Answer the calls anyway, so the conversation stays valid for a follow-up.
                    toolRoundsExhausted = true
                    AssistantLog.add("Turn: stopped after \(Self.maxToolRounds) rounds of tool calls")
                    next.appendToolResults(calls.map {
                        ($0, ToolResult.failure("Not run: ReGlass allows \(Self.maxToolRounds) rounds of tool calls per request."))
                    })
                    conversation = next
                    break
                }
                rounds += 1
                var results = await runTools(calls, toolbox: toolbox, context: request.context, inOrder: several,
                                             events: events)
                try Task.checkCancellation()
                toolsWorked += results.filter { !$0.result.isError }.count
                // Several instructions: a tool's own words ("Typed it.") are said at once, and Claude carries on with
                // the rest, told not to say them again. Its reply adds only what's new ("Do Not Disturb is on.").
                if several, results.contains(where: { $0.result.spokenReply != nil }) {
                    results = results.map { item in
                        guard let words = item.result.spokenReply?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !words.isEmpty else { return item }
                        var chunker = SentenceChunker()
                        for sentence in chunker.add(words) { say(sentence) }
                        if let rest = chunker.flush() { say(rest) }
                        var result = item.result
                        result.content += " (Already said to the user: \"\(words)\" Don't say it again.)"
                        result.spokenReply = nil
                        return (call: item.call, result: result)
                    }
                    replyAudio.hold()
                }
                next.appendToolResults(results)
                conversation = next
                // Tools that answer in their own words (`ToolResult.spokenReply`): when every call of the round
                // brought some, those words are the reply. Speak them and end the turn without asking Claude again.
                if let reply = Self.spokenReply(results) {
                    var replyChunker = SentenceChunker()
                    for sentence in replyChunker.add(reply) { say(sentence) }
                    if let rest = replyChunker.flush() { say(rest) }
                    next.appendSpokenReply(reply)
                    conversation = next
                    AssistantLog.add("Turn: the tools' own words were the reply")
                    break
                }
                stream = claude.continueAfterTools(next, settings: decision.settings)
            }
        } catch {
            failure = ClaudeClient.map(error)
        }
        replyAudio.release()
        let turnUsage: ClaudeUsage? = usage == ClaudeUsage() ? nil : usage

        if Task.isCancelled || failure == .cancelled {
            sentenceSink.finish()
            voiceTask.cancel()
            audio.finish(throwing: CancellationError())
            AssistantLog.add("Turn cancelled after \(watch.elapsed.seconds)")
            events.yield(.finished(TurnOutcome(kind: .cancelled, spokenText: spoken.joined(separator: " "),
                                               firstTextAfter: firstTextAfter, firstAudioAfter: replyAudio.firstAudioAfter,
                                               audioSeconds: replyAudio.seconds, usage: turnUsage,
                                               conversation: nil)))
            events.finish()
            return
        }

        // A failure mid-sentence leaves a fragment: drop it rather than speak half a sentence.
        if failure == nil, let rest = chunker.flush() { say(rest) }

        var kind: TurnOutcome.Kind = .answered
        if let failure {
            kind = .failed(failure)
        } else if toolRoundsExhausted {
            kind = .cutShort
            say("Sorry, that needed too many steps. Please try asking for less at once.")
        } else if let completion {
            switch completion.stop {
            case .toolUse:
                break   // handled above

            case .endTurn:
                if spoken.isEmpty, toolsWorked > 0 {
                    say("Done.")   // the tools did it; Claude added nothing to say
                } else if spoken.isEmpty {
                    kind = .empty
                    say("Sorry, I don't have an answer for that.")
                }
            case .refusal(let category):
                kind = .refused
                AssistantLog.add("Claude declined (\(category ?? "no category"))")
                say(spoken.isEmpty ? "Sorry, I can't help with that one." : "Sorry, I can't go on with that.")
            case .maxTokens:
                kind = .cutShort
                if spoken.isEmpty { say("Sorry, that answer got too long. Try asking for less.") }
            case .other(let reason):
                AssistantLog.add("Claude stopped: \(reason)")
                if spoken.isEmpty {
                    kind = .empty
                    say("Sorry, I don't have an answer for that.")
                }
            }
        }
        sentenceSink.finish()
        if let voiceError = await voiceTask.value, !(voiceError is CancellationError) {
            AssistantLog.add("Voice failed (\(type(of: voiceError)))")
        }

        // Claude or the network failed: apologise in the fallback voice, which needs neither.
        if let failure {
            let apology = toolsWorked > 0 ? "Sorry, I lost the connection before I could finish answering."
                : spoken.isEmpty ? failure.spokenApology : "Sorry, I lost the rest of that answer."
            spoken.append(apology)
            events.yield(.sentence(apology))
            do {
                for try await chunk in fallbackVoice.speak(apology, onRoute: { events.yield(.voice($0)) }) {
                    if replyAudio.speak(chunk) { events.yield(.firstAudio) }
                }
            } catch {
                AssistantLog.add("Fallback voice failed (\(type(of: error)))")
            }
        }

        if Task.isCancelled {
            audio.finish(throwing: CancellationError())
        } else {
            audio.finish()
        }
        let outcome = TurnOutcome(kind: kind, spokenText: spoken.joined(separator: " "), firstTextAfter: firstTextAfter,
                                  firstAudioAfter: replyAudio.firstAudioAfter, audioSeconds: replyAudio.seconds,
                                  usage: turnUsage,
                                  // A refused turn isn't carried into a follow-up: re-sending it would likely be
                                  // refused again, and a reply cut off mid-stream may hold an unsigned thinking block.
                                  conversation: failure == nil && kind != .refused
                                      && conversation?.endsWithUnansweredToolUse != true ? conversation : nil)
        AssistantLog.add("Turn timing: first text \(firstTextAfter?.seconds ?? "—"), first audio "
                         + "\(replyAudio.firstAudioAfter?.seconds ?? "—"), \(replyAudio.seconds.seconds) of audio, "
                         + "\(spoken.count) sentence\(spoken.count == 1 ? "" : "s"), "
                         + (rounds > 0 ? "\(rounds) tool round\(rounds == 1 ? "" : "s"), " : "")
                         + "done in \(watch.elapsed.seconds) (\(decision.route.rawValue): \(decision.settings.logDescription))")
        events.yield(.finished(outcome))
        events.finish()
    }

    // MARK: Tools

    /// Runs one round's calls concurrently, or with `inOrder` one after another (several instructions: type, then
    /// change the setting, never both at once), and returns their results in the calls' order.
    private func runTools(_ calls: [ClaudeToolCall], toolbox: Toolbox, context: ClaudeTurnContext, inOrder: Bool = false,
                          events: AsyncStream<TurnEvent>.Continuation) async -> [(call: ClaudeToolCall, result: ToolResult)] {
        let toolContext = ToolContext(surface: context.surface, date: context.date, timeZone: context.timeZone)
        let watch = Stopwatch()
        let timeout = Self.toolTimeout
        if inOrder, calls.count > 1 {
            var results: [(call: ClaudeToolCall, result: ToolResult)] = []
            for call in calls {
                if Task.isCancelled {
                    results.append((call: call, result: .failure("Not run: the request was stopped.")))
                    continue
                }
                events.yield(.toolStarted(id: call.id, name: call.name))
                let result = await ToolCall.run(call, tool: toolbox.byName[call.name], context: toolContext, timeout: timeout)
                events.yield(.toolFinished(id: call.id, name: call.name, result: result))
                results.append((call: call, result: result))
            }
            let failed = results.filter(\.result.isError).count
            AssistantLog.add("Tools in order: \(calls.map(\.name).joined(separator: ", ")) in \(watch.elapsed.seconds)"
                             + (failed > 0 ? " (\(failed) failed)" : ""))
            return results
        }
        for call in calls { events.yield(.toolStarted(id: call.id, name: call.name)) }
        let results = await withTaskGroup(of: (Int, ToolResult).self) { group -> [ToolResult] in
            for (index, call) in calls.enumerated() {
                let tool = toolbox.byName[call.name]
                group.addTask {
                    let result = await ToolCall.run(call, tool: tool, context: toolContext, timeout: timeout)
                    events.yield(.toolFinished(id: call.id, name: call.name, result: result))
                    return (index, result)
                }
            }
            var ordered = [ToolResult?](repeating: nil, count: calls.count)
            for await (index, result) in group { ordered[index] = result }
            return ordered.map { $0 ?? .failure("The tool didn't run.") }
        }
        let failed = results.filter(\.isError).count
        AssistantLog.add("Tools: \(calls.map(\.name).joined(separator: ", ")) in \(watch.elapsed.seconds)"
                         + (failed > 0 ? " (\(failed) failed)" : ""))
        return zip(calls, results).map { (call: $0, result: $1) }
    }

    /// The longest a spoken reply may run (about 20 s, hard stop at 30 s).
    static let maxSpokenSeconds: Double = 30
    /// The voice's speaking rate, roughly: about 150 words a minute.
    static let charactersPerSecond: Double = 15
    /// Rounds of tool calls per turn; Claude is stopped after that.
    static let maxToolRounds = 6
    /// Each tool call's limit; the glasses keep waiting (keep-alives every 3 s) and the whole reply has 75 s per request.
    static let toolTimeout: Duration = .seconds(10)

    /// The round's spoken replies joined in the calls' order, when every call brought one; nil otherwise.
    static func spokenReply(_ results: [(call: ClaudeToolCall, result: ToolResult)]) -> String? {
        let replies = results.map { $0.result.spokenReply?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        guard !replies.isEmpty, !replies.contains(where: \.isEmpty) else { return nil }
        return replies.joined(separator: " ")
    }

    static func searchReason(_ code: String) -> String {
        switch code {
        case "too_many_requests": return "The search service was busy."
        case "max_uses_exceeded": return "ReGlass's limit of three searches per question was reached."
        case "query_too_long": return "The search was too long."
        case "invalid_tool_input": return "The search couldn't be run."
        case "unavailable": return "The search service had a problem."
        default: return "The search didn't work."
        }
    }

    static func fetchReason(_ code: String) -> String {
        switch code {
        case "url_not_accessible": return "The page couldn't be opened."
        case "url_not_allowed": return "That page isn't allowed."
        case "url_not_in_prior_context": return "ReGlass can only read pages already in the conversation."
        case "unsupported_content_type": return "That kind of page can't be read."
        case "content_too_large": return "The document was too large."
        case "too_many_requests": return "The reading service was busy."
        case "max_uses_exceeded": return "ReGlass's limit of three pages per question was reached."
        case "url_too_long", "invalid_tool_input": return "The address couldn't be used."
        case "unavailable": return "The reading service had a problem."
        default: return "The page couldn't be read."
        }
    }
}

/// The reply's audio on its way out: hands it to the turn's audio stream, counts it, notes when the first arrived, and
/// bridges tool rounds.
///
/// ReGlassKit ends a reply once its audio has run dry for 2.5 s (a stalled voice). A lead-in spoken before a tool round
/// can play out well before the next sentence exists (the tools run, then the next request), so while a round holds
/// the stream, real-time silence keeps it alive once the queued speech has nearly played out and the voice has gone
/// quiet. Never before the first audio (ReGlassKit counts no gap then), and at most `maxHold` per round. Speech and
/// silence go out under one lock, so silence can't land inside a sentence.
///
/// `@unchecked Sendable`: all state is behind `lock`.
private final class ReplyAudio: @unchecked Sendable {
    private let lock = NSLock()
    private let watch: Stopwatch
    private let sink: AsyncThrowingStream<[Int16], Error>.Continuation
    private var spokenSamples = 0
    /// Speech and silence handed out.
    private var queuedSamples = 0
    private var first: TimeInterval?
    private var startedAt: ContinuousClock.Instant?
    private var lastSpeechAt: ContinuousClock.Instant?
    private var filler: Task<Void, Never>?
    /// The latest `hold()`: each tool round or search gets its own `maxHold`.
    private var heldAt: ContinuousClock.Instant?

    /// Covers a tool call's 10 s limit plus the next request's thinking.
    static let maxHold: Duration = .seconds(25)
    /// Silence starts once less than this is still queued to play.
    static let lowWater: Double = 0.25
    /// ... and the voice has handed out nothing for this long.
    static let quietFor: Duration = .milliseconds(300)
    static let step: Duration = .milliseconds(100)

    var firstAudioAfter: TimeInterval? { lock.withLock { first } }
    /// Speech only.
    var seconds: TimeInterval { lock.withLock { PCM.replySeconds(spokenSamples) } }

    init(watch: Stopwatch, sink: AsyncThrowingStream<[Int16], Error>.Continuation) {
        self.watch = watch
        self.sink = sink
    }

    /// Hands a chunk of speech out. True for the first audio.
    func speak(_ chunk: [Int16]) -> Bool {
        lock.withLock {
            guard !chunk.isEmpty else { return false }
            let now = ContinuousClock.now
            spokenSamples += chunk.count
            queuedSamples += chunk.count
            lastSpeechAt = now
            sink.yield(chunk)
            guard first == nil else { return false }
            first = watch.elapsed
            startedAt = now
            return true
        }
    }

    /// A tool round or search started: keep the stream alive until `release`, for at most `maxHold` from now.
    func hold() {
        lock.withLock {
            heldAt = .now
            guard filler == nil else { return }
            filler = Task { [weak self] in await self?.fill() }
        }
    }

    /// The next sentence is on its way (or the turn is ending).
    func release() {
        let task: Task<Void, Never>? = lock.withLock {
            defer { filler = nil }
            return filler
        }
        task?.cancel()
    }

    private func fill() async {
        var padded = 0
        defer {
            if padded > 0 { AssistantLog.add("Turn: held the reply open for \(PCM.replySeconds(padded).seconds) during tools") }
        }
        while lock.withLock({ heldAt.map { $0.duration(to: .now) < Self.maxHold } ?? false }) {
            do { try await Task.sleep(for: Self.step) } catch { return }
            lock.withLock {
                guard let startedAt, let lastSpeechAt else { return }
                let now = ContinuousClock.now
                let queued = PCM.replySeconds(queuedSamples) - Self.seconds(startedAt.duration(to: now))
                guard queued < Self.lowWater, lastSpeechAt.duration(to: now) > Self.quietFor else { return }
                let count = Int((Self.lowWater + Self.seconds(Self.step) - max(queued, 0)) * PCM.replyRate)
                guard count > 0 else { return }
                queuedSamples += count
                padded += count
                sink.yield([Int16](repeating: 0, count: count))
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
