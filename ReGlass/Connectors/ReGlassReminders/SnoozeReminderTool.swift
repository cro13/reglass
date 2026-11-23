import Foundation
import ReGlassAssistant

/// snooze_reminder: "Hey Meta, snooze", "snooze that", "snooze it for twenty minutes" after a reminder went off (the
/// context note says which, `ReminderSnooze.contextLine`), or one named by its title ("snooze the food reminder for
/// five minutes"). It ends in `LibraryStore.snoozeReminder`, so the reminder rings again exactly like a new one. ReGlass
/// answers in its own words ("Snoozed till twenty to eight."), so the turn ends without a second Claude round.
/// Titles go to Claude and Chats only, never to the activity log.
struct SnoozeReminderTool: AssistantTool {
    /// The longest snooze, in minutes (twelve hours).
    static let longest = 720

    var definition: ToolDefinition {
        ToolDefinition(
            name: "snooze_reminder",
            description: """
            Snoozes a reminder in ReGlass that just went off, so it goes off again in a few minutes: ten unless the \
            user says how long. Use it for "snooze", "snooze that", "snooze it", "snooze it for twenty minutes" or \
            "ten more minutes" when your context says a reminder went off or was snoozed. With no title it takes the \
            reminder that went off or was snoozed last, within the last hour; "make it twenty minutes" right after a \
            snooze counts from now. Pass title only when the user names one ("snooze the food reminder \
            for five minutes": title "food"); a named one still to come moves that many minutes past its time. An \
            alarm ringing right now is snooze_alarm, not this; with no reminder in your context, a bare "snooze" is \
            for an alarm too. For a new time of day ("move the food reminder to eight"), use change_reminder. ReGlass \
            confirms aloud by itself, so add nothing after it.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "minutes": [
                        "type": "integer",
                        "description": """
                        How long to snooze, from 1 to 720 minutes: "for twenty minutes" is 20, "half an hour" is 30, \
                        "an hour" is 60. Leave it out for the usual ten.
                        """,
                    ],
                    "title": [
                        "type": "string",
                        "description": """
                        Only when the user names the reminder: a few words of its title, such as "food" or "dentist". \
                        Leave it out for "snooze", "snooze that" or "snooze it".
                        """,
                    ],
                ],
                "additionalProperties": false,
            ])
    }

    /// What the store said, read on the main actor.
    private enum Outcome: Sendable {
        case snoozed(was: ReminderSnapshot, now: ReminderSnapshot, minutes: Int, phoneAlert: Bool)
        /// More than one named reminder could be meant; the times are when each went off (nil: still to come).
        case several([ReminderSnapshot], wentOff: [UUID: Date])
        /// A reminder was named and none matched.
        case noMatch
        /// None was named and none went off within the hour.
        case nothing
        /// None was named and an alarm (not a reminder) is ringing right now.
        case alarmRinging
        /// It went missing while it was being snoozed (deleted on screen meanwhile).
        case gone
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let asked = Self.integer(input["minutes"])
        if let asked, !(1...Self.longest).contains(asked) {
            return .failure("A snooze can be from one minute to twelve hours. Nothing changed.",
                            action: ToolAction(title: "Couldn't snooze a reminder", detail: "Up to twelve hours"))
        }
        let words = Self.text(input["title"])
        let now = Date()

        let outcome = await MainActor.run { () -> Outcome in
            let minutes = asked ?? LibraryStore.snoozeMinutes
            let recent = ReminderSnooze.wentOff(within: ReminderSnooze.snoozableFor, now: now)
            let target: ReminderSnapshot
            if let words {
                let rang = Set(recent.map(\.reminder.id))
                let upcoming = LibraryStore.shared.upcomingReminders()
                    .filter { !rang.contains($0.id) && !ReminderScheduler.isLeaving($0.id) }
                switch Self.pick(words, recent: recent.map(\.reminder), upcoming: upcoming) {
                case .one(let one): target = one
                case .several(let candidates):
                    return .several(candidates, wentOff: Dictionary(recent.map { ($0.reminder.id, $0.at) },
                                                                    uniquingKeysWith: { first, _ in first }))
                case .nothing: return .noMatch
                }
            } else {
                // "Snooze" while an alarm rings is the alarm's (snooze_alarm), even after a reminder went off.
                if ReminderScheduler.shared.alarmRinging() { return .alarmRinging }
                guard let last = ReminderSnooze.latest(within: ReminderSnooze.snoozableFor, now: now) else { return .nothing }
                target = last.reminder
            }
            // One still to come moves that much past its time, never earlier than it was; the one just snoozed
            // ("make it twenty minutes") counts from now instead.
            let resnooze = ReminderSnooze.waitingAfterSnooze(within: ReminderSnooze.snoozableFor, now: now)?.reminder.id == target.id
            let ahead = !resnooze && target.isOpen && target.due > now
                ? Int((target.due.timeIntervalSince(now) / 60).rounded()) : 0
            guard !ReminderScheduler.isLeaving(target.id),
                  let snoozed = LibraryStore.shared.snoozeReminder(target.id, for: ahead + minutes, at: now) else {
                return .gone
            }
            return .snoozed(was: target, now: snoozed, minutes: minutes,
                            phoneAlert: ReminderScheduler.shared.phoneCanAlert(at: snoozed.due))
        }

        let clock = AlarmClock(context)
        switch outcome {
        case .snoozed(let was, let snoozed, let minutes, let phoneAlert):
            var reply = "Snoozed till \(Self.spokenTime(snoozed.due, clock: clock))."
            if !phoneAlert { reply += " Your iPhone can't alert you until notifications are on for ReGlass." }
            let facts: [String: JSONValue] = [
                "reminder": Self.describe(snoozed, clock: clock, now: Date()),
                "minutes": .int(minutes),
                "was_due_at": .string(clock.stamp(was.due)),
                "iphone_alert": .bool(phoneAlert),
                "said": .string(reply),
            ]
            let detail = "\(ReminderSpeech.displayTitle(snoozed.title)) · \(ReminderSpeech.chatWhen(snoozed.due, clock: clock))"
            return .success(Self.json(.object(facts)), action: ToolAction(title: "Snoozed a reminder", detail: detail),
                            spokenReply: reply)
        case .several(let candidates, let wentOff):
            let listed: [JSONValue] = candidates.map { reminder in
                var facts: [String: JSONValue] = ["title": .string(reminder.title)]
                if let at = wentOff[reminder.id] {
                    facts["went_off_minutes_ago"] = .int(max(0, Int(now.timeIntervalSince(at) / 60)))
                } else {
                    facts["due_at"] = .string(clock.stamp(reminder.due))
                }
                return .object(facts)
            }
            let facts: [String: JSONValue] = [
                "changed": [],
                "which_one": .array(listed),
                "note": "Ask which one, then call again with more of its title.",
            ]
            return .success(Self.json(.object(facts)),
                            action: ToolAction(title: "Asked which reminder", detail: "\(candidates.count) could be meant"))
        case .noMatch:
            return .failure("No reminder that went off in the last hour or is still to come matches that. Nothing changed.",
                            action: ToolAction(title: "No reminder to snooze", detail: "None matched"))
        case .nothing:
            return .failure("""
                No reminder went off in the last hour, so there's nothing to snooze. Nothing changed. If an alarm is \
                ringing, use snooze_alarm.
                """, action: ToolAction(title: "No reminder to snooze", detail: "None went off lately"))
        case .alarmRinging:
            return .failure("An alarm is ringing right now, not a reminder: snooze it with snooze_alarm. Nothing changed.",
                            action: ToolAction(title: "An alarm is ringing", detail: "Not a reminder"))
        case .gone:
            return .failure("That reminder couldn't be snoozed; it may have just been deleted. Nothing changed.",
                            action: ToolAction(title: "Couldn't snooze a reminder", detail: "ReGlass couldn't save it"))
        }
    }

    // MARK: Picking the named one

    private enum Pick {
        case one(ReminderSnapshot)
        case several([ReminderSnapshot])
        case nothing
    }

    /// Every word first, then the closest partial match; among those that went off (`recent`, latest first) before
    /// those still to come (soonest first). Matches that all share one title are the same reminder: the first.
    private static func pick(_ words: String, recent: [ReminderSnapshot], upcoming: [ReminderSnapshot]) -> Pick {
        let rounds = [ReminderSpeech.fullMatch(recent, words: words), ReminderSpeech.fullMatch(upcoming, words: words),
                      ReminderSpeech.match(recent, words: words), ReminderSpeech.match(upcoming, words: words)]
        guard let found = rounds.first(where: { !$0.isEmpty }), let first = found.first else { return .nothing }
        return Set(found.map { $0.title.lowercased() }).count == 1 ? .one(first) : .several(Array(found.prefix(5)))
    }

    // MARK: Words

    /// How the voice says the new time: "twenty to eight", "half past seven", "ten past nine", "eight", "seven
    /// forty-three", within the next few hours today; later, as a reminder's time ("nine tomorrow morning").
    static func spokenTime(_ date: Date, clock: AlarmClock) -> String {
        guard clock.dayWord(date) == "today", date.timeIntervalSince(clock.now) < 3 * 3600 else {
            return ReminderSpeech.target(ReminderSpeech.absolute(date, clock: clock))
        }
        let parts = clock.calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0
        let minute = parts.minute ?? 0
        let hourWord = { (hour: Int) in TimerSpeech.words(hour % 12 == 0 ? 12 : hour % 12) }
        switch minute {
        case 0: return hour == 12 ? "noon" : (hour == 0 ? "midnight" : hourWord(hour))
        case 15: return "quarter past \(hourWord(hour))"
        case 30: return "half past \(hourWord(hour))"
        case 45: return "quarter to \(hourWord(hour + 1))"
        case 5, 10, 20, 25: return "\(TimerSpeech.words(minute)) past \(hourWord(hour))"
        case 35, 40, 50, 55: return "\(TimerSpeech.words(60 - minute)) to \(hourWord(hour + 1))"
        default: return ReminderSpeech.clockWords(hour: hour, minute: minute)
        }
    }

    // MARK: Helpers (local, as ReGlassReminderTools' are another thread's)

    /// `{"id": "3f2a9c1b", "title": "check on the food", "due_at": "Wed 2026-10-28 19:58", "spoken_when": "in ten
    /// minutes"}`.
    private static func describe(_ reminder: ReminderSnapshot, clock: AlarmClock, now: Date) -> JSONValue {
        let seconds = reminder.due.timeIntervalSince(now)
        let spoken = seconds < 2 * 3600 ? ReminderSpeech.relative(until: reminder.due, now: now)
            : ReminderSpeech.absolute(reminder.due, clock: clock)
        return .object([
            "id": .string(String(reminder.id.uuidString.prefix(8)).lowercased()),
            "title": .string(reminder.title),
            "due_at": .string(clock.stamp(reminder.due)),
            "spoken_when": .string(spoken),
        ])
    }

    /// A trimmed, non-empty string, or nil.
    private static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A whole number, passed as a number or as digits, or nil.
    private static func integer(_ value: JSONValue?) -> Int? {
        value?.int ?? value?.string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
