import Foundation
import ReGlassKit

/// The glasses' firmware update as the app shows it: what Meta offers, a running update, and how the last one ended.
/// Driven by `GlassesController` (check, start, stop); shown by `FirmwareView` and, while one runs, the full-screen
/// `FirmwareUpdateCover`.
struct FirmwareUpdateState: Equatable {
    /// What Meta's update server offers these glasses.
    enum Check: Equatable {
        case unknown
        case checking
        /// The glasses already run what Meta offers.
        case upToDate(String)
        case available(FirmwareAvailableUpdate)
        /// Carries what to tell the wearer.
        case failed(String)
    }

    /// Where a running update is. Only moves forward.
    enum Stage: Int, Comparable, CaseIterable {
        /// Fetching the update from Meta and connecting to the glasses.
        case preparing
        /// Streaming the update to the glasses.
        case sending
        /// The glasses have the whole update and are installing it; they restart on their own.
        case installing
        /// Reconnecting after the restart to read the new version.
        case confirming

        static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Run: Equatable {
        /// A rehearsal sends the whole update and stops before the glasses install it (DEBUG builds only).
        let rehearsal: Bool
        let target: String
        let bytes: Int
        var stage = Stage.preparing
        var sent = 0
        /// When sending started, and how far it was then: the rate behind "about N min left".
        var sendingSince: Date?
        var sentAtStart = 0
        /// ReGlass left the screen at this time, before the install: the update stops at `away + awayGrace` unless
        /// ReGlass comes back.
        var away: Date?
        /// The glasses' battery when the update started.
        var battery: Int?

        var fraction: Double { bytes > 0 ? min(1, Double(sent) / Double(bytes)) : 0 }

        /// Seconds left for the transfer at the rate seen so far, once there is enough to measure.
        func secondsLeft(now: Date) -> TimeInterval? {
            guard stage == .sending, let since = sendingSince else { return nil }
            let elapsed = now.timeIntervalSince(since)
            let done = sent - sentAtStart
            guard elapsed >= 15, done > 0 else { return nil }
            return Double(bytes - sent) / (Double(done) / elapsed)
        }
    }

    /// How the last update ended. Shown until dismissed.
    enum Outcome: Equatable {
        /// The glasses restarted on the new version.
        case updated(String)
        /// A rehearsal reached the end of the update and stopped before installing.
        case rehearsed
        /// Stopped before the glasses installed anything. Carries why.
        case stopped(String)
        /// The glasses received the update and may be installing it, but ReGlass couldn't confirm the result.
        case unconfirmed(String)
        case failed(String)
    }

    var check = Check.unknown
    var run: Run?
    var outcome: Outcome?

    var isRunning: Bool { run != nil }
    /// The full-screen view shows while an update runs, and its outcome until dismissed.
    var showsCover: Bool { run != nil || outcome != nil }

    /// How long ReGlass may be off screen before the install, before the update stops.
    static let awayGrace: TimeInterval = 20
    /// The transfer rate measured on these glasses with the 100 ms pacing (~9.6 KB/s over two full 10.9 MB runs on
    /// 2026-11-14), for the estimate up front.
    static let typicalBytesPerSecond = 9_600.0

    /// "About 20 minutes" for an update of `bytes`, rounded up to 5 minutes.
    static func estimate(bytes: Int) -> String {
        let minutes = Double(bytes) / typicalBytesPerSecond / 60
        let rounded = max(5, Int((minutes / 5).rounded(.up)) * 5)
        return "about \(rounded) minutes"
    }

    /// "10.9 MB".
    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
