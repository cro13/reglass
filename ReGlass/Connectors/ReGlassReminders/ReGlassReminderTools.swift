import Foundation
import ReGlassAssistant

// Claude's tools for ReGlass's own reminders (`LibraryStore`; delivered by `ReminderScheduler`). Setting, moving and
// cancelling answer in their own words (`ToolResult.spokenReply`), so the turn ends without a second Claude round;
// listing goes back to Claude. Titles go to Claude and Chats only, never to the activity log. A reminder deleted on
// screen whose Undo is still showing is left out of all of them.
//
// The words decide: "remind me …" / "a reminder …" is set_reminder; "move / push back / remind me again about" one
// already set is change_reminder; "timer" is set_timer; "add X to my shopping list" or anything to do or buy with no
// time is add_to_list (ReGlass's lists); "wake me" / "alarm" is set_alarm. The descriptions steer Claude between them.

struct SetReminderTool: AssistantTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "set_reminder",
            description: """
            Sets a reminder in ReGlass: at the time, ReGlass says it aloud on the user's glasses, or their iPhone alerts \
            them when they aren't wearing them. Use it whenever the user says "remind me", "a reminder" or "don't let \
            me forget", with a delay or a time: "remind me in six minutes to check on the food", "I want a reminder to \
            check on my food in 6 minutes", "remind me tomorrow at nine to call the dentist", "remind me at eight to \
            call mum". A short delay is still a reminder, not a timer, unless the user says "timer". Something for a \
            list with a day or time is a reminder too ("add call the bank to my to-do list for tomorrow at nine": \
            category To-do). Not for things to do or buy with no time ("I need to buy milk", "add milk to my \
            shopping list": add_to_list), and not for notes. Not for moving, renaming or bringing back a reminder \
            already set ("move the food reminder to eight", "remind me again about the food": change_reminder). Give \
            the time as in_minutes for a delay, or as time (and date when a day was named) for a time of day; ReGlass \
            works out the day and the morning or evening. With neither, don't call it: ask when. ReGlass confirms aloud \
            by itself, so add nothing after it.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "description": """
                        What to be reminded of, in a few lowercase words, as the user put it, without "remind me to": \
                        "check on the food", "call the dentist", "take the laundry out".
                        """,
                    ],
                    "in_minutes": [
                        "type": "integer",
                        "description": """
                        For a delay ("in six minutes", "in an hour"): how many minutes from now. An hour is 60, an hour \
                        and a half is 90. Leave out time and date then.
                        """,
                    ],
                    "time": [
                        "type": "string",
                        "description": """
                        For a time of day: 24-hour HH:MM as the user said it ("at nine" is "09:00", "half past six in \
                        the evening" is "18:30"). When they didn't say morning or evening, write the hour as is and set \
                        am_pm_known to false: ReGlass picks the daytime reading ("at two" is two in the afternoon).
                        """,
                    ],
                    "am_pm_known": [
                        "type": "boolean",
                        "description": """
                        With time: true when it's clear whether it's morning or evening (am or pm, a 24-hour time, \
                        "tonight", "in the morning"). False for a bare "at eight".
                        """,
                    ],
                    "date": [
                        "type": "string",
                        "description": """
                        Only when the user named a day ("tomorrow", "on Friday"): that day as YYYY-MM-DD, from today's \
                        date in your context. A day with no time means nine in the morning.
                        """,
                    ],
                    "announcement": [
                        "type": "string",
                        "description": """
                        What ReGlass says when it's due, as the iPhone's alarm and on the glasses: one short sentence \
                        starting "Hey, your reminder", numbers as words, such as "Hey, your reminder to check on the food \
                        is up." or "Hey, your reminder about the dentist is up." Leave it out to use the title.
                        """,
                    ],
                    "category": [
                        "type": "string",
                        "description": """
                        The category from the context note's list that fits, such as Appointments for calling the \
                        doctor or To-do for the user's to-do list. Leave it out for an everyday one, like checking on \
                        the food. A new category only when the user names one that isn't there.
                        """,
                    ],
                ],
                "required": ["title"],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        guard let title = ReminderSpeech.cleanTitle(input["title"]?.string) else {
            return .failure("A reminder needs a few words on what it's for, such as \"check on the food\". Nothing was set.",
                            action: ToolAction(title: "Couldn't set a reminder", detail: "Nothing to remind about"))
        }
        let clock = AlarmClock(context)

        let due: Date
        let when: String
        switch ReGlassReminderTools.newTime(input, context: context, clock: clock, nothing: "Nothing was set.") {
        case .at(let date, let spoken):
            due = date
            when = spoken
        case .failed(let sentence, let detail):
            return .failure(sentence, action: ToolAction(title: "Couldn't set a reminder", detail: detail))
        case .notGiven:
            return .failure("A reminder needs a time. Nothing was set: ask the user when, such as in ten minutes or tomorrow at nine.",
                            action: ToolAction(title: "Asked when to remind", detail: nil))
        }

        let announcement = ReminderSpeech.cleanAnnouncement(input["announcement"]?.string)
        let source = context.librarySource
        let outcome = await MainActor.run { () -> (saved: ReminderSnapshot?, twin: Bool, phoneAlert: Bool, isNew: Bool, refused: String?) in
            var category: String?
            var isNew = false
            switch CategoryTools.resolve(input["category"], nothing: "Nothing was set.") {
            case .none: break
            case .refused(let sentence): return (nil, false, false, false, sentence)
            case .use(let name, let new):
                category = name
                isNew = new
            }
            let store = LibraryStore.shared
            // Said twice: the same reminder is already there.
            if let twin = store.upcomingReminders().first(where: {
                abs($0.due.timeIntervalSince(due)) < 60 && $0.title.lowercased() == title.lowercased()
                    && !ReminderScheduler.isLeaving($0.id)
            }) {
                LastCapture.record(.reminder, ids: [twin.id])
                return (twin, true, ReminderScheduler.shared.phoneCanAlert(at: twin.due), false, nil)
            }
            let saved = store.addReminder(title: title, due: due, announcement: announcement, category: category,
                                          source: source)
            if let saved { LastCapture.record(.reminder, ids: [saved.id]) }
            return (saved, false, ReminderScheduler.shared.phoneCanAlert(at: due), isNew, nil)
        }
        if let refused = outcome.refused {
            return .failure(refused, action: ToolAction(title: "Couldn't set a reminder", detail: "Too many categories"))
        }
        guard let saved = outcome.saved else {
            return .failure("The reminder couldn't be saved. Nothing was set.",
                            action: ToolAction(title: "Couldn't set a reminder", detail: "ReGlass couldn't save it"))
        }

        // The voice says where it went: "Okay, at nine tomorrow morning: call the doctor, in
        // Appointments."
        var reply = "Okay, \(when): \(saved.title)"
            + (saved.category.map { ", in \($0)\(outcome.isNew ? ", a new category" : "")" } ?? "") + "."
        if !outcome.phoneAlert {
            reply += " Your iPhone can't alert you until notifications are on for ReGlass."
        }
        var facts: [String: JSONValue] = [
            "reminder": ReGlassReminderTools.describe(saved, clock: clock, now: Date()),
            "iphone_alert": .bool(outcome.phoneAlert),
            "said": .string(reply),
        ]
        if outcome.twin { facts["already_set"] = true }
        let detail = ([ReminderSpeech.displayTitle(saved.title), ReminderSpeech.chatWhen(saved.due, clock: clock)]
            + [saved.category].compactMap { $0 }).joined(separator: " · ")
        return .success(ReGlassReminderTools.json(.object(facts)),
                        action: ToolAction(title: outcome.twin ? "Reminder already set" : "Set a reminder", detail: detail),
                        spokenReply: reply)
    }
}

struct ListReGlassRemindersTool: AssistantTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "list_reminders",
            description: """
            Lists the reminders set in ReGlass that haven't gone off yet, soonest first: each one's id, title, due_at \
            (local), spoken_when ("in six minutes", "at nine tomorrow morning"), minutes_left and its category. Use it \
            for "what reminders do I have?", "when's my dentist reminder?", or to find the reminder the user means; \
            with a category, only that category's ("my work reminders"). Say the count first, then the reminders with \
            spoken_when. Not for list items ("what's on my shopping list?": read_list), and not for timers or alarms.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "category": [
                        "type": "string",
                        "description": "Only reminders in this category, when the user names one. Leave it out for all.",
                    ],
                ],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let (open, filed) = await MainActor.run { () -> ([ReminderSnapshot], (asked: String?, found: String?)) in
            let filed = CategoryTools.existing(input["category"])
            let all = ReGlassReminderTools.upcoming()
            guard filed.asked != nil else { return (all, filed) }
            return (all.filter { reminder in
                guard let found = filed.found, let own = reminder.category else { return false }
                return LibraryCategory.same(own, found)
            }, filed)
        }
        let clock = AlarmClock(context)
        let now = Date()
        let shown = Array(open.prefix(10))
        var facts: [String: JSONValue] = [
            "count": .int(open.count),
            "reminders": .array(shown.map { ReGlassReminderTools.describe($0, clock: clock, now: now) }),
        ]
        if open.count > shown.count { facts["more"] = .int(open.count - shown.count) }
        if let found = filed.found { facts["category"] = .string(found) }
        if let asked = filed.asked, filed.found == nil {
            facts["note"] = .string("There's no category like \u{201C}\(asked)\u{201D}.")
        }
        let detail = (open.isEmpty ? "None coming up" : "\(open.count) coming up") + (filed.found.map { " · \($0)" } ?? "")
        return .success(ReGlassReminderTools.json(.object(facts)),
                        action: ToolAction(title: "Checked your reminders", detail: detail))
    }
}

