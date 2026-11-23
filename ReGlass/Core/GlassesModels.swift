import Foundation
import ReGlassKit

/// What ReGlass shows about the glasses it set up. Nothing secret: the owner key and identity live sealed in
/// ReGlassKit; this record is for display and points at them by serial.
struct PairedGlasses: Codable, Equatable {
    /// The Bluetooth peripheral id.
    var id: UUID
    var serial: String
    /// The name shown in ReGlass. Starts as the advertised name; the wearer can rename it.
    var name: String
    var model: String?
    var firmware: String?
    var setUpAt: Date
    /// The last readings, so Home has something to show before the link is back.
    var lastBattery: Int?
    var lastCaseBattery: Int?
    /// When the case's level was last read (the case reports only through the glasses sitting in it).
    var lastCaseSeenAt: Date?
    var lastSeen: Date?

    private static let key = "reglass.pairedGlasses.v2"

    static func load() -> PairedGlasses? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PairedGlasses.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }

    var productLine: String { Self.productLine(model) }

    /// The wearer's pair are Ray-Ban Meta Audio Clubmasters; other model codes are shown as they come.
    static func productLine(_ model: String?) -> String {
        let raw = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if raw.isEmpty || lower.contains("orca") || lower.contains("audio") { return "Ray-Ban Meta Audio" }
        return raw
    }
}

/// The glasses as the screens show them.
struct GlassesLive: Equatable {
    enum Connection: Equatable {
        /// ReGlass is not trying (stay connected is off, or nothing is set up).
        case idle
        case connecting
        case connected
        /// Trying, but nothing answers. Carries what to do about it.
        case searching(String)
        case bluetoothOff
        case bluetoothDenied
        /// The glasses no longer accept ReGlass's key, or setup never finished: reconnect or set up again.
        case refused
        /// The saved key is locked until the iPhone has been unlocked once.
        case keyUnavailable

        var isConnected: Bool { self == .connected }
        var needsAttention: Bool { self == .refused || self == .keyUnavailable }

        init(_ connection: GlassesStatus.Connection) {
            switch connection {
            case .connecting: self = .connecting
            case .connected: self = .connected
            case .refused: self = .refused
            case .waiting(.bluetoothOff?): self = .bluetoothOff
            case .waiting(.bluetoothDenied?): self = .bluetoothDenied
            case .waiting(let error?): self = .searching(error.errorDescription ?? Self.lookingHint)
            case .waiting(nil): self = .searching(Self.lookingHint)
            }
        }

        static let lookingHint = "Looking for your glasses. Wake them and keep them close."
    }

    var connection: Connection = .idle
    var battery: Int?
    var charging = false
    var caseBattery: Int?
    var caseCharging = false
    var inCase: Bool?
    /// When `caseBattery` was last live. The case has no radio of its own: its level only comes through the glasses
    /// while they sit in it, so out of the case it's an older reading.
    var caseSeenAt: Date?
    var worn: Bool?
    var firmware: String?
    var model: String?
    var serial: String?
    var updatedAt: Date?

    /// The case's level is being read right now (connected, glasses in the case).
    var caseIsLive: Bool { connection == .connected && inCase == true }
}

/// A pair of glasses found during setup, with the name ReGlass shows.
struct FoundGlasses: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int?
    let connectedToPhone: Bool
    let pairingMode: Bool

    init(_ nearby: NearbyGlasses) {
        id = nearby.id
        name = Self.friendlyName(nearby.name)
        rssi = nearby.rssi
        connectedToPhone = nearby.connectedToPhone
        pairingMode = nearby.pairingMode
    }

    var subtitle: String {
        if connectedToPhone { return "Connected to this iPhone" }
        if pairingMode { return "Ready to pair" }
        return "Nearby"
    }

    /// 0–3 bars from RSSI; glasses iOS holds without an advert count as close.
    var signalBars: Int {
        guard let rssi else { return connectedToPhone ? 3 : 0 }
        switch rssi {
        case (-60)...: return 3
        case (-75)...: return 2
        default: return 1
        }
    }

    /// The glasses advertise short names such as "RB Meta 00B2"; show "Ray-Ban Meta 00B2".
    static func friendlyName(_ advertised: String) -> String {
        let trimmed = advertised.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("RB ") { return "Ray-Ban " + trimmed.dropFirst(3) }
        return trimmed.isEmpty ? "Meta glasses" : trimmed
    }
}

