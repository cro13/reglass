import Foundation

/// One running timer for the glasses' own scheduler, which chimes it without the phone.
public struct GlassesTimer: Sendable, Equatable {
    /// The app's id for it, at most 127 UTF-8 bytes (a lowercase UUID). The glasses' alert is matched back by it.
    public let id: String
    /// What it's for ("food"), at most 255 UTF-8 bytes. Goes to the glasses; never logged.
    public let title: String
    /// When it was set. Stays the same in every list, so a late list runs only the time left.
    public let start: Date
    public let duration: TimeInterval

    public var due: Date { start.addingTimeInterval(duration) }

    public init(id: String, title: String, start: Date, duration: TimeInterval) {
        self.id = id
        self.title = title
        self.start = start
        self.duration = duration
    }
}

/// The glasses rang a timer and sent an alert in assistant turn message 6.
public struct GlassesTimerAlert: Sendable, Equatable {
    /// The timer's id when the alert named one of the timers last sent; nil when it didn't (match on due time then).
    public let id: String?
    public let at: Date
}

/// The glasses' timers on one connection (svc15 message 1100; see `TimerListMessages`).
///
/// The app owns the list: `set` hands over every running timer each time, and ReGlassKit keeps the glasses in step.
/// Each list replaces everything on the glasses (they clear every slot first), holds at most eight timers and is lost
/// when they restart, so ReGlassKit sends the whole list whenever it changed and again at every registration of the
/// assistant (each reconnect), always leaving out timers already due or due within a second.
///
/// **While a voice turn is open the list waits** and goes out the moment the turn ends. Only lists sent with no turn
/// open are proven on the device; the firmware's dispatcher hands 1100 to the scheduler whatever the turn is doing,
/// but nothing shows the glasses' assistant tolerates it mid-turn, beside a reply streaming in real time. Waiting
/// costs nothing: a timer's start stays the time it was set, so the glasses run the time left (and one already due by
/// then is left out, for the app to announce itself). Turn-less pushes (announcements) don't hold the list: they're
/// short and nothing would wake the list after them.
///
/// Logs carry counts and states only, never titles.
public final class GlassesTimers: Sendable {
    private let service: AssistantService

    private struct State {
        var desired: [GlassesTimer] = []
        /// Bumped by every `set`.
        var version = 0
        /// The app has set a list on this connection: from now on it owns what the glasses hold.
        var owned = false
        /// The version the glasses hold since the current registration (-1: not sent yet).
        var sentVersion = -1
        /// The timers in the last list sent (their alert is matched against them).
        var onGlasses: [GlassesTimer] = []
        var waitLogged = false
        var sink: AsyncStream<GlassesTimerAlert>.Continuation?
        var sinkID = UUID()
        /// Sends run one after another.
        var tail: Task<Void, Never>?
        var stopped = false
    }

    private let state = Locked(State())

    /// Timers due within this are left out of a list: they'd be late before the glasses could act.
    static let leadTime: TimeInterval = 1

    init(service: AssistantService) {
        self.service = service
        service.timerHooks.withLock {
            $0 = TimerHooks(registered: { [weak self] in self?.registered() },
                            turnEnded: { [weak self] in self?.flush() },
                            alert: { [weak self] payload in self?.alert(payload) })
        }
    }

    /// Every timer that should be running, in any order (only the eight due soonest fit on the glasses). Sent at once
    /// when the assistant is registered and no voice turn is open; otherwise when the turn ends or the next link
    /// registers. An empty list clears the glasses' timers.
    public func set(_ timers: [GlassesTimer]) {
        state.withLock { s in
            s.desired = timers
            s.version += 1
            s.owned = true
        }
        flush()
    }

