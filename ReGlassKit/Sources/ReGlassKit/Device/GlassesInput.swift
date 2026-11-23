import Foundation

/// A touch on the glasses that reached the phone.
///
/// The glasses report touches as svc28 pushes: 2011 "captouch" (DeviceState field 5) and 2035 "action button"
/// (field 29). These pushes arrive only in one app-manager mode. Outside that mode the glasses
/// handle play and pause locally. ReGlass listens passively for the pushes.
public struct GlassesInputEvent: Sendable, Equatable {
    public enum Kind: Sendable, Hashable, CustomStringConvertible {
        /// One tap (captouch 1).
        case tap
        /// Captouch 2.
        case doubleTap
        /// Captouch 8.
        case tripleTap
        /// Tap and hold (captouch 3).
        case hold
        /// Captouch 5; the firmware still turns the volume up.
        case swipeForward
        /// Captouch 4; the firmware still turns the volume down.
        case swipeBackward
        /// Captouch 7.
        case slideForward
        /// Captouch 6.
        case slideBackward
        /// Captouch 11.
        case palmTap
        /// Captouch 12.
        case palmHold
        /// The action button, a short press (2035, released).
        case actionButton
        /// The action button, a long press (2035, released).
        case actionButtonLong
        /// A captouch value with no name here.
        case other(Int)

        public var description: String {
            switch self {
            case .tap: return "single tap"
            case .doubleTap: return "double tap"
            case .tripleTap: return "triple tap"
            case .hold: return "tap and hold"
            case .swipeForward: return "swipe forward"
            case .swipeBackward: return "swipe backward"
            case .slideForward: return "slide forward"
            case .slideBackward: return "slide backward"
            case .palmTap: return "palm tap"
            case .palmHold: return "palm hold"
            case .actionButton: return "action button"
            case .actionButtonLong: return "action button, long press"
            case .other(let value): return "touch \(value)"
            }
        }
    }

    public let kind: Kind
    /// When the phone received it.
    public let at: Date

    public init(kind: Kind, at: Date) {
        self.kind = kind
        self.at = at
    }
}

/// Reads touch pushes off svc28. Only the two push types the firmware sends for a gesture count: the 2005 snapshot
/// (and any other push that happens to carry field 5) holds last-known values, not a new touch, and a stale value
/// read as a tap would stop the voice for nothing.
enum GlassesInputDecoder {
    static let captouchPush = 2011
    static let actionButtonPush = 2035
    static let snapshot = 2005

    /// The touch a status message reports, if it is a touch push.
    static func kind(messageType: Int, payload: [UInt8]) -> GlassesInputEvent.Kind? {
        guard messageType == captouchPush || messageType == actionButtonPush,
              let fields = try? Wire.parse(payload) else { return nil }
        if messageType == captouchPush, fields.has(5) { return captouch(fields.varint(5)) }
        if messageType == actionButtonPush, fields.has(29) { return actionButton(fields.varint(29)) }
        return nil
    }

    /// A push of another type (not the snapshot) that carries a touch field: worth one log line, since it would mean
    /// the glasses report touches some other way.
    static func carriesTouchField(messageType: Int, payload: [UInt8]) -> Bool {
        guard messageType != captouchPush, messageType != actionButtonPush, messageType != snapshot,
              let fields = try? Wire.parse(payload) else { return false }
        return fields.has(5) || fields.has(29)
    }

    /// Meta's CAPTOUCH names. 0 is "unknown"; 9 and 10 say a finger rests on the pad or left
    /// it, which isn't a gesture.
    private static func captouch(_ value: Int64) -> GlassesInputEvent.Kind? {
        switch value {
        case 1: return .tap
        case 2: return .doubleTap
        case 3: return .hold
        case 4: return .swipeBackward
        case 5: return .swipeForward
        case 6: return .slideBackward
        case 7: return .slideForward
        case 8: return .tripleTap
        case 11: return .palmTap
        case 12: return .palmHold
        case 0, 9, 10: return nil
        default: return Int(exactly: value).map { .other($0) }
        }
    }

    /// Button actions are 1 for short press down, 2 for short press up, and 3 for long press up. A press counts on release.
    private static func actionButton(_ value: Int64) -> GlassesInputEvent.Kind? {
        switch value {
        case 2: return .actionButton
        case 3: return .actionButtonLong
        default: return nil
        }
    }
}

/// The connection's touch events, decoded passively from the status channel and passed to every listener. A touch of
/// the same kind within 250 ms of the last one passed on is a repeat and dropped. Logs kinds and timings only.
final class GlassesInput: Sendable {
    static let debounce: TimeInterval = 0.25

    private struct State {
        var subscribers: [UUID: AsyncStream<GlassesInputEvent>.Continuation] = [:]
        var lastByKind: [GlassesInputEvent.Kind: Date] = [:]
        var last: Date?
        /// Push types already noted for carrying a touch field, once per connection.
        var noted: Set<Int> = []
        var finished = false
    }

    private let state = Locked(State())

    /// Touches from now on. Ends when the connection stops.
    func stream() -> AsyncStream<GlassesInputEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: GlassesInputEvent.self, bufferingPolicy: .bufferingNewest(16))
        let id = UUID()
        let added = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            state.subscribers[id] = continuation
            return true
        }
        if added {
            continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) } }
        } else {
            continuation.finish()
        }
        return stream
    }

    /// One svc28 message, as the connection received it.
    func receive(messageType: Int, payload: [UInt8], now: Date = Date()) {
        guard let kind = GlassesInputDecoder.kind(messageType: messageType, payload: payload) else {
            if GlassesInputDecoder.carriesTouchField(messageType: messageType, payload: payload),
               state.withLock({ $0.noted.insert(messageType).inserted }) {
                kitLog("device", "touch: status push \(messageType) carries a touch field; not used as a touch")
            }
            return
        }
        let (passed, gap, subscribers) = state.withLock { state -> (Bool, TimeInterval?, [AsyncStream<GlassesInputEvent>.Continuation]) in
            if let previous = state.lastByKind[kind], now.timeIntervalSince(previous) < Self.debounce { return (false, nil, []) }
            let gap = state.last.map { now.timeIntervalSince($0) }
            state.lastByKind[kind] = now
            state.last = now
            return (true, gap, Array(state.subscribers.values))
        }
        guard passed else {
            kitLog("device", "touch: \(kind) again within 250 ms; dropped as a repeat")
            return
        }
        let after = gap.map { String(format: ", %.1f s after the previous touch", $0) } ?? ""
        kitLog("device", "touch: \(kind) (status push \(messageType))\(after)")
        let event = GlassesInputEvent(kind: kind, at: now)
        for subscriber in subscribers { subscriber.yield(event) }
    }

    /// The connection stopped: every stream ends, and later ones end at once.
    func finish() {
        let subscribers = state.withLock { state -> [AsyncStream<GlassesInputEvent>.Continuation] in
            state.finished = true
            defer { state.subscribers = [:] }
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.finish() }
    }
}
