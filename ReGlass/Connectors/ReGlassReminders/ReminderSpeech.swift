import Foundation

/// Words for ReGlass's own reminders: what the voice says (numbers as words, for text-to-speech), what Chats shows, the
/// clean-up of what Claude passes in, and matching "the food reminder" to a reminder.
enum ReminderSpeech {
    /// "In N minutes" can be up to a year ahead.
    static let maxMinutesAhead = 525_600

    // MARK: Spoken

    /// What the voice says when a reminder comes due. `lateBy`: how long after its due time this is said (ReGlass wasn't
    /// running when it came due).
    static func dueLine(title: String, announcement: String?, lateBy: TimeInterval) -> String {
        if lateBy >= 45 {
            let minutes = Int((lateBy / 60).rounded())
            let ago = minutes <= 1 ? "about a minute ago" : "\(TimerSpeech.words(minutes)) minutes ago"
            return "A reminder that was due \(ago): \(title)."
        }
        if let announcement { return announcement }
        return "Hey, your reminder is up: \(title)."
    }

    /// "in six minutes", "in a minute", "in an hour", "in an hour and a half", "in two hours and ten minutes".
    static func relative(seconds: Int) -> String {
        switch seconds {
        case ..<60: return "in less than a minute"
        case 60: return "in a minute"
        case 3600: return "in an hour"
        case 5400: return "in an hour and a half"
        default: return "in " + TimerSpeech.duration(seconds)
        }
    }

    /// Time left, rounded to whole minutes, for a reminder already set: "in six minutes".
    static func relative(until due: Date, now: Date) -> String {
        let seconds = due.timeIntervalSince(now)
        guard seconds >= 60 else { return relative(seconds: Int(seconds)) }
        return relative(seconds: Int((seconds / 60).rounded()) * 60)
    }

    /// "at nine tomorrow morning", "at seven thirty this evening", "at noon today", "at nine on Friday morning",
    /// "on November fifth at nine in the morning".
    static func absolute(_ date: Date, clock: AlarmClock) -> String {
        let parts = clock.calendar.dateComponents([.hour, .minute, .month, .day], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let day = clock.dayWord(date)
        let daysAhead = clock.calendar.dateComponents([.day], from: clock.calendar.startOfDay(for: clock.now),
                                                      to: clock.calendar.startOfDay(for: date)).day ?? 0
        if daysAhead > 6 {
            let month = clock.calendar.monthSymbols[max(0, min(11, (parts.month ?? 1) - 1))]
            let dayOfMonth = ordinal(parts.day ?? 1)
            let part: String
            switch clock.partOfDay(hour) {
            case "night": part = "at night"
            case let other: part = "in the \(other)"
            }
            if hour == 12, minute == 0 { return "on \(month) \(dayOfMonth) at noon" }
            if hour == 0, minute == 0 { return "on \(month) \(dayOfMonth) at midnight" }
            return "on \(month) \(dayOfMonth) at \(clockWords(hour: hour, minute: minute)) \(part)"
        }
        let weekday = daysAhead >= 2
        if hour == 12, minute == 0 {
            return "at noon " + (weekday ? "on \(day)" : day)
        }
        let when = clock.spokenWhen(date)
        let time = hour == 0 && minute == 0 ? "midnight" : clockWords(hour: hour, minute: minute)
        return "at \(time) " + (weekday ? "on \(when)" : when)
    }

    /// Where a reminder was moved to, from how its time is said: "eight this evening" for "at eight this evening",
    /// "Friday at nine…" for "on Friday at nine…", "ten minutes from now" for "in ten minutes".
    static func target(_ when: String) -> String {
        if when.hasPrefix("in ") { return String(when.dropFirst(3)) + " from now" }
        if when.hasPrefix("at ") || when.hasPrefix("on ") { return String(when.dropFirst(3)) }
        return when
    }

    /// "nine", "nine oh five", "seven thirty", on a twelve-hour clock.
    static func clockWords(hour: Int, minute: Int) -> String {
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        if minute == 0 { return TimerSpeech.words(twelve) }
        if minute < 10 { return "\(TimerSpeech.words(twelve)) oh \(TimerSpeech.words(minute))" }
        return "\(TimerSpeech.words(twelve)) \(TimerSpeech.words(minute))"
    }

    /// "first", "twenty-second", "thirty-first".
    static func ordinal(_ number: Int) -> String {
        let small = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth",
                     "eleventh", "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth",
                     "eighteenth", "nineteenth", "twentieth"]
        switch number {
        case 1...20: return small[number - 1]
        case 21...29: return "twenty-" + small[number - 21]
        case 30: return "thirtieth"
        case 31: return "thirty-first"
        default: return TimerSpeech.words(number)
        }
    }

