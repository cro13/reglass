import Foundation

/// Makes a piece of Claude's text safe to speak: no markdown, URLs, emoji or square brackets.
///
/// The system prompt already asks for plain spoken English; this is the safety net. Square brackets matter most:
/// Eleven v4 Turbo performs bracketed tags such as "[laughs]" as sounds, so short bracketed bits (tags, citation
/// markers) are dropped and longer ones become parentheses.
public enum SpokenText {
    public static func clean(_ text: String) -> String {
        var s = text

        // Internal tags that can leak with thinking disabled (<thinking>, </context>…), and tool calls written out
        // as text ({"query": …} or web_search(…)): neither should ever be read aloud.
        s = s.replacing(#/<\/?[A-Za-z_][A-Za-z0-9_:-]*(\s[^<>]*)?>/#, with: "")
        if looksLikeToolCall(s) {
            AssistantLog.add("Dropped a piece of the reply that looked like a tool call written as text")
            return ""
        }

        // Links: keep the words, drop the address. Then bare URLs.
        s = s.replacing(#/\[([^\]\n]+)\]\((?:[^)\s]+)\)/#) { String($0.output.1) }
        s = s.replacing(#/<?https?:\/\/[^\s>)\]]+>?/#, with: "")
        s = s.replacing(#/\bwww\.[^\s)\]]+/#, with: "")

        // Square brackets: short ones (tags, [1]) go, longer ones become parentheses.
        s = s.replacing(#/\[([^\]\n]{0,24})\]/#, with: "")
        s = s.replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")

        // Markdown structure at line starts: headings, quotes, bullets, numbered lists, rules.
        s = s.replacing(#/(?m)^\s{0,3}#{1,6}\s+/#, with: "")
        s = s.replacing(#/(?m)^\s{0,3}>\s?/#, with: "")
        s = s.replacing(#/(?m)^\s*[-*•+]\s+/#, with: "")
        s = s.replacing(#/(?m)^\s*\d{1,2}[.)]\s+/#, with: "")
        s = s.replacing(#/(?m)^\s*([-*_]\s*){3,}$/#, with: "")

        // Emphasis and code marks.
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacing(#/(^|[\s(])[*_]([^*_\n]+)[*_](?=[\s.,;:!?)]|$)/#) { String($0.output.1) + String($0.output.2) }
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "|", with: ", ")

        // Emoji and other pictographs.
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isPictograph($0) }))

        // Whitespace: one space, no space before punctuation.
        s = s.replacing(#/\s+/#, with: " ")
        s = s.replacing(#/\s+([.,;:!?])/#) { String($0.output.1) }
        s = s.replacing(#/\(\s*\)/#, with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tool call written into the text instead of a tool_use block (a known thinking-disabled failure).
    static func looksLikeToolCall(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        return compact.contains("{\"query\"") || compact.contains("web_search(") || compact.contains("\"name\":\"web_search\"")
            || compact.contains("web_fetch(") || compact.contains("\"name\":\"web_fetch\"")
            || compact.contains("<invoke") || compact.contains("tool_use")
    }

    /// True for emoji and pictographs, but not for digits, "#" or "*" that merely *can* be emoji.
    private static func isPictograph(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        if properties.isEmojiPresentation { return true }
        if properties.isEmoji, scalar.value > 0x238C { return true }
        switch scalar.value {
        case 0xFE0F, 0x200D, 0x20E3: return true          // variation selector, joiner, keycap
        case 0x1F3FB...0x1F3FF: return true                // skin tones
        default: return false
        }
    }
}
