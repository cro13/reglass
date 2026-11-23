import Foundation
import OSLog

/// Where ReGlassKit's activity lines go. The app points this at its activity log.
///
/// Lines describe states and steps only ("link ready", "trust refused 0x1043"). They never contain tokens, codes,
/// keys, receipts, payload bytes, email addresses or other personal data.
public enum ReGlassKitLog {
    private static let sink = Locked<(@Sendable (String) -> Void)?>(nil)

    public static func setSink(_ newSink: (@Sendable (String) -> Void)?) {
        sink.withLock { $0 = newSink }
    }

    static func write(_ area: String, _ message: String) {
        Logger(subsystem: "reglass.kit", category: area).debug("\(message, privacy: .public)")
        sink.current?("\(area): \(message)")
    }
}

/// Logs one line for `area` ("bluetooth", "link", "account", "ownership", "device").
func kitLog(_ area: String, _ message: @autoclosure () -> String) {
    ReGlassKitLog.write(area, message())
}