    // MARK: Chats

    /// "Check on the food" for Chats, the Lock Screen and notifications.
    static func displayTitle(_ title: String) -> String {
        title.prefix(1).uppercased() + title.dropFirst()
    }

    /// "19:58", "Tomorrow 09:00", "Fri 30 Oct 09:00", in the owner's own format.
    static func chatWhen(_ date: Date, clock: AlarmClock) -> String {
        switch clock.dayWord(date) {
        case "today": return clock.chatTime(date)
        default: return "\(clock.chatDay(date)) \(clock.chatTime(date))"
        }
    }

    // MARK: Claude's input

    /// A short title, or nil: trimmed, without quotes, a trailing full stop or a leading "remind me to", at most 120
    /// characters.
    static func cleanTitle(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”."))),
              !text.isEmpty else { return nil }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for prefix in ["remind me to ", "reminder to ", "a reminder to ", "remind me ", "to "]
        where text.lowercased().hasPrefix(prefix) && text.count > prefix.count {
            text = String(text.dropFirst(prefix.count))
            break
        }
        guard !text.isEmpty, !["reminder", "a reminder"].contains(text.lowercased()) else { return nil }
        return String(text.prefix(120))
    }

    /// Claude's line for the due time, or nil: one or two short sentences, at most 200 characters.
    static func cleanAnnouncement(_ raw: String?) -> String? {
        TimerSpeech.cleanAnnouncement(raw)
    }

    /// ReGlass's reminders that a few words point at ("food" → "check on the food"). Every word matching wins; else the
    /// reminders sharing the most words. No words: all of them.
    static func match(_ reminders: [ReminderSnapshot], words: String?) -> [ReminderSnapshot] {
        let key = keyWords(words ?? "")
        guard !key.isEmpty else { return reminders }
        let scored = reminders.map { reminder -> (reminder: ReminderSnapshot, hits: Int) in
            let own = Set(keyWords(reminder.title))
            return (reminder, key.filter { own.contains($0) }.count)
        }
        let all = scored.filter { $0.hits == key.count }.map(\.reminder)
        if !all.isEmpty { return all }
        guard let best = scored.map(\.hits).max(), best > 0 else { return [] }
        return scored.filter { $0.hits == best }.map(\.reminder)
    }

    /// The reminders whose titles hold every key word of `words`, with no closest-match fallback. All of them for no
    /// words.
    static func fullMatch(_ reminders: [ReminderSnapshot], words: String?) -> [ReminderSnapshot] {
        let key = keyWords(words ?? "")
        guard !key.isEmpty else { return reminders }
        return reminders.filter { reminder in
            let own = Set(keyWords(reminder.title))
            return key.allSatisfy { own.contains($0) }
        }
    }

    /// Lowercased words without "the", "reminder" and the like, plurals folded ("foods" → "food").
    private static func keyWords(_ text: String) -> [String] {
        let skip: Set<String> = ["the", "my", "a", "an", "to", "for", "of", "about", "that", "this", "one", "me",
                                 "reminder", "reminders", "remind", "please"]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !skip.contains($0) }
            .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
    }
}
