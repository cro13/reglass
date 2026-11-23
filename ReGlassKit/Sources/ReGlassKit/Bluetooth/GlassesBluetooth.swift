import CoreBluetooth

/// ReGlass's Bluetooth central, as the app sees it.
public enum GlassesBluetooth {
    /// The central's state-restoration identifier. When iOS relaunches ReGlass for a Bluetooth event it lists this in
    /// `launchOptions[.bluetoothCentrals]`; call `start()` before `didFinishLaunching` returns.
    public static let restoreIdentifier = "reglass.central"

    /// Whether ReGlass may already use Bluetooth, so `start()` won't show the permission prompt.
    public static var isAuthorized: Bool { CBManager.authorization == .allowedAlways }

    /// Creates the central. The first call may show iOS's Bluetooth permission prompt; call it at launch only when
    /// `isAuthorized` or when iOS is restoring ReGlass. Idempotent.
    public static func start() {
        BluetoothCentral.shared.start()
    }
}
