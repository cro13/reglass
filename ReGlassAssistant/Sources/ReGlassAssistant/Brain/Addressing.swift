import Foundation

/// The wearer saying the app's name partway through a request: what came before is finished, and a new instruction
/// starts. "Take a note: buy oat milk and eggs. ReGlass, set a timer for ten minutes." is two instructions, so the
/// note stops at "eggs" and never takes in the second one.
///
/// The name: ReGlass, pronounced "ree-glass", including spaced and hyphenated transcriptions ("re glass", "re-glass").
///
/// A name splits the request when it's said to the assistant, not about something:
/// - after a greeting: "hey ReGlass", "okay, ReGlass";
/// - or set off on both sides: a pause before it (punctuation, or "and", "then", "so", "now", "also" right before
///   it) and one after it (punctuation, or "please"): "…at eight. ReGlass, please set a reminder", "…and then
///   ReGlass, turn on…". "The ReGlass app" and "I use ReGlass." don't split.
///
/// Not a split: the name with nothing after it ("thanks, ReGlass."); the name at the very start, which is only
/// dropped (like the Transcriber's wake phrase); and the name right after a colon or a word that starts dictation
/// ("type: hey ReGlass, I'm late"), where it's part of the words being dictated. The greeting and joining words just
/// before the name go with it, so "…see you at eight and then hey ReGlass, …" leaves "…see you at eight".
///
/// Deterministic on purpose: the brain judging where dictation ends from punctuation alone is what failed.
public enum Addressing {
    public struct Request: Sendable, Equatable {
        /// The instructions in the order said, each without the name that started it. One for most requests.
        public let parts: [String]

        /// What Claude gets: the words when there's one instruction; numbered instructions otherwise (the system
        /// prompt says what they mean).
        public var text: String {
            guard parts.count > 1 else { return parts.first ?? "" }
            let numbered = parts.enumerated().map { "\($0.offset + 1). \($0.element)" }
            return "The user said your name partway through, so this request is \(parts.count) instructions, in the "
                + "order said:\n" + numbered.joined(separator: "\n")
        }
    }

    public static func parse(_ said: String) -> Request {
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = words(in: text)
        guard !tokens.isEmpty else { return Request(parts: text.isEmpty ? [] : [text]) }

        func gap(before index: Int) -> Substring {
            text[(index == 0 ? text.startIndex : tokens[index - 1].range.upperBound)..<tokens[index].range.lowerBound]
        }
        func gap(after index: Int) -> Substring {
            text[tokens[index].range.upperBound..<(index + 1 < tokens.count ? tokens[index + 1].range.lowerBound : text.endIndex)]
        }

        /// Where each instruction starts in `text`, and where the one before it ends.
        var cuts: [(end: String.Index, start: String.Index)] = []
        var lead = text.startIndex
        for index in tokens.indices {
            let word = tokens[index].word
            let greeted = index > 0 && greetings.contains(tokens[index - 1].word) && gap(before: index).allSatisfy(joins)
            guard names.contains(word) || (greeted && greetedOnly.contains(word)) else { continue }
            guard index + 1 < tokens.count else { continue }   // nothing after the name

            // The greeting and joining words just before the name go with it.
            var first = index
            while first > 0, (greetings.contains(tokens[first - 1].word) || joiners.contains(tokens[first - 1].word)),
                  gap(before: first).allSatisfy(joins) {
                first -= 1
            }
            let pauseBefore = first < index || first == 0 || gap(before: first).contains(where: pauses.contains)
            let pauseAfter = gap(after: index).contains(where: pauses.contains) || tokens[index + 1].word == "please"
            guard greeted || (pauseBefore && pauseAfter) else { continue }

            var start = tokens[index].range.upperBound
            while start < text.endIndex, text[start].isWhitespace || text[start].isPunctuation { start = text.index(after: start) }
            let end = tokens[first].range.lowerBound

            // Nothing said yet since the last cut: a leading address ("ReGlass, …", "hey ReGlass, ReGlass, …"), dropped.
            let before = text[(cuts.last?.start ?? lead)..<end]
            if !before.contains(where: { $0.isLetter || $0.isNumber }) {
                if cuts.isEmpty { lead = start } else { cuts[cuts.count - 1].start = start }
                continue
            }
            // Part of the words being dictated: "type: hey ReGlass, …", "write hey ReGlass …".
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") || (first > 0 && dictationWords.contains(tokens[first - 1].word)) { continue }
            cuts.append((end: end, start: start))
        }

        var parts: [String] = []
        var from = lead
        for cut in cuts {
            parts.append(clean(text[from..<cut.end]))
            from = cut.start
        }
        parts.append(clean(text[from...]))
        parts.removeAll(where: { !$0.contains(where: { $0.isLetter || $0.isNumber }) })
        return Request(parts: parts.isEmpty ? [text] : parts)
    }

    // MARK: Private

    private static let names: Set<String> = ["reglass", "reeglass"]
    private static let spokenNames = [["re", "glass"], ["ree", "glass"]]
    /// Words that count as the name only after a greeting (everyday words that sound like it). None for now.
    private static let greetedOnly: Set<String> = []
    private static let greetings: Set<String> = ["ok", "okay", "hey", "hi"]
    private static let joiners: Set<String> = ["and", "then", "so", "now", "also"]
    /// The word before a name that makes it part of the dictation ("type hey ReGlass, I'm late").
    private static let dictationWords: Set<String> = ["type", "write", "dictate", "say", "saying", "reply", "text",
                                                      "message", "writes", "says"]
    private static let pauses: Set<Character> = [",", ".", "!", "?", ";", ":", "…", "—", "–"]
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}]+)*"#)

    /// Spaces, commas and dashes: what may sit between "hey" and "ReGlass", or "and then" and "hey".
    private static func joins(_ character: Character) -> Bool {
        character.isWhitespace || character == "," || character == "-"
    }

    private static func words(in text: String) -> [(word: String, range: Range<String.Index>)] {
        let tokens = wordPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range, in: text).map { (word: text[$0].lowercased(), range: $0) }
        }
        // Give the existing address parser one token spanning the whole name, while keeping original string
        // ranges. Literal dictation such as "write re glass" therefore keeps the wearer's exact words.
        var result: [(word: String, range: Range<String.Index>)] = []
        var index = 0
        while index < tokens.count {
            let spelling = spokenNames.first { spelling in
                guard index + spelling.count <= tokens.count else { return false }
                return spelling.indices.allSatisfy { offset in
                    guard tokens[index + offset].word == spelling[offset] else { return false }
                    guard offset > 0 else { return true }
                    let gap = text[tokens[index + offset - 1].range.upperBound..<tokens[index + offset].range.lowerBound]
                    return gap.allSatisfy { $0.isWhitespace || $0 == "-" || $0 == "–" }
                }
            }
            if let spelling {
                result.append((word: "reglass", range: tokens[index].range.lowerBound..<tokens[index + spelling.count - 1].range.upperBound))
                index += spelling.count
            } else {
                result.append(tokens[index])
                index += 1
            }
        }
        return result
    }

    /// Without spaces or a dangling comma at either end, starting with a capital; a full stop at the end stays.
    private static func clean(_ part: Substring) -> String {
        let text = part.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;-–—")))
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
