import Foundation

/// Keeps the glasses' LE connection requested while ReGlass holds it.
///
/// An iOS connection request has no deadline: it stays pending until the glasses are in reach, and the central asks
/// again after every drop, 5 s after a failed attempt, and when Bluetooth comes back. So the LE link is usually up
/// before a session starts and its L2CAP channel opens at once. iOS keeps the glasses' link up for audio after it ends
/// ReGlass, so no connect or drop would relaunch ReGlass; the central's subscription to the glasses' PSM notifications
/// does (state restoration delivers it), because the glasses notify when the assistant's session disappears.
///
/// One keeper holds one pair. Keepers and transports hold through the central, which keeps the connection while
/// anyone holds it, so the setup and the live connection may each have their own.
final class ConnectionKeeper: Sendable {
    private let central: BluetoothCentral
    private let holder = ConnectionHolder(role: "keeper", reconnects: true)
    private let held = Locked<UUID?>(nil)

    init(central: BluetoothCentral = .shared) {
        self.central = central
    }

    deinit {
        release()
    }

    /// Holds the connection to `glasses`, letting go of any other pair first. Holding the same pair again asks for
    /// the connection again.
    func hold(_ glasses: UUID) {
        let previous = held.withLock { current -> UUID? in
            defer { current = glasses }
            return current
        }
        if let previous, previous != glasses { central.release(previous, holder: holder) }
        central.keepConnected(glasses, holder: holder)
    }

    /// Lets go. The app's LE connection closes unless something else holds it. Idempotent.
    func release() {
        let previous = held.withLock { current -> UUID? in
            defer { current = nil }
            return current
        }
        if let previous { central.release(previous, holder: holder) }
    }
}
