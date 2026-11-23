import Foundation

// The glasses queue up to ten texts received over Bluetooth MAP and ask whether the phone is active (empty
// message 1046). An affirmative reply (message 1047, tag 1 set to true) lets the announcement proceed
// to a chime and speech request if the other announcement conditions pass. The glasses drop the queue after a
// negative response or 2 s without one. ReGlass leaves the request unanswered.
//
// Turn message 6 requests speech. Its fields are `{1 event name, 2 repeated {1 key, 2 text},
// 3 repeated {1 key, 2 flag}, 4 repeated {1 key, 2 int}, 5 repeated {1 key, 2 fixed32}, 6 interaction id}`.
// MAP texts carry a provider, timestamp in seconds, message body, and sender number or address. Notifications
// on svc46 can also name the sender and conversation. These values may be shown but must stay out of logs.

extension AssistantMessageType {
    /// The glasses ask whether this phone is the active one (empty). Sent when a text arrives over MAP.
    static let activeDeviceStateRequest = 1046
    /// The answer: `{1 isActive}`.
    static let activeDeviceStateResponse = 1047
}

/// Something the glasses asked or reported on their own. Log-safe except the fields of a speech request, which are
/// content.
public enum GlassesReport: Sendable, Equatable {
    /// 1046: a text reached the glasses over Bluetooth (MAP) and they asked whether this iPhone is the active one.
    /// `answeredYes` is true when this iPhone said yes, nil when it didn't answer (then the glasses drop the text
    /// after 2 s).
    case activePhoneQuestion(answeredYes: Bool?)
    /// Turn message 6: the glasses chimed and asked the phone to speak (a message, a reminder). They wait about 30 s.
    case speechRequest(GlassesSpeechRequest)
    /// A message ReGlass doesn't read, by kind ("assistant message 1050", "service 101 message 3"). Log-safe.
    case unrecognised(String)
}

/// A request for speech the glasses made on their own. Text fields are content (a sender, a message): show them, never log them.
public struct GlassesSpeechRequest: Sendable, Equatable {
    /// The event name from tag 1, such as an incoming message or timer alert.
    public let name: String?
    /// Text values from tag 2, keyed by name. They can include the sender and message body.
    public let texts: [String: String]
    /// Flags from tag 3, keyed by name. They can indicate a group conversation or a silent notification.
    public let flags: [String: Bool]
    /// Numeric values from tag 4, keyed by name. They can include the message index and type.
    public let numbers: [String: Int64]
    /// The payload's size in bytes. Log-safe.
    public let size: Int
    /// The interaction the glasses named; the answer goes under it. Opaque and never logged.
    let interaction: String?

    public static let incomingMessage = GlassesRequestName.incomingMessage
    public static let reminderAlert = GlassesRequestName.tarAlert

    /// The glasses named the interaction the answer should carry.
    public var namesInteraction: Bool { interaction != nil }
    /// An incoming message, by name or (unnamed) by its message fields.
    public var isMessage: Bool {
        name == Self.incomingMessage || (name == nil && (texts["subtitle"] != nil || texts["sender_id"] != nil))
    }
    /// "native" for texts over MAP (SMS, iMessage); "whatsapp", "messenger"… for notifications.
    public var provider: String? { nonEmpty("provider") }
    /// Who sent it: a name when the glasses have one, else the number or address the message came from.
    public var sender: String? { nonEmpty("sender_name") ?? nonEmpty("thread_name") ?? nonEmpty("sender_id") }
    /// The message text ("subtitle" in the glasses' request), if they passed it.
    public var messageText: String? { nonEmpty("subtitle") }
    /// A log-safe name for the request: known event names only.
    public var logName: String {
        guard let name else { return "an unnamed request" }
        return name == Self.incomingMessage || name == Self.reminderAlert ? name : "another event"
    }

    private func nonEmpty(_ key: String) -> String? {
        guard let value = texts[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Reads a turn message 6 payload; nil when it has neither an event name nor an interaction id in that layout.
    static func decode(_ payload: [UInt8]) -> GlassesSpeechRequest? {
        guard let fields = try? Wire.parse(payload) else { return nil }
        let name = String(decoding: fields.bytes(1), as: UTF8.self)
        let interaction = String(decoding: fields.bytes(6), as: UTF8.self)
        guard !name.isEmpty || !interaction.isEmpty else { return nil }
        var texts: [String: String] = [:]
        var flags: [String: Bool] = [:]
        var numbers: [String: Int64] = [:]
        for (field, pair) in [2, 3, 4].flatMap({ field in fields.repeatedBytes(field).map { (field, $0) } }) {
            guard let entry = try? Wire.parse(pair) else { continue }
            let key = String(decoding: entry.bytes(1), as: UTF8.self)
            guard !key.isEmpty else { continue }
            switch field {
            case 2: texts[key] = String(decoding: entry.bytes(2), as: UTF8.self)
            case 3: flags[key] = entry.varint(2) != 0
            default: numbers[key] = entry.varint(2)
            }
        }
        return GlassesSpeechRequest(name: name.isEmpty ? nil : name, texts: texts, flags: flags, numbers: numbers,
                                    size: payload.count, interaction: interaction.isEmpty ? nil : interaction)
    }
}

extension AssistantService {
    /// 1046 from the glasses (a text reached them over MAP): left unanswered, so the glasses drop the text after 2 s.
    func activePhoneAsked() async {
        log("the glasses asked whether this iPhone is the active phone (a text reached them over Bluetooth); "
            + "not answered")
        emit(.glassesReport(.activePhoneQuestion(answeredYes: nil)))
    }

    /// A turn message 6 (or one naming a request) that reads as a request for speech: passed to the app with what it
    /// carries. False when it doesn't read as one, so the caller passes it on by kind as before.
    func speechRequested(_ payload: [UInt8]) -> Bool {
        guard let request = GlassesSpeechRequest.decode(payload) else { return false }
        log("the glasses asked for speech: \(request.logName) (\(payload.count) bytes, \(request.texts.count) text "
            + "fields, interaction id \(request.namesInteraction ? "named" : "missing"))")
        emit(.glassesReport(.speechRequest(request)))
        return true
    }
}