struct CancelReminderTool: AssistantTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "cancel_reminder",
            description: """
            Cancels a reminder set in ReGlass so it doesn't go off ("cancel the food reminder": words "food"), or, with \
            done true, ticks it off because the user already did it ("I already called the dentist", "tick off the \
            dentist reminder"). Pass a few words of its title as words. With no words and only one reminder set, it \
            takes that one. If more than one could be meant, nothing changes and the candidates come back, each with \
            its id and due time: ask which, then call again with that one's id. For "cancel all my reminders" pass \
            all as true: with two or more set, the first call changes \
            nothing and returns them with needs_confirmation; ask, and call again with all and confirmed true only \
            after a clear yes. ReGlass confirms aloud by itself when one was cancelled or ticked off. To move one to \
            another time instead, use change_reminder. Not for timers, alarms or items on an Apple Reminders list.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "words": [
                        "type": "string",
                        "description": "A few words of the reminder's title, such as \"food\" or \"dentist\".",
                    ],
                    "id": [
                        "type": "string",
                        "description": "The id of one reminder from list_reminders or a which_one answer, to pick exactly that one.",
                    ],
                    "done": [
                        "type": "boolean",
                        "description": "True when the user already did it: the reminder is ticked off instead of cancelled.",
                    ],
                    "all": ["type": "boolean", "description": "True for every reminder that hasn't gone off yet."],
                    "confirmed": [
                        "type": "boolean",
                        "description": "With all: true only after the user said yes to cancelling them all.",
                    ],
                ],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let words = ReGlassReminderTools.text(input["words"])
        let id = ReGlassReminderTools.text(input["id"])?.lowercased()
        let done = input["done"]?.bool ?? false
        let all = input["all"]?.bool ?? false
        let confirmed = input["confirmed"]?.bool ?? false
        let clock = AlarmClock(context)
        let now = Date()
        let open = await MainActor.run { ReGlassReminderTools.upcoming() }
        let describe: ([ReminderSnapshot]) -> JSONValue = { list in
            .array(list.map { ReGlassReminderTools.describe($0, clock: clock, now: now) })
        }
        guard !open.isEmpty else {
            return .success(ReGlassReminderTools.json(["changed": [], "reminders": [], "note": "No reminders are set."]),
                            action: ToolAction(title: "No reminder to cancel", detail: "None coming up"))
        }

        let targets: [ReminderSnapshot]
        if all {
            if open.count > 1, !confirmed {
                return .success(ReGlassReminderTools.json(["changed": [], "needs_confirmation": true, "reminders": describe(open)]),
                                action: ToolAction(title: "Asked before cancelling all reminders", detail: "\(open.count) coming up"))
            }
            targets = open
        } else {
            let matched: [ReminderSnapshot]
            if let id, id.count >= 4 {
                matched = open.filter { ReGlassReminderTools.shortID($0).hasPrefix(id) || $0.id.uuidString.lowercased() == id }
            } else {
                matched = ReminderSpeech.match(open, words: words)
            }
            if matched.isEmpty {
                return .success(ReGlassReminderTools.json(["changed": [], "no_match": true, "reminders": describe(open)]),
                                action: ToolAction(title: "No reminder to cancel", detail: "None matched"))
            }
            if matched.count > 1 {
                return .success(ReGlassReminderTools.json(["changed": [], "which_one": describe(matched)]),
                                action: ToolAction(title: "Asked which reminder", detail: "\(matched.count) could be meant"))
            }
            targets = matched
        }

        await MainActor.run {
            for reminder in targets {
                if done {
                    LibraryStore.shared.completeReminder(reminder.id)
                } else {
                    LibraryStore.shared.deleteReminder(reminder.id)
                }
            }
        }
        let left = open.count - targets.count
        let reply: String
        let title: String
        if targets.count == 1, let only = targets.first {
            reply = done ? "Ticked off: \(only.title)." : "Cancelled: \(only.title)."
            title = done ? "Ticked off a reminder" : "Cancelled a reminder"
        } else {
            reply = done ? "Ticked off \(TimerSpeech.words(targets.count)) reminders."
                : "Cancelled \(TimerSpeech.words(targets.count)) reminders."
            title = done ? "Ticked off \(targets.count) reminders" : "Cancelled \(targets.count) reminders"
        }
        let detail: String? = targets.count == 1 ? targets.first.map { ReminderSpeech.displayTitle($0.title) }
            : (left == 0 ? "None left" : "\(left) still coming up")
        let key = done ? "ticked_off" : "cancelled"
        return .success(ReGlassReminderTools.json(.object([key: describe(targets), "still_set": .int(left),
                                                         "said": .string(reply)])),
                        action: ToolAction(title: title, detail: detail),
                        spokenReply: reply)
    }
}

struct ChangeReminderTool: AssistantTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "change_reminder",
            description: """
            Moves a reminder already set in ReGlass to a new time, or renames it: "move the food reminder to eight", \
            "push my reminder back ten minutes", "snooze the food reminder for five minutes", "change the bins \
            reminder to tomorrow at seven", "make the dentist reminder half an hour earlier", or a line typed in the \
            Reminders bar such as "Move “Check on the food” to in 20 minutes". It also brings back one that already \
            went off or was ticked off ("remind me again about the food in ten minutes"): it's set again for the new \
            time. Pass a few words of its title as words; with no words it takes the one that just went off, else the \
            only one set. If more than one could be meant, nothing changes and the candidates come back, each with its \
            id and due time: ask which, then call again with that one's id. Give the new time as for set_reminder: \
            in_minutes from now, or time (and date when a day was named); or, for "push back", "snooze", "later" or \
            "earlier", later_by_minutes from its current time. With no new time or title, don't call it: ask when. Not \
            for a new reminder (set_reminder), for cancelling or ticking one off (cancel_reminder), or for timers, \
            alarms and Apple Reminders lists. ReGlass confirms aloud by itself, so add nothing after it.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "words": [
                        "type": "string",
                        "description": "A few words of the reminder's title, such as \"food\" or \"dentist\".",
                    ],
                    "id": [
                        "type": "string",
                        "description": "The id of one reminder from list_reminders or a which_one answer, to pick exactly that one.",
                    ],
                    "in_minutes": [
                        "type": "integer",
                        "description": """
                        For a new time as a delay from now ("to in twenty minutes", "to an hour from now"): how many \
                        minutes from now. Leave out time, date and later_by_minutes then.
                        """,
                    ],
                    "later_by_minutes": [
                        "type": "integer",
                        "description": """
                        For a shift from its current time: "push it back ten minutes" or "snooze it for ten minutes" is \
                        10, "an hour later" is 60, "half an hour earlier" is -30. One that already went off counts from \
                        now. Leave out in_minutes, time and date then.
                        """,
                    ],
                    "time": [
                        "type": "string",
                        "description": """
                        For a new time of day: 24-hour HH:MM as the user said it ("to eight" is "08:00", "to half past \
                        six in the evening" is "18:30"). When they didn't say morning or evening, write the hour as is \
                        and set am_pm_known to false: ReGlass picks the daytime reading.
                        """,
                    ],
                    "am_pm_known": [
                        "type": "boolean",
                        "description": """
                        With time: true when it's clear whether it's morning or evening (am or pm, a 24-hour time, \
                        "tonight", "in the morning"). False for a bare "to eight".
                        """,
                    ],
                    "date": [
                        "type": "string",
                        "description": """
                        Only when the user named a day ("to tomorrow", "to Friday"): that day as YYYY-MM-DD, from \
                        today's date in your context. A day with no time keeps the reminder's time of day.
                        """,
                    ],
                    "title": [
                        "type": "string",
                        "description": """
                        Only when the user renames it: the new few lowercase words, such as "check the oven". Leave it \
                        out to keep the title.
                        """,
                    ],
                ],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let words = ReGlassReminderTools.text(input["words"])
        let id = ReGlassReminderTools.text(input["id"])?.lowercased()
        let newTitle = ReminderSpeech.cleanTitle(ReGlassReminderTools.text(input["title"]))
        let laterBy = ReGlassReminderTools.integer(input["later_by_minutes"])
        let timeGiven = laterBy != nil || ReGlassReminderTools.integer(input["in_minutes"]) != nil
            || ReGlassReminderTools.text(input["time"]) != nil || ReGlassReminderTools.text(input["date"]) != nil
        guard timeGiven || newTitle != nil else {
            return .failure("Nothing changed: ask the user when to move it to, such as in ten minutes or tomorrow at nine.",
                            action: ToolAction(title: "Asked when to move a reminder", detail: nil))
        }
        let clock = AlarmClock(context)
        let now = Date()
        let (open, pick) = await MainActor.run { () -> ([ReminderSnapshot], ReGlassReminderTools.Pick) in
            let open = ReGlassReminderTools.upcoming()
            let earlier = LibraryStore.shared.earlierReminders(limit: 30).filter { !ReminderScheduler.isLeaving($0.id) }
            return (open, ReGlassReminderTools.pick(open: open, earlier: earlier, words: words, id: id, now: now,
                                                  justWentOff: ReminderScheduler.staleAfter))
        }
        let describe: ([ReminderSnapshot]) -> JSONValue = { list in
            .array(list.map { ReGlassReminderTools.describe($0, clock: clock, now: now) })
        }

        let target: ReminderSnapshot
        switch pick {
        case .one(let one):
            target = one
        case .several(let candidates):
            return .success(ReGlassReminderTools.json(.object(["changed": [], "which_one": describe(candidates)])),
                            action: ToolAction(title: "Asked which reminder", detail: "\(candidates.count) could be meant"))
        case .nothing:
            let note = open.isEmpty ? "No reminders are set. For a new one, use set_reminder."
                : "No reminder matches. For a new one, use set_reminder."
            return .success(ReGlassReminderTools.json(.object(["changed": [], "no_match": true,
                                                             "reminders": describe(Array(open.prefix(10))),
                                                             "note": .string(note)])),
                            action: ToolAction(title: "No reminder to move", detail: open.isEmpty ? "None set" : "None matched"))
        }

        // The new time: a shift from its current time (from now for one that already went off), or as set_reminder
        // reads it, where a day with no time keeps the reminder's time of day.
        var newDue: Date?
        var newWhen: String?
        if let laterBy {
            let moved = max(target.due, now).addingTimeInterval(TimeInterval(laterBy) * 60)
            let limit = ReminderSpeech.maxMinutesAhead
            guard laterBy != 0, (-limit...limit).contains(laterBy), moved.timeIntervalSinceNow > 5 else {
                let sentence = laterBy == 0 ? "A shift of zero minutes changes nothing. Nothing changed."
                    : "That would put it in the past or more than a year ahead. Nothing changed."
                return .failure(sentence, action: ToolAction(title: "Couldn't move a reminder", detail: "That time doesn't work"))
            }
            newDue = moved
            newWhen = ReminderSpeech.absolute(moved, clock: clock)
        } else {
            switch ReGlassReminderTools.newTime(input, context: context, clock: clock, nothing: "Nothing changed.",
                                              dayTime: clock.clock(target.due), keepDay: target.due) {
            case .at(let date, let spoken):
                newDue = date
                newWhen = spoken
            case .failed(let sentence, let detail):
                return .failure(sentence, action: ToolAction(title: "Couldn't move a reminder", detail: detail))
            case .notGiven:
                break
            }
        }
        let due = newDue
        let when = newWhen
        let renamed = newTitle.map { $0.lowercased() != target.title.lowercased() } ?? false
        guard due != nil || renamed else {
            return .failure("It already has that title. Nothing changed: ask the user what to change.",
                            action: ToolAction(title: "Nothing to change", detail: ReminderSpeech.displayTitle(target.title)))
        }

        let reopened = due != nil && !target.isOpen
        let outcome = await MainActor.run { () -> (saved: ReminderSnapshot?, phoneAlert: Bool) in
            // Deleted on screen meanwhile.
            guard !ReminderScheduler.isLeaving(target.id) else { return (nil, false) }
            let saved = LibraryStore.shared.changeReminder(target.id, due: due, title: renamed ? newTitle : nil)
            // Only the title changed: the alert on the Lock Screen still shows the old one.
            if let saved, renamed, due == nil, saved.isOpen { ReminderScheduler.shared.replaceAlert(for: saved.id) }
            return (saved, saved.map { ReminderScheduler.shared.phoneCanAlert(at: $0.due) } ?? false)
        }
        guard let saved = outcome.saved else {
            return .failure("That reminder couldn't be changed; it may have just been deleted. Nothing changed.",
                            action: ToolAction(title: "Couldn't move a reminder", detail: "ReGlass couldn't save it"))
        }

        var reply: String
        let title: String
        if let when, due != nil {
            reply = reopened ? "Okay, again \(when): \(saved.title)."
                : "Okay, moved to \(ReminderSpeech.target(when)): \(saved.title)."
            title = reopened ? "Set a reminder again" : "Moved a reminder"
            if !outcome.phoneAlert { reply += " Your iPhone can't alert you until notifications are on for ReGlass." }
        } else {
            reply = "Okay, renamed: \(saved.title)."
            title = "Renamed a reminder"
        }
        var facts: [String: JSONValue] = [
            "reminder": ReGlassReminderTools.describe(saved, clock: clock, now: Date()),
            "was_due_at": .string(clock.stamp(target.due)),
            "iphone_alert": .bool(outcome.phoneAlert),
            "said": .string(reply),
        ]
        if reopened { facts["set_again"] = true }
        if renamed { facts["renamed_from"] = .string(target.title) }
        let detail = due == nil ? ReminderSpeech.displayTitle(saved.title)
            : "\(ReminderSpeech.displayTitle(saved.title)) · \(ReminderSpeech.chatWhen(saved.due, clock: clock))"
        return .success(ReGlassReminderTools.json(.object(facts)), action: ToolAction(title: title, detail: detail),
                        spokenReply: reply)
    }
}

