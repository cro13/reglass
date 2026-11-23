import Foundation

/// The byte pipe under the encrypted link: it moves whole frames (L2CAP SDUs) to and from one pair of glasses.
/// The Bluetooth layer implements it; the session layer uses it. A fresh transport is made per connection attempt.
protocol FrameTransport: AnyObject, Sendable {
    /// Opens the link. Throws a `ReGlassError` (`.bluetoothOff`, `.bluetoothDenied`, `.glassesUnknown`,
    /// `.pairingDeclined`, `.noAnswer`, ...) when it won't open. Cancellation-aware.
    func connect() async throws

    /// Sends one frame.
    func send(_ frame: [UInt8]) async throws

    /// Returns exactly one whole frame, waiting for it. Throws `ReGlassError.linkLost` once closed (by either side).
    /// Cancellation-aware.
    func receive() async throws -> [UInt8]

    /// Closes the link and wakes any waiting `receive`. Idempotent.
    func close()
}
