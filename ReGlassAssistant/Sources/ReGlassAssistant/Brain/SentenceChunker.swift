import Foundation

/// Turns Claude's streamed text into whole sentences for the voice, as early as they're complete.
///
/// A sentence ends at `.`, `!`, `?` or `…` followed by a space or line break (not inside "3.5", "e.g." or "Dr."),
/// or at a line break. Very short sentences ("Sure.") wait to be joined with the next one, except the first piece of a
/// reply, which goes out as soon as it's complete so the voice can start. A long first sentence is split at a clause
/// (comma, semicolon, colon, dash) once it passes `firstClauseLength`, for the same reason.
public struct SentenceChunker: Sendable {
    /// Shorter sentences are joined with the next one (after the first piece).
    public var minimumLength = 24
    /// A first sentence still going past this is cut at its last clause boundary.
    public var firstClauseLength = 90

    private var buffer = ""
    private var emittedCount = 0

    public init() {}

    /// Adds streamed text; returns the sentences completed by it.
    public mutating func add(_ text: String) -> [String] {
        buffer += text
        var out: [String] = []
        while let piece = nextPiece() {
            out.append(piece)
        }
        return out
    }

    /// Everything left, e.g. at the end of the reply or before a pause (a web search).
    public mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        guard !rest.isEmpty else { return nil }
        emittedCount += 1
        return rest
    }

    // MARK: Private

    private mutating func nextPiece() -> String? {
        var searchFrom = buffer.startIndex
        while let end = sentenceEnd(from: searchFrom) {
            let candidate = buffer[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            let firstPiece = emittedCount == 0
            if candidate.isEmpty {
                buffer.removeSubrange(..<end)
                searchFrom = buffer.startIndex
                continue
            }
            if candidate.count >= minimumLength || firstPiece {
                buffer.removeSubrange(..<end)
                emittedCount += 1
                return candidate
            }
            // Too short: keep it and look for the next boundary, so it's spoken together with what follows.
            searchFrom = end
        }
        if emittedCount == 0, buffer.count > firstClauseLength, let clause = lastClauseEnd() {
            let candidate = buffer[..<clause].trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(..<clause)
            emittedCount += 1
            return candidate.isEmpty ? nil : candidate
        }
        return nil
    }

    /// The index just past the first sentence end at or after `start`, if the text after it has arrived.
    private func sentenceEnd(from start: String.Index) -> String.Index? {
        var index = start
        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)
            if character.isNewline {
                return next
            }
            if Self.terminators.contains(character) {
                // Swallow closing quotes and brackets, and runs like "?!" or "...".
                var end = next
                while end < buffer.endIndex, Self.terminators.contains(buffer[end]) || Self.closers.contains(buffer[end]) {
                    end = buffer.index(after: end)
                }
                guard end < buffer.endIndex else { return nil }   // wait for what follows
                if buffer[end].isWhitespace, !isAbbreviation(endingAt: index) {
                    return end
                }
                index = end
                continue
            }
            index = next
        }
        return nil
    }

    /// "Dr.", "e.g.", "a.m.", single initials: a full stop that doesn't end the sentence.
    private func isAbbreviation(endingAt dot: String.Index) -> Bool {
        guard buffer[dot] == "." else { return false }
        var start = dot
        while start > buffer.startIndex {
            let previous = buffer.index(before: start)
            if buffer[previous].isWhitespace || buffer[previous] == "(" { break }
            start = previous
        }
        let word = buffer[start..<dot].lowercased()
        if word.count == 1, word.first?.isLetter == true { return true }   // "J. Smith"
        return Self.abbreviations.contains(word)
    }

    private func lastClauseEnd() -> String.Index? {
        var found: String.Index?
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let next = buffer.index(after: index)
            if Self.clauseMarks.contains(buffer[index]), next < buffer.endIndex, buffer[next].isWhitespace,
               buffer.distance(from: buffer.startIndex, to: index) >= 20 {
                found = next
            }
            index = next
        }
        return found
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")"]
    private static let clauseMarks: Set<Character> = [",", ";", ":", "—", "–"]
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "sr", "jr", "prof", "vs", "etc", "e.g", "i.e", "a.m", "p.m", "u.s", "u.k",
        "approx", "mt", "ft", "inc", "ltd",
    ]
}
