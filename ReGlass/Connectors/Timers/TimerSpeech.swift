import Foundation

/// Words for timers: what the voice says (numbers as words, for text-to-speech), what Chats shows, and the clean-up of
/// what Claude passes in.
enum TimerSpeech {
    // MARK: Spoken

    /// What the voice says when a timer ends. `lateBy`: how long after its due time this is said (ReGlass wasn't running).
    static func doneLine(label: String?, announcement: String?, seconds: Int, lateBy: TimeInterval) -> String {
        if lateBy >= 45 {
            let minutes = Int((lateBy / 60).rounded())
            let ago = minutes <= 1 ? "about a minute ago" : "\(words(minutes)) minutes ago"
            if let label { return "Your \(label) timer went off \(ago)." }
            return "Your timer for \(duration(seconds)) went off \(ago)."
        }
        if let announcement { return announcement }
        if let label { return "Your \(label) timer is up." }
        if let adjective = durationAdjective(seconds) { return "Your \(adjective) timer is done." }
        return "Your timer for \(duration(seconds)) is done."
    }

    /// "one minute", "one and a half minutes", "two hours and ten minutes", "forty-five seconds".
    static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let rest = seconds % 60
        if hours == 0, minutes == 0 { return unit(rest, "second") }
        if hours == 0, rest == 0 { return unit(minutes, "minute") }
        if hours == 0, rest == 30 { return "\(words(minutes)) and a half minutes" }
        if hours == 0 { return "\(unit(minutes, "minute")) and \(unit(rest, "second"))" }
        if minutes == 0, rest == 0 { return unit(hours, "hour") }
        if minutes == 30, rest == 0 { return "\(words(hours)) and a half hours" }
        var parts = [unit(hours, "hour")]
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if rest > 0 { parts.append(unit(rest, "second")) }
        return parts.dropLast().joined(separator: ", ") + " and " + parts.last!
    }

    /// "ten-minute", "two-hour", "thirty-second"; nil for mixed lengths.
    static func durationAdjective(_ seconds: Int) -> String? {
        if seconds < 60 { return "\(words(seconds))-second" }
        if seconds % 3600 == 0 { return "\(words(seconds / 3600))-hour" }
        if seconds % 60 == 0, seconds < 3600 { return "\(words(seconds / 60))-minute" }
        return nil
    }

    static func words(_ number: Int) -> String {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                    "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        switch number {
        case ..<0: return "minus " + words(-number)
        case ..<20: return ones[number]
        case ..<100: return tens[number / 10] + (number % 10 == 0 ? "" : "-" + ones[number % 10])
        case ..<1000:
            return ones[number / 100] + " hundred" + (number % 100 == 0 ? "" : " and " + words(number % 100))
        case ..<1_000_000:
            let rest = number % 1000
            return words(number / 1000) + " thousand" + (rest == 0 ? "" : (rest < 100 ? " and " : " ") + words(rest))
        default: return String(number)
        }
    }

    private static func unit(_ count: Int, _ name: String) -> String {
        "\(words(count)) \(name)\(count == 1 ? "" : "s")"
    }

    // MARK: Chats

    /// "1 minute", "1 minute, 30 seconds".
    static func shortDuration(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) s"
    }

    /// The local time of day, the owner's way ("19:58" or "7:58 PM").
    static func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Food" for Chats.
    static func displayLabel(_ label: String) -> String {
        label.prefix(1).uppercased() + label.dropFirst()
    }

    // MARK: Claude's input

    /// A short label, or nil: trimmed, without quotes or a trailing "timer", at most 40 characters.
    static func cleanLabel(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’."))),
              !text.isEmpty else { return nil }
        for prefix in ["the ", "my ", "a "] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.lowercased().hasSuffix(" timer") { text = String(text.dropLast(" timer".count)) }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.lowercased() != "timer" else { return nil }
        return String(text.prefix(40))
    }

    /// Claude's line for the end of the timer, or nil: one or two short sentences, at most 200 characters.
    static func cleanAnnouncement(_ raw: String?) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 200 else {
            return nil
        }
        return text
    }

    /// For matching "the pasta timer" against "pasta": lowercased, without "the", "my" and "timer".
    static func matchKey(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["the", "my", "a", "timer", "timers"].contains($0) }
            .joined(separator: " ")
    }
}