extension SetupStage {
    var title: String {
        switch self {
        case .account: return "Checking your Meta account"
        case .connect: return "Connecting to your glasses"
        case .ownership: return "Making ReGlass the owner"
        case .secure: return "Reconnecting securely"
        case .finish: return "Final checks"
        }
    }

    var activeDetail: String {
        switch self {
        case .account: return "Confirming your sign-in with Meta."
        case .connect: return "Opening an encrypted Bluetooth link."
        case .ownership: return "Meta signs the hand-over and your glasses accept ReGlass's key."
        case .secure: return "Your glasses now check ReGlass's key on every connection."
        case .finish: return "Matching the serial number and reading the battery."
        }
    }

    /// The stages a run goes through. A reconnect with the saved key skips Meta entirely.
    static func stages(enrolling: Bool) -> [SetupStage] {
        enrolling ? allCases : [.connect, .secure, .finish]
    }
}

/// The wake word as Settings shows it: what the glasses last reported, and what ReGlass is doing about it.
struct WakeWordState: Equatable {
    enum Activity: Equatable {
        case idle
        /// Installing; the live connection has let go for it.
        case installing(WakeWord, WakeWordProgress)
        /// Just installed and confirmed by the glasses.
        case installed(WakeWord)
        /// Stopped. Carries what to tell the wearer.
        case failed(WakeWord, String)
    }

    /// The last reading from the glasses. Nil until read, and after an install that couldn't be confirmed.
    var installed: InstalledWakeWord?
    /// The glasses run firmware the wake word files weren't made for.
    var unavailable = false
    /// The last read didn't work, in plain words.
    var readProblem: String?
    var activity: Activity = .idle
    /// Asking the glasses which wake word resources are installed. Kept apart from `activity`, so a read after an install never
    /// wipes the install's outcome message.
    var isReading = false

    var isBusy: Bool { isReading || isInstalling }

    var isInstalling: Bool {
        if case .installing = activity { return true }
        return false
    }

    /// The short value on the Settings row.
    var summary: String {
        if case .installing(_, let progress) = activity { return progress.label }
        if isReading, activity == .idle { return "Checking…" }
        if unavailable { return "Not available" }
        switch installed {
        case .heyMeta?: return "Hey Meta"
        case .custom?: return "Custom"
        case .olderCustom?: return "Earlier custom"
        case .incomplete?: return "Didn't finish"
        case .unknown?: return "Unknown"
        case .empty?: return "None"
        case nil: return "—"
        }
    }

    /// Whether the stored resources match `choice`; the running DSP model is not reported.
    func isCurrent(_ choice: WakeWord) -> Bool {
        switch (choice, installed) {
        case (.heyMeta, .heyMeta?), (.custom, .custom?): return true
        default: return false
        }
    }
}

extension WakeWord {
    var title: String {
        switch self {
        case .heyMeta: return "Hey Meta"
        case .custom: return "Custom wake word"
        }
    }
}

extension WakeWordProgress {
    /// Where an install is, in a few words.
    var label: String {
        switch self {
        case .connecting: return "Connecting…"
        case .sending(let fraction): return "Installing… \(Int((fraction * 100).rounded(.down)))%"
        case .finishing: return "Finishing…"
        }
    }

    /// 0…1 for a progress bar; nil while there is nothing to measure.
    var fraction: Double? {
        switch self {
        case .connecting: return nil
        case .sending(let fraction): return fraction
        case .finishing: return 1
        }
    }
}
