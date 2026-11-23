import Foundation

/// The setup steps the person sees.
public enum SetupStage: Int, CaseIterable, Comparable, Identifiable, Sendable {
    /// Checking the Meta sign-in.
    case account
    /// Opening the encrypted link and reading the glasses' identity.
    case connect
    /// Meta signs the hand-over and the glasses accept ReGlass's key.
    case ownership
    /// Reconnecting with ReGlass's key: the glasses now check it on every connection.
    case secure
    /// Matching the serial number and reading the battery.
    case finish

    public var id: Int { rawValue }

    public static func < (a: SetupStage, b: SetupStage) -> Bool { a.rawValue < b.rawValue }
}

/// What a successful transfer or reconnect confirmed.
public struct GlassesSetupResult: Sendable, Equatable {
    public let serial: String
    public let batteryPercent: Int
    public let firmware: String?
    public let model: String?
}

/// Whether ReGlass has an owner key on this iPhone.
public enum OwnerKeyState: Sendable {
    case none
    case present
    /// There is a key file, but it can't be read right now: the iPhone hasn't been unlocked since it started.
    case unreadable
    /// The key file is damaged. ReGlass never replaces it on its own; only reinstalling ReGlass resets it.
    case damaged
}

/// Glasses ReGlass set up on this iPhone.
public struct SavedGlasses: Sendable, Equatable {
    /// The CBPeripheral identifier they were last verified under.
    public let id: UUID
    public let serial: String
    /// Confirmed by a trusted reconnect. False while a setup is unfinished or after the glasses refused the key.
    public let isVerified: Bool
}
