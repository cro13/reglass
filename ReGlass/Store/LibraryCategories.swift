import Foundation

/// The short set of categories notes, reminders and list items are sorted into: Shopping,
/// To-do, Appointments, Ideas and Work, plus any the owner names ("put it under Garden"), at most `limit` in all.
///
/// A category is only its name, stored on each note, reminder and item; there's no category model. The defaults always
/// exist; one of the owner's own exists while something carries it (`LibraryStore.categoryNames()`). Names are compared
/// folded (case, accents, "my … list", a plural or a typo don't matter), so "groceries", "my shopping list" and
/// "Shoping" all mean Shopping, and "the office" means Work.
enum LibraryCategory {
    static let shopping = "Shopping"
    static let toDo = "To-do"
    static let appointments = "Appointments"
    static let ideas = "Ideas"
    static let work = "Work"

    /// In the order chips and lists show them.
    static let defaults = [shopping, toDo, appointments, ideas, work]

    /// At most this many categories, defaults included.
    static let limit = 12

    /// A new category's name is at most this long.
    static let maxNameLength = 24

    /// A category's symbol: one per default, a tag for the owner's own. ReGlass's own custom symbols (Phosphor Regular,
    /// in `Assets.xcassets/Categories`), not SF Symbols, so draw it with `Image(category:)` or `Image(_:)`, never
    /// `Image(systemName:)`. Its colour is `LibraryCategory.color`.
    static func symbol(_ name: String) -> String {
        switch canonical(name) {
        case shopping: return "ph.shopping-cart"
        case toDo: return "ph.check-circle"
        case appointments: return "ph.calendar-blank"
        case ideas: return "ph.lightbulb-filament"
        case work: return "ph.briefcase"
        default: return "ph.tag"
        }
    }

    /// True when both names mean the same category.
    static func same(_ a: String, _ b: String) -> Bool {
        let a = key(a), b = key(b)
        return !a.isEmpty && a == b
    }

    /// What a spoken or typed name resolves to.
    enum Resolution: Equatable {
        /// An existing category, by its shown name.
        case existing(String)
        /// A category the owner is naming for the first time, tidied for showing.
        case new(String)
        /// A new name, but `limit` categories exist already.
        case full
        /// Nothing usable was given.
        case empty
    }

    /// `spoken` among `existing` (shown names, as `LibraryStore.categoryNames()` gives them): the same name, a known
    /// other word for a default ("groceries", "office"), or a typo away. Otherwise a new category, unless there are
    /// `limit` already. Only call it with a name the owner said: Claude never invents categories.
    static func resolve(_ spoken: String, among existing: [String]) -> Resolution {
        if let found = match(spoken, among: existing) { return .existing(found) }
        // A name with no letters or digits ("🛒") can't be told apart from another one, so it isn't one.
        guard let name = displayName(spoken), !key(name).isEmpty else { return .empty }
        return existing.count >= limit ? .full : .new(name)
    }

    /// The existing category `spoken` means, or nil.
    static func match(_ spoken: String, among existing: [String]) -> String? {
        let wanted = key(spoken)
        guard !wanted.isEmpty else { return nil }
        let candidates = existing + defaults.filter { name in !existing.contains { same($0, name) } }
        if let exact = candidates.first(where: { key($0) == wanted }) { return exact }
        if let alias = aliases[wanted], let found = candidates.first(where: { same($0, alias) }) { return found }
        // A typo: one letter off for short names, two for long ones.
        let close = candidates.map { ($0, editDistance(key($0), wanted)) }
            .filter { $0.1 <= (wanted.count >= 8 ? 2 : wanted.count >= 4 ? 1 : 0) }
            .min { $0.1 < $1.1 }
        return close?.0
    }

    /// How a new category is shown: single spaces, at most `maxNameLength` characters, first letter capitalised
    /// ("garden" → "Garden", "my car list" → "Car"). Nil when nothing is left.
    static func displayName(_ raw: String) -> String? {
        var words = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        while let first = words.first?.lowercased(), ["my", "the", "a"].contains(first) { words.removeFirst() }
        while let last = words.last?.lowercased(), ["list", "lists", "category"].contains(last) { words.removeLast() }
        var name = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        guard !name.isEmpty else { return nil }
        if name.count > maxNameLength { name = String(name.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces) }
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: Private

    /// Folded words → the default they mean.
    private static let aliases: [String: String] = {
        let table: [String: [String]] = [
            shopping: ["shop", "groceries", "grocery", "supermarket", "to buy", "buy", "store", "market"],
            toDo: ["todo", "to do", "task", "tasks", "chore", "chores", "errand", "errands"],
            appointments: ["appointment", "doctor", "doctors", "dentist", "medical", "visit"],
            ideas: ["idea", "feature idea", "brainstorm", "thought"],
            work: ["office", "job", "work stuff", "business"],
        ]
        var out: [String: String] = [:]
        for (name, words) in table { for word in words { out[key(word)] = name } }
        return out
    }()

    /// The default `name` stands for, or `name` itself.
    private static func canonical(_ name: String) -> String {
        defaults.first { same($0, name) } ?? name
    }

    /// Lowercased, no accents, "-" as a space, without "my"/"the" in front or "list" behind, single spaces, and a
    /// plural "s" dropped: "My Shopping List" → "shopping", "To-dos" → "to do", "Ideas" → "idea".
    private static func key(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "-", with: " ")
        var words = folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        while let first = words.first, ["my", "the", "a", "our"].contains(first) { words.removeFirst() }
        while let last = words.last, ["list", "lists", "category"].contains(last), words.count > 1 { words.removeLast() }
        guard var last = words.popLast() else { return "" }
        if last.count > 3, last.hasSuffix("s"), !last.hasSuffix("ss") { last.removeLast() }
        words.append(last)
        return words.joined(separator: " ")
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
