import Foundation

/// How hard Claude thinks before answering (`output_config.effort`).
public enum Effort: String, Sendable, CaseIterable, Codable {
    case low
    case medium
    case high
}

/// A route's thinking. `disabled` means as little as the model allows: how each model sends it is
/// `ClaudeModel.thinking` (every `Effort` case is high or below, where Haiku 5.5 and Sonnet 5.5 can turn it off).
public enum ThinkingMode: String, Sendable, CaseIterable, Codable {
    case adaptive
    case disabled
}

/// The request settings for one route.
public struct RouteSettings: Sendable, Equatable, Codable {
    public var thinking: ThinkingMode
    public var effort: Effort

    public init(thinking: ThinkingMode, effort: Effort) {
        self.thinking = thinking
        self.effort = effort
    }

    var logDescription: String { "thinking \(thinking.rawValue), effort \(effort.rawValue)" }
}

/// The two routes' settings.
///
/// Quick commands run with thinking disabled at effort low (Haiku 5.5 can think for seconds before its first token);
/// everything else runs adaptive thinking at effort medium. On Haiku 5.5, effort high made web-search answers take
/// about 9 s (some 1,400 thinking tokens); medium is the default. The same routes apply to every model.
public struct AssistantTuning: Sendable, Equatable, Codable {
    public var quick = RouteSettings(thinking: .disabled, effort: .low)
    public var standard = RouteSettings(thinking: .adaptive, effort: .medium)

    public init() {}

    public static let `default` = AssistantTuning()
    private static let key = "reglass.assistant.tuning"

    /// The settings in use. The on-device tuning screen was retired with the first experiments, so a value saved by
    /// it is cleared rather than applied.
    public static var current: AssistantTuning {
        if UserDefaults.standard.object(forKey: key) != nil {
            UserDefaults.standard.removeObject(forKey: key)
            AssistantLog.add("Tuning: a saved tuning was cleared; using the defaults")
        }
        return .default
    }
}

/// Effort "Auto": picks the quick route for quick commands (play, pause, set, remind, timers, alarms, the time,
/// short imperatives) and the standard route for everything else. A small local rule set, so it costs nothing and
/// adds no latency. Its reason is log-safe (a category, never the words).
public struct EffortRouter: Sendable {
    public enum Route: String, Sendable {
        case quick
        case standard
    }

    public struct Decision: Sendable, Equatable {
        public let route: Route
        /// "command", "time", "short", "greeting" or "default".
        public let reason: String
        public let settings: RouteSettings

        public var effort: Effort { settings.effort }
        public var thinking: ThinkingMode { settings.thinking }
    }

    public let tuning: AssistantTuning

    public init(tuning: AssistantTuning = .current) {
        self.tuning = tuning
    }

    public func decide(_ transcript: String) -> Decision {
        let (route, reason) = classify(transcript)
        return Decision(route: route, reason: reason, settings: route == .quick ? tuning.quick : tuning.standard)
    }

    func classify(_ transcript: String) -> (Route, String) {
        let words = Self.words(transcript)
        guard !words.isEmpty else { return (.quick, "short") }
        let text = words.joined(separator: " ")

        if words.contains(where: Self.interpreterWords.contains) {
            return (.standard, "default")
        }
        if Self.timeQuestions.contains(where: { text == $0 || text.hasPrefix($0 + " ") }) {
            return (.quick, "time")
        }
        if Self.greetings.contains(text) || (words.count <= 3 && Self.greetings.contains(where: { text.hasPrefix($0) })) {
            return (.quick, "greeting")
        }
        let asksSomething = words.contains(where: Self.questionWords.contains) || text.contains("tell me about")
        if let first = words.first, Self.commandVerbs.contains(first),
           !(asksSomething && words.count > 6) {
            return (.quick, "command")
        }
        if words.contains(where: Self.quickNouns.contains), words.count <= 10, !asksSomething || text.hasPrefix("set") {
            return (.quick, "command")
        }
        if words.count <= 4, !asksSomething {
            return (.quick, "short")
        }
        return (.standard, "default")
    }

    // MARK: Rules

    /// Lowercased words without punctuation, with polite openers removed ("please", "can you", "Hey Meta").
    static func words(_ transcript: String) -> [String] {
        var words = transcript.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
        let openers: [[String]] = [["hey", "meta"], ["hey", "reglass"], ["hey", "re", "glass"], ["reglass"],
                                   ["re", "glass"], ["please"], ["can", "you"], ["could", "you"], ["would", "you"],
                                   ["will", "you"], ["i", "want", "you", "to"], ["go", "ahead", "and"], ["just"]]
        var trimmed = true
        while trimmed {
            trimmed = false
            for opener in openers where words.starts(with: opener) {
                words.removeFirst(opener.count)
                trimmed = true
            }
        }
        if words.last == "please" { words.removeLast() }
        return words
    }

    static let commandVerbs: Set<String> = [
        "play", "pause", "resume", "stop", "skip", "next", "previous", "shuffle", "repeat", "set", "start", "cancel",
        "remind", "wake", "turn", "switch", "mute", "unmute", "louder", "quieter", "volume", "snooze", "dismiss",
        "add", "call", "text", "message", "open", "close", "lock", "unlock", "dim", "brighten",
    ]

    static let quickNouns: Set<String> = ["timer", "alarm", "reminder", "reminders", "stopwatch", "countdown"]

    static let interpreterWords: Set<String> = [
        "interpret", "interpreter", "interpreting", "interpretation",
        "translate", "translator", "translating", "translation",
    ]

    static let questionWords: Set<String> = [
        "what", "what's", "whats", "why", "how", "who", "who's", "where", "where's", "when", "which", "explain",
        "describe", "compare", "should", "is", "are", "does", "do", "did", "can", "could",
    ]

    static let timeQuestions: [String] = [
        "what time is it", "what's the time", "whats the time", "what is the time", "what day is it",
        "what's the date", "whats the date", "what is the date", "what's today's date", "what is today's date",
        "what day is today", "what's today", "time", "the time",
    ]

    static let greetings: Set<String> = [
        "hi", "hello", "hey", "thanks", "thank you", "thank you very much", "thanks a lot", "good morning",
        "good night", "good evening", "good afternoon", "never mind", "nevermind", "nothing", "cancel that",
    ]
}