    /// The glasses' alerts, for one consumer, for this connection's life: a new call ends the previous stream.
    public func alerts() -> AsyncStream<GlassesTimerAlert> {
        let (stream, continuation) = AsyncStream.makeStream(of: GlassesTimerAlert.self, bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        let previous = state.withLock { s -> AsyncStream<GlassesTimerAlert>.Continuation? in
            defer {
                s.sink = s.stopped ? nil : continuation
                s.sinkID = id
            }
            return s.sink
        }
        previous?.finish()
        if state.withLock({ $0.stopped }) {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { s in
                    if s.sinkID == id { s.sink = nil }
                }
            }
        }
        return stream
    }

    // MARK: Internal

    /// The connection stopped for good.
    func shutdown() {
        let (sink, tail) = state.withLock { s -> (AsyncStream<GlassesTimerAlert>.Continuation?, Task<Void, Never>?) in
            s.stopped = true
            defer {
                s.sink = nil
                s.tail = nil
            }
            return (s.sink, s.tail)
        }
        tail?.cancel()
        sink?.finish()
    }

    /// A new registration: the glasses may have restarted (slots gone) or kept an older list. Send it again.
    private func registered() {
        state.withLock { $0.sentVersion = -1 }
        flush()
    }

    private func flush() {
        state.withLock { s in
            guard !s.stopped else { return }
            let previous = s.tail
            s.tail = Task { [weak self] in
                await previous?.value
                await self?.sendIfNeeded()
            }
        }
    }

    private func sendIfNeeded() async {
        let now = Date()
        let snapshot = state.withLock { s -> (version: Int, list: [GlassesTimer])? in
            guard s.owned, !s.stopped, s.sentVersion != s.version else { return nil }
            return (s.version, Self.pending(s.desired, now: now))
        }
        guard let snapshot, !Task.isCancelled else { return }
        let payload = TimerListMessages.list(snapshot.list.map(Self.record))
        switch await service.sendTimerList(payload) {
        case .sent:
            state.withLock { s in
                s.onGlasses = snapshot.list
                s.waitLogged = false
                if s.version == snapshot.version { s.sentVersion = snapshot.version }
            }
            kitLog("timers", snapshot.list.isEmpty ? "no timers; the glasses' list cleared"
                     : "\(snapshot.list.count) synced to the glasses")
        case .turnOpen:
            let first = state.withLock { s -> Bool in
                defer { s.waitLogged = true }
                return !s.waitLogged
            }
            if first { kitLog("timers", "the list waits until the voice turn ends") }
        case .unavailable:
            break   // sent when the assistant next registers
        }
    }

    /// Finds which timer rang if the alert names one of the IDs sent.
    private func alert(_ payload: [UInt8]) {
        let (candidates, sink) = state.withLock { s in (s.onGlasses + s.desired, s.sink) }
        let match = candidates.first { !$0.id.isEmpty && payload.contains(subsequence: Array($0.id.utf8)) }
        kitLog("timers", "the glasses rang a timer (\(match == nil ? "not named in the alert" : "named in the alert"))")
        sink?.yield(GlassesTimerAlert(id: match?.id, at: Date()))
    }

    /// The timers that go in a list: not yet due, soonest first, at most eight.
    static func pending(_ timers: [GlassesTimer], now: Date) -> [GlassesTimer] {
        Array(timers.filter { $0.due.timeIntervalSince(now) > leadTime }
            .sorted { $0.due < $1.due }
            .prefix(TimerListMessages.maxRecords))
    }

    static func record(_ timer: GlassesTimer) -> [UInt8] {
        TimerListMessages.runningTimer(id: timer.id, title: timer.title,
                                       durationMs: Int64((timer.duration * 1000).rounded()),
                                       startEpochMs: TimerListMessages.epochMs(timer.start))
    }
}

/// How the assistant service tells the timers what happened on svc15.
struct TimerHooks: Sendable {
    /// The assistant registered on a link (every reconnect, and after the glasses closed its channels).
    let registered: @Sendable () -> Void
    /// A voice turn ended: a list waiting for it can go.
    let turnEnded: @Sendable () -> Void
    /// Matches the timer that rang using the alert payload from the glasses. The payload stays out of logs.
    let alert: @Sendable ([UInt8]) -> Void
}