enum ReGlassReminderTools {
    /// `{"id": "3f2a9c1b", "title": "check on the food", "due_at": "Wed 2026-10-28 19:58", "spoken_when": "in six
    /// minutes", ...}`, and its category when it has one. One whose time has passed says what became of it instead
    /// ("state": "went off").
    static func describe(_ reminder: ReminderSnapshot, clock: AlarmClock, now: Date) -> JSONValue {
        let seconds = reminder.due.timeIntervalSince(now)
        guard reminder.isOpen || seconds > 0 else {
            var facts: [String: JSONValue] = [
                "id": .string(shortID(reminder)),
                "title": .string(reminder.title),
                "due_at": .string(clock.stamp(reminder.due)),
                "state": .string(reminder.fired != nil ? "went off" : "ticked off"),
            ]
            if let category = reminder.category { facts["category"] = .string(category) }
            return .object(facts)
        }
        let spoken = seconds < 2 * 3600 ? ReminderSpeech.relative(until: reminder.due, now: now)
            : ReminderSpeech.absolute(reminder.due, clock: clock)
        var facts: [String: JSONValue] = [
            "id": .string(shortID(reminder)),
            "title": .string(reminder.title),
            "due_at": .string(clock.stamp(reminder.due)),
            "spoken_when": .string(spoken),
            "minutes_left": .int(max(0, Int((seconds / 60).rounded(.up)))),
        ]
        if !reminder.isOpen { facts["state"] = "ticked off" }
        if let category = reminder.category { facts["category"] = .string(category) }
        return .object(facts)
    }

