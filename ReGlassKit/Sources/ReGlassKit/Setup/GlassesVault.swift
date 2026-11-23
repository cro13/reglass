import Foundation

/// ReGlass's saved owner key and glasses, as the app sees them.
public enum GlassesVault {
    public static func ownerKeyState() -> OwnerKeyState {
        do {
            return try IdentityStore.ownerKey() == nil ? .none : .present
        } catch ReGlassError.keyUnavailable {
            return .unreadable
        } catch {
            return .damaged
        }
    }

    /// Throws `ReGlassError.keyUnavailable` before the first unlock.
    public static func savedGlasses() throws -> [SavedGlasses] {
        try IdentityStore.records().map {
            SavedGlasses(id: $0.glassesID, serial: $0.serial, isVerified: $0.state == .verified)
        }
    }

    /// Forgets the glasses with `serial`. The owner key stays sealed on this iPhone, so a later setup reuses it
    /// (a key the glasses may still hold is never thrown away). Nothing changes on the glasses.
    public static func forget(serial: String) throws {
        try IdentityStore.remove(serial: serial)
        kitLog("ownership", "forgot glasses …\(serial.suffix(4)); owner key kept")
    }
}
