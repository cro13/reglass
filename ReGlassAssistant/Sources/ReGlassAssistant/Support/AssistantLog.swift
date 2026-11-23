import Foundation

/// Where ReGlassAssistant writes its log lines. The app points it at its activity log.
///
/// Rule for every line: states, sizes, timings, token counts, HTTP status and error kinds only. Never a key, a
/// transcript, a reply, a search query or audio.
public enum AssistantLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: (@Sendable (String) -> Void)?

    public static func setSink(_ newSink: @escaping @Sendable (String) -> Void) {
        lock.withLock { sink = newSink }
    }

    static func add(_ line: String) {
        let current = lock.withLock { sink }
        current?("Assistant: " + line)
    }
}

extension TimeInterval {
    /// "1.42 s", for log lines.
    var seconds: String { String(format: "%.2f s", self) }
}

/// A monotonic stopwatch for latency lines.
struct Stopwatch: Sendable {
    private let start = DispatchTime.now().uptimeNanoseconds

    var elapsed: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }
}