    /// Open reminders, soonest first, without any on its way out (deleted on screen, its Undo still showing).
    @MainActor
    static func upcoming() -> [ReminderSnapshot] {
        LibraryStore.shared.upcomingReminders().filter { !ReminderScheduler.isLeaving($0.id) }
    }

    /// Which reminder change_reminder means.
    enum Pick {
        case one(ReminderSnapshot)
        /// More than one could be meant: ask which.
        case several([ReminderSnapshot])
        case nothing
    }

    /// An id picks exactly one, open or not. Words pick among the open ones first; with none matching, among those
    /// that went off or were ticked off (`earlier`, most recent first), taking the latest when every match has the
    /// same title. No words: the one that went off within `justWentOff` ("push it back ten minutes" right after it
    /// rang), else the only open one.
    static func pick(open: [ReminderSnapshot], earlier: [ReminderSnapshot], words: String?, id: String?, now: Date,
                     justWentOff: TimeInterval) -> Pick {
        if let id, id.count >= 4 {
            let matched = (open + earlier).filter { shortID($0).hasPrefix(id) || $0.id.uuidString.lowercased() == id }
            guard let first = matched.first else { return .nothing }
            return matched.count == 1 ? .one(first) : .several(matched)
        }
        guard words != nil else {
            if let rang = earlier.first(where: { $0.fired.map { now.timeIntervalSince($0) < justWentOff } ?? false }) {
                return .one(rang)
            }
            if open.count == 1, let only = open.first { return .one(only) }
            return open.isEmpty ? .nothing : .several(Array(open.prefix(10)))
        }
        // Every word first, Coming up then Earlier: a title filled into the bar ("Remind me again about “Check on the
        // food”") names its reminder exactly, and must win over one to come that only shares "check". Only then the
        // closest partial match, again Coming up first.
        let fullOpen = ReminderSpeech.fullMatch(open, words: words)
        if fullOpen.count == 1, let only = fullOpen.first { return .one(only) }
        if fullOpen.count > 1 { return .several(fullOpen) }
        let fullGone = ReminderSpeech.fullMatch(earlier, words: words)
        if !fullGone.isEmpty { return pickEarlier(fullGone) }
        let partOpen = ReminderSpeech.match(open, words: words)
        if partOpen.count == 1, let only = partOpen.first { return .one(only) }
        if partOpen.count > 1 { return .several(partOpen) }
        let partGone = ReminderSpeech.match(earlier, words: words)
        return partGone.isEmpty ? .nothing : pickEarlier(partGone)
    }

