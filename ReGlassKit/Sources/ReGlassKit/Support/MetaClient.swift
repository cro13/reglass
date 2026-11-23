import Foundation

/// The static client tokens identify the client to Meta.
/// `FRL|` for the email-code sign-in, `AR|` for the token exchange, `HW|` for the ownership hand-over.
///
/// The app's build puts them in Info.plist as `ReGlassMetaHwToken`, `ReGlassMetaArToken`, `ReGlassMetaFrlToken`
/// (from its private Secrets.xcconfig). Never log or display them.
struct MetaClientCredentials: Sendable {
    let hardware: String
    let accountRecovery: String
    let firstRunLogin: String

    /// The tokens from Info.plist, or nil if any is missing.
    static var current: MetaClientCredentials? {
        guard let hardware = value("ReGlassMetaHwToken"),
              let accountRecovery = value("ReGlassMetaArToken"),
              let firstRunLogin = value("ReGlassMetaFrlToken") else { return nil }
        return MetaClientCredentials(hardware: hardware, accountRecovery: accountRecovery, firstRunLogin: firstRunLogin)
    }

    private static func value(_ key: String) -> String? {
        let text = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An xcconfig variable that was never defined reaches the plist unexpanded.
        return text.isEmpty || text.hasPrefix("$(") ? nil : text
    }
}

public enum MetaClient {
    /// Whether this build carries Meta's client tokens.
    public static var isConfigured: Bool { MetaClientCredentials.current != nil }

    /// The build-time problem to show before starting a sign-in conversation.
    public static var signInDataError: ReGlassError? { Functions.isAvailable ? nil : .missingSignInData }
}
