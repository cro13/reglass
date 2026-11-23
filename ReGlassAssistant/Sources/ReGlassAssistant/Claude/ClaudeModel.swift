import Foundation

/// The Claude models the owner can choose for the assistant's answers (Settings → Assistant → Model). Claude Haiku
/// 5.5 is the default. A conversation keeps the model it started with (`ClaudeConversation.model`), so its thinking
/// blocks and its prompt cache stay valid; a new choice applies from the next conversation. Small jobs beside the
/// answers (a typed note's title) and the interpreter always use Claude Haiku 5.5 (`ClaudeConfiguration.model`).
///
/// What differs between them in a request (`ClaudeClient`):
/// - **Thinking off**, for the quick route: Haiku 5.5 takes `thinking: {type: disabled}` at effort high or below.
///   Sonnet 5.5 rejects `disabled` and takes `between_tools` instead, also at effort high or below. Opus 5.5 and
///   Fable 5.2 can't turn thinking off: the field is left out and effort low keeps the thinking short. Every
///   `Effort` case is high or below.
/// - **Declined requests:** Sonnet 5.5, Opus 5.5 and Fable 5.2 get Anthropic's server-side fallback
///   (`fallbacks: "default"`): a request a safety classifier declines is answered by the model Anthropic recommends
///   for that kind of request, in the same stream. Haiku 5.5 has no fallback.
public enum ClaudeModel: String, CaseIterable, Sendable, Identifiable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"
    case fable = "claude-fable-5-2"

    public var id: String { rawValue }

    /// "Claude Sonnet 5.5".
    public var displayName: String { "Claude " + shortName }

    /// "Sonnet 5.5".
    public var shortName: String {
        switch self {
        case .haiku: return "Haiku 5.5"
        case .sonnet: return "Sonnet 5.5"
        case .opus: return "Opus 5.5"
        case .fable: return "Fable 5.2"
        }
    }

    /// A few words for the picker.
    public var summary: String {
        switch self {
        case .haiku: return "The fastest, and the lowest cost. The default."
        case .sonnet: return "Stronger answers, a little slower."
        case .opus: return "Thorough on hard questions. Slower, and costs more."
        case .fable: return "Anthropic's most capable model. The slowest and the most expensive."
        }
    }

    /// `thinking` for a route on this model; nil leaves the field out of the request.
    func thinking(_ mode: ThinkingMode) -> JSONValue? {
        switch mode {
        case .adaptive:
            return ["type": "adaptive"]
        case .disabled:
            switch self {
            case .haiku: return ["type": "disabled"]
            case .sonnet: return ["type": "between_tools"]
            case .opus, .fable: return nil
            }
        }
    }

    /// Anthropic's server-side fallback for declined requests is sent with this model's requests.
    var hasServerFallback: Bool { self != .haiku }

    // MARK: The choice

    private static let key = "reglass.assistant.model"

    /// The model new conversations use. A saved value this build doesn't know falls back to Claude Haiku 5.5.
    public static var chosen: ClaudeModel {
        get { UserDefaults.standard.string(forKey: key).flatMap(ClaudeModel.init(rawValue:)) ?? .haiku }
        set {
            guard newValue != chosen else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            AssistantLog.add("Model: \(newValue.shortName) chosen; it applies from the next conversation")
        }
    }
}