    /// Among matching reminders that went off or were ticked off (newest first): the newest when they're all the same
    /// reminder by title, else a few to choose from.
    private static func pickEarlier(_ gone: [ReminderSnapshot]) -> Pick {
        guard let latest = gone.first else { return .nothing }
        return Set(gone.map { $0.title.lowercased() }).count == 1 ? .one(latest) : .several(Array(gone.prefix(5)))
    }

    /// A new due time, as set_reminder and change_reminder take it.
    enum NewTime {
        /// The moment, and how the voice says it ("in six minutes", "at nine tomorrow morning").
        case at(Date, when: String)
        case failed(sentence: String, detail: String)
        /// Neither in_minutes nor a time or date.
        case notGiven
    }

    /// Reads in_minutes, or time (with am_pm_known) and date. In minutes count from when the owner asked; a bare
    /// hour ("tomorrow at two") takes the waking-day reading; a day with no time takes `dayTime` (HH:MM). `nothing`
    /// ends each failure sentence for Claude ("Nothing was set.").
    /// `keepDay`: when moving a reminder, its current due date. A new time with no day keeps that day if it's after
    /// today ("move the dentist to ten" leaves Friday's dentist on Friday).
    static func newTime(_ input: JSONValue, context: ToolContext, clock: AlarmClock, nothing: String,
                        dayTime: String = "09:00", keepDay: Date? = nil) -> NewTime {
        let inMinutes = integer(input["in_minutes"])
        let time = text(input["time"])
        var date = text(input["date"])
        if date == nil, time != nil, let keepDay, Calendar.current.startOfDay(for: keepDay) > Calendar.current.startOfDay(for: Date()) {
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.timeZone = context.timeZone
            day.dateFormat = "yyyy-MM-dd"
            date = day.string(from: keepDay)
        }
        let due: Date
        let when: String
        if let inMinutes {
            guard (1...ReminderSpeech.maxMinutesAhead).contains(inMinutes) else {
                return .failed(sentence: "A reminder can be from one minute to a year ahead. \(nothing)",
                               detail: "Up to a year ahead")
            }
            // From when the owner asked, within the last half minute (like a timer).
            let now = Date()
            let start = min(now, max(context.date, now.addingTimeInterval(-30)))
            due = start.addingTimeInterval(TimeInterval(inMinutes * 60))
            when = ReminderSpeech.relative(seconds: inMinutes * 60)
        } else if time != nil || date != nil {
            var resolvedTime = time ?? dayTime
            var amPmKnown = time == nil ? true : (input["am_pm_known"]?.bool ?? false)
            if !amPmKnown, let daytime = daytimeReading(resolvedTime) {
                resolvedTime = daytime
                amPmKnown = true
            }
            switch clock.resolve(time: resolvedTime, amPmKnown: amPmKnown, day: date, inMinutes: nil, days: []) {
            case .failure(let failure):
                let (sentence, detail) = explain(failure, nothing: nothing)
                return .failed(sentence: sentence, detail: detail)
            case .success(let resolved):
                due = resolved.plan.fire
                when = ReminderSpeech.absolute(due, clock: clock)
            }
        } else {
            return .notGiven
        }
        guard due.timeIntervalSinceNow > 5 else {
            return .failed(sentence: "That time has already passed. \(nothing)", detail: "That time has passed")
        }
        return .at(due, when: when)
    }

    /// The first eight hex digits of the reminder's id, lowercased: enough to tell a few reminders apart, short for
    /// Claude to pass back.
    static func shortID(_ reminder: ReminderSnapshot) -> String {
        String(reminder.id.uuidString.prefix(8)).lowercased()
    }

    /// For a time said without morning or evening ("at two"), the reading that falls in the waking day (07:00 to
    /// 21:59) when only one of the two does: "02:00" is "14:00", "10:00" stays "10:00", "12:00" is noon. Nil when both
    /// do ("08:00" or "20:00"): then the usual rule stands, whichever comes first. Reminders only; alarms keep their
    /// own rule.
    static func daytimeReading(_ raw: String) -> String? {
        guard let parsed = AlarmClock.parseTime(raw), !parsed.periodGiven else { return nil }
        let base = parsed.time.hour % 12
        let daytime = [base, base + 12].filter { (7...21).contains($0) }
        guard daytime.count == 1, let hour = daytime.first else { return nil }
        return String(format: "%02d:%02d", hour, parsed.time.minute)
    }

    /// One plain sentence for Claude, ending in `nothing`, and the Chats detail.
    static func explain(_ failure: AlarmClock.Failure, nothing: String = "Nothing was set.") -> (String, String) {
        switch failure.chat {
        case "That time has passed": return ("That time has already passed. \(nothing)", failure.chat)
        case "Too far ahead": return ("Reminders can be set up to a year ahead. \(nothing)", failure.chat)
        case "Couldn't read the date": return ("ReGlass couldn't read that date. Use YYYY-MM-DD. \(nothing)", failure.chat)
        case "No time given": return ("ReGlass couldn't read that time. Use 24-hour HH:MM. \(nothing)", failure.chat)
        default: return ("ReGlass couldn't work out when that reminder is due. \(nothing)", failure.chat)
        }
    }

    /// A trimmed, non-empty string, or nil.
    static func text(_ value: JSONValue?) -> String? {
        guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }

    /// A whole number, passed as a number or as digits, or nil.
    static func integer(_ value: JSONValue?) -> Int? {
        value?.int ?? value?.string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

extension ToolContext {
    /// Said to the glasses, or typed in ReGlass.
    var librarySource: LibrarySource {
        surface == .glasses ? .voice : .typed
    }
}
