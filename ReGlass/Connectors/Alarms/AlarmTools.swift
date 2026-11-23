import Foundation
import ReGlassAssistant

// Claude's alarm tools. Results are compact JSON facts for Claude (it words the spoken reply, times as words); the
// `ToolAction` is the line Chats shows. Labels go to Claude and Chats only, never to the activity log.
//
// Alarms are for a time of day and ring on the iPhone (AlarmKit). Countdowns stay with the Timers connector
// (`set_timer`, which rings on the glasses); the descriptions steer Claude between the two.

struct SetAlarmTool: AssistantTool {
    let service: AlarmService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "set_alarm",
            description: """
            Sets an alarm for a time of day on the user's iPhone. It rings on the iPhone (Lock Screen, through Silent \
            mode and Focus) even when ReGlass isn't running, with a nine-minute snooze. Use it for "wake me at seven", \
            "set an alarm for six forty-five on weekdays", "alarm at half past two tomorrow", "alarm in twenty \
            minutes". Not for countdowns ("a timer for ten minutes", "pasta timer"): use set_timer, which rings on the \
            glasses. Not for "remind me to ...": use a reminders tool if you have one. Pass the time as the user said \
            it; ReGlass works out the day and the morning or evening. Returns the alarm as set: its time, rings_at \
            (local, with the weekday), spoken_when ("tomorrow morning", "this evening", "tonight") and repeats. In the \
            reply always say the time with spoken_when ("seven tomorrow morning"). If rolled_over is true the time had \
            just passed today, so it's set for tomorrow: say so briefly. If already_set is true, an identical alarm \
            existed and no new one was made.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "time": [
                        "type": "string",
                        "description": """
                        The time of day in 24-hour HH:MM, such as "07:00", "18:30" or "06:45". Write the hour the user \
                        said; when they didn't say morning or evening, just write it as is ("at seven" is "07:00") and \
                        set am_pm_known to false. Leave it out only with in_minutes.
                        """,
                    ],
                    "am_pm_known": [
                        "type": "boolean",
                        "description": """
                        True when it's clear whether the time is morning or evening: they said am or pm, a 24-hour time, \
                        "in the morning", "tonight", "this evening", or asked to be woken ("wake me at seven" is 07:00, \
                        so true). False for a bare "at seven": ReGlass then picks whichever of 07:00 and 19:00 comes \
                        first.
                        """,
                    ],
                    "date": [
                        "type": "string",
                        "description": """
                        Only when the user named a day: "tomorrow", "on Friday", "on the 30th". That day as YYYY-MM-DD, \
                        worked out from today's date in your context. Leave it out for "at seven" and "wake me at \
                        seven": ReGlass picks the next time it comes round.
                        """,
                    ],
                    "in_minutes": [
                        "type": "integer",
                        "description": """
                        For "an alarm in twenty minutes" or "in an hour": how many minutes from now, 1 to 1440. Leave \
                        out time and date then.
                        """,
                    ],
                    "repeat_days": [
                        "type": "array",
                        "items": ["type": "string", "enum": ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]],
                        "description": """
                        For a repeating alarm, the days of the week it rings: weekdays is mon to fri, weekends is sat \
                        and sun, every day is all seven. Leave it out for a one-off alarm. Only weekly repeats are \
                        possible: for "every other day" or monthly, say ReGlass can't do that.
                        """,
                    ],
                    "label": [
                        "type": "string",
                        "description": """
                        What the alarm is for, in one to three lowercase words, as the user put it: "gym", "take \
                        medicine", "flight". Shown when it rings. Never "alarm" or "wake up". Leave it out when no \
                        reason was given.
                        """,
                    ],
                ],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let clock = AlarmClock(context)
        guard let days = AlarmClock.parseDays(input["repeat_days"]) else {
            return .failure("Alarms can only repeat on days of the week, such as weekdays or every Monday.",
                            action: ToolAction(title: "Couldn't set an alarm", detail: "Repeats weekly only"))
        }
        let inMinutes = input["in_minutes"]?.int ?? input["in_minutes"]?.string.flatMap { Int($0) }
        let resolved: AlarmClock.Resolved
        switch clock.resolve(time: input["time"]?.string, amPmKnown: input["am_pm_known"]?.bool ?? false,
                             day: input["date"]?.string, inMinutes: inMinutes, days: days) {
        case .failure(let failure):
            return .failure(failure.sentence, action: ToolAction(title: "Couldn't set an alarm", detail: failure.chat))
        case .success(let value):
            resolved = value
        }
        let label = AlarmTools.cleanLabel(input["label"]?.string)

        // Said twice: the same alarm is already there.
        if let twin = await service.currentEntries(now: clock.now, timeZone: clock.timeZone).first(where: { AlarmTools.same($0, resolved) }) {
            return .success(AlarmTools.json(.object(["alarm": .object(AlarmTools.describe(twin, clock: clock)), "already_set": true])),
                            action: ToolAction(title: "Alarm already set for \(AlarmTools.chatTime(twin, clock: clock))",
                                               detail: AlarmTools.chatWhen(twin, clock: clock)))
        }

        switch await service.schedule(resolved, label: label) {
        case .failure(let problem):
            let (sentence, detail) = AlarmTools.explain(problem)
            return .failure(sentence, action: ToolAction(title: "Couldn't set an alarm", detail: detail))
        case .success(let record):
            let entries = await service.currentEntries(now: clock.now, timeZone: clock.timeZone)
            let fire = resolved.plan.fire
            var alarm: [String: JSONValue] = [
                "time": .string(clock.clock(fire)),
                "rings_at": .string(clock.stamp(fire)),
                "day": .string(clock.dayWord(fire)),
                "spoken_when": .string(clock.spokenWhen(fire)),
                "minutes_until": .int(max(1, Int((fire.timeIntervalSince(clock.now) / 60).rounded(.up)))),
            ]
            if !record.days.isEmpty {
                alarm["repeats"] = .string(clock.repeatWords(record.days))
                alarm["spoken_when"] = .string("in the \(clock.partOfDay(clock.calendar.component(.hour, from: fire))), \(clock.repeatWords(record.days))")
            }
            if let label { alarm["label"] = .string(label) }
            var result: [String: JSONValue] = [
                "alarm": .object(alarm),
                "snooze_minutes": .int(ReGlassAlarmLook.snoozeMinutes),
                "alarms_set": .int(entries.count),
            ]
            if resolved.rolledOver { result["rolled_over"] = true }
            if let part = resolved.assumedPart { result["am_pm_assumed"] = .string(part) }
            let title = "Set an alarm for \(clock.chatTime(fire))"
            let when = record.days.isEmpty ? clock.chatDay(fire) : clock.chatRepeat(record.days)
            let detail = [when, label.map(AlarmTools.displayLabel), "snooze \(ReGlassAlarmLook.snoozeMinutes) min"]
                .compactMap { $0 }.joined(separator: " · ")
            return .success(AlarmTools.json(.object(result)), action: ToolAction(title: title, detail: detail))
        }
    }
}

struct ListAlarmsTool: AssistantTool {
    let service: AlarmService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "list_alarms",
            description: """
            Lists the alarms ReGlass has set on the iPhone, soonest first: each one's time, label (missing for a plain \
            alarm), when it next rings (rings_at and spoken_when, such as "tomorrow morning"), repeats, and state \
            ("set", "snoozed" with rings_again_at, or "ringing"). Use it for "what alarms do I have?", "when's my \
            alarm?", or to find which alarm the user means. Alarms made in the Clock app can't be seen; if the user \
            asks about one, say so. Not for timers: use list_timers.
            """,
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        if let blocked = await AlarmTools.readBlock(service) {
            let (sentence, detail) = AlarmTools.explain(.blocked(blocked))
            return .failure(sentence, action: ToolAction(title: "Couldn't check your alarms", detail: detail))
        }
        let clock = AlarmClock(context)
        let entries = await service.currentEntries(now: clock.now, timeZone: clock.timeZone)
        let detail = entries.isEmpty ? "None set" : entries.count == 1 ? "1 set" : "\(entries.count) set"
        return .success(AlarmTools.json([
            "alarms": .array(entries.map { .object(AlarmTools.describe($0, clock: clock)) }),
            "note": "Only alarms ReGlass set are listed.",
        ]), action: ToolAction(title: "Checked your alarms", detail: detail))
    }
}

struct CancelAlarmTool: AssistantTool {
    let service: AlarmService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "cancel_alarm",
            description: """
            Cancels alarms ReGlass set, so they don't ring; a repeating alarm stops for good. To cancel one, pass its \
            time ("cancel my seven o'clock alarm": "07:00") or its label ("the gym alarm": "gym"). With neither and \
            only one alarm set, it cancels that one. If more than one could be meant, nothing is cancelled and the \
            candidates come back so you can ask which. For "cancel all my alarms" pass all as true: when two or more \
            are set, the first call cancels nothing and returns them with needs_confirmation; read them back briefly, \
            ask the user to confirm, and call again with all and confirmed both true only after a clear yes. Alarms \
            made in the Clock app can't be cancelled. Not for timers (use cancel_timer), and not for an alarm that is \
            ringing right now (use snooze_alarm to stop it).
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "time": [
                        "type": "string",
                        "description": "The alarm's time in 24-hour HH:MM, as the user said it, such as \"07:00\".",
                    ],
                    "label": ["type": "string", "description": "The alarm's label, such as \"gym\"."],
                    "all": ["type": "boolean", "description": "True to cancel every alarm ReGlass set."],
                    "confirmed": [
                        "type": "boolean",
                        "description": "With all: true only after the user said yes to cancelling them all.",
                    ],
                ],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        if let blocked = await AlarmTools.readBlock(service) {
            let (sentence, detail) = AlarmTools.explain(.blocked(blocked))
            return .failure(sentence, action: ToolAction(title: "Couldn't cancel an alarm", detail: detail))
        }
        let clock = AlarmClock(context)
        let entries = await service.currentEntries(now: clock.now, timeZone: clock.timeZone)
        guard !entries.isEmpty else {
            return .success(AlarmTools.json(["cancelled": [], "alarms": [], "note": "ReGlass has no alarms set."]),
                            action: ToolAction(title: "No alarm to cancel", detail: "None set"))
        }
        let describe: ([AlarmService.Entry]) -> JSONValue = { list in
            .array(list.map { .object(AlarmTools.describe($0, clock: clock)) })
        }

        let candidates: [AlarmService.Entry]
        if input["all"]?.bool == true {
            if entries.count > 1, input["confirmed"]?.bool != true {
                return .success(AlarmTools.json(["cancelled": [], "needs_confirmation": true, "alarms": describe(entries)]),
                                action: ToolAction(title: "Asked before cancelling all alarms", detail: "\(entries.count) set"))
            }
            candidates = entries
        } else {
            let matched = AlarmTools.match(entries, time: input["time"]?.string, label: AlarmTools.cleanLabel(input["label"]?.string),
                                           clock: clock)
            if matched.isEmpty {
                return .success(AlarmTools.json(["cancelled": [], "no_match": true, "alarms": describe(entries)]),
                                action: ToolAction(title: "No alarm to cancel", detail: "None matched"))
            }
            if matched.count > 1 {
                return .success(AlarmTools.json(["cancelled": [], "which_one": describe(matched)]),
                                action: ToolAction(title: "Asked which alarm to cancel", detail: "\(matched.count) could be meant"))
            }
            candidates = matched
        }

        let done = Set(await service.cancel(candidates.map(\.id)))
        let cancelled = candidates.filter { done.contains($0.id) }
        guard !cancelled.isEmpty else {
            return .failure("The alarm couldn't be cancelled. Try again in a moment.",
                            action: ToolAction(title: "Couldn't cancel an alarm", detail: "iOS didn't cancel it"))
        }
        let left = entries.count - cancelled.count
        let title: String
        if cancelled.count == 1, let only = cancelled.first {
            title = only.label.map { "Cancelled the \($0) alarm" } ?? "Cancelled the \(AlarmTools.chatTime(only, clock: clock)) alarm"
        } else {
            title = "Cancelled \(cancelled.count) alarms"
        }
        return .success(AlarmTools.json(["cancelled": describe(cancelled), "still_set": .int(left)]),
                        action: ToolAction(title: title, detail: left == 0 ? "None left" : "\(left) still set"))
    }
}

struct SnoozeAlarmTool: AssistantTool {
    let service: AlarmService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "snooze_alarm",
            description: """
            For an alarm that is ringing right now: snoozes it for nine minutes, or with stop true, stops it (a \
            one-off alarm is then done; a repeating one rings again on its next day). With stop true it also stops an \
            alarm that is snoozed. Use it for "snooze", "snooze the alarm", "stop the alarm", "turn it off" while an \
            alarm rings. Returns what it did and, after a snooze, rings_again_at; ringing false when no alarm is \
            ringing.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "stop": ["type": "boolean", "description": "True to stop the alarm instead of snoozing it."],
                ],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        if let blocked = await AlarmTools.readBlock(service) {
            let (sentence, detail) = AlarmTools.explain(.blocked(blocked))
            return .failure(sentence, action: ToolAction(title: "Couldn't reach your alarms", detail: detail))
        }
        let clock = AlarmClock(context)
        let stop = input["stop"]?.bool ?? false
        let entries = await service.currentEntries(now: clock.now, timeZone: clock.timeZone)
        let ringing = entries.filter { $0.state == .ringing }
        let snoozed = entries.filter { $0.state == .snoozed }

        if stop {
            let targets = ringing.isEmpty ? snoozed : ringing
            guard !targets.isEmpty else {
                return .success(AlarmTools.json(["ringing": false, "stopped": 0]),
                                action: ToolAction(title: "No alarm ringing", detail: nil))
            }
            var stopped = 0
            for entry in targets {
                if await service.stop(entry.id) { stopped += 1 }
            }
            guard stopped > 0 else {
                return .failure("The alarm couldn't be stopped. Use the slider on the iPhone.",
                                action: ToolAction(title: "Couldn't stop the alarm", detail: nil))
            }
            let repeating = targets.contains { $0.repeats }
            return .success(AlarmTools.json(["stopped": .int(stopped), "repeats_again": .bool(repeating)]),
                            action: ToolAction(title: stopped == 1 ? "Stopped the alarm" : "Stopped \(stopped) alarms",
                                               detail: repeating ? "Rings again on its next day" : nil))
        }

        guard !ringing.isEmpty else {
            var result: [String: JSONValue] = ["ringing": false, "snoozed": 0]
            if let next = snoozed.first?.next { result["already_snoozed_until"] = .string(clock.clock(next)) }
            return .success(AlarmTools.json(.object(result)), action: ToolAction(title: "No alarm ringing", detail: nil))
        }
        var again: Date?
        for entry in ringing {
            if let end = await service.snooze(entry.id) { again = again.map { min($0, end) } ?? end }
        }
        guard let again else {
            return .failure("The alarm couldn't be snoozed. Use the Snooze button on the iPhone.",
                            action: ToolAction(title: "Couldn't snooze the alarm", detail: nil))
        }
        return .success(AlarmTools.json(["snoozed": .int(ringing.count), "minutes": .int(ReGlassAlarmLook.snoozeMinutes),
                                         "rings_again_at": .string(clock.clock(again))]),
                        action: ToolAction(title: "Snoozed the alarm", detail: "Rings again at \(clock.chatTime(again))"))
    }
}

enum AlarmTools {
    /// For tools that only read or change existing alarms: never shows iOS's prompt.
    @MainActor
    static func readBlock(_ service: AlarmService) async -> AlarmService.Blocked? {
        switch service.liveAuthorization() {
        case .authorized: return nil
        case .denied: return .denied
        default: return .needsAppOpen
        }
    }

    /// One plain sentence for Claude, and the Chats detail.
    static func explain(_ problem: AlarmService.ScheduleProblem) -> (String, String) {
        switch problem {
        case .blocked(.needsAppOpen):
            return ("Alarms aren't allowed for ReGlass yet. Open ReGlass on your phone once to allow alarms.",
                    "Alarms aren't allowed for ReGlass yet")
        case .blocked(.askedOnScreen):
            return ("ReGlass just asked for permission on the phone's screen. Allow alarms there, then ask again.",
                    "Waiting for permission on the iPhone")
        case .blocked(.denied):
            return ("Alarms are switched off for ReGlass in iPhone Settings.", "Alarms are off in iPhone Settings")
        case .blocked(.locked):
            return ("ReGlass can't reach its alarms until the iPhone has been unlocked once since it restarted.",
                    "Unlock your iPhone once")
        case .tooMany:
            return ("ReGlass already has \(AlarmService.maxAlarms) alarms set, the most it keeps. One has to be cancelled first.",
                    "\(AlarmService.maxAlarms) alarms already set")
        case .systemLimit:
            return ("The iPhone won't take more alarms from ReGlass right now. One has to be cancelled first.",
                    "The iPhone's alarm limit")
        case .failed:
            return ("The alarm couldn't be set. Try again in a moment.", "iOS didn't set it")
        }
    }

    /// The same alarm: same kind of schedule, same time and days, ringing at the same moment.
    static func same(_ entry: AlarmService.Entry, _ resolved: AlarmClock.Resolved) -> Bool {
        guard entry.state == .set, let next = entry.next else { return false }
        switch resolved.plan {
        case .next(let time, let fire):
            return entry.time == time && !entry.repeats && abs(next.timeIntervalSince(fire)) < 60
        case .weekly(let time, let days, _):
            return entry.time == time && entry.days == days.sorted()
        case .fixed(let date):
            return entry.fixed.map { abs($0.timeIntervalSince(date)) < 60 } ?? false
        }
    }

    /// Alarms matching a label and/or a time. A time without am/pm also matches its twin twelve hours away, but only
    /// when nothing matches exactly.
    static func match(_ entries: [AlarmService.Entry], time: String?, label: String?, clock: AlarmClock) -> [AlarmService.Entry] {
        var pool = entries
        if let label {
            let key = matchKey(label)
            pool = pool.filter { entry in
                guard let own = entry.label.map(matchKey) else { return false }
                return own == key || own.contains(key) || key.contains(own)
            }
        }
        let askedTime = time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !askedTime.isEmpty, AlarmClock.parseTime(askedTime) == nil { return [] }
        if let parsed = AlarmClock.parseTime(askedTime) {
            let wanted = parsed.time
            let exact = pool.filter { ringTime($0, clock: clock) == wanted }
            if !exact.isEmpty || parsed.periodGiven {
                pool = exact
            } else {
                let twin = AlarmClock.ClockTime(hour: (wanted.hour + 12) % 24, minute: wanted.minute)
                pool = pool.filter { ringTime($0, clock: clock) == twin }
            }
        } else if label == nil, entries.count > 1 {
            return entries
        }
        return pool
    }

    private static func ringTime(_ entry: AlarmService.Entry, clock: AlarmClock) -> AlarmClock.ClockTime? {
        if let time = entry.time { return time }
        guard let fixed = entry.fixed else { return nil }
        let c = clock.calendar.dateComponents([.hour, .minute], from: fixed)
        return AlarmClock.ClockTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
    }

    /// `{"label": "gym", "time": "07:00", "rings_at": "Wed 2026-10-28 07:00", "spoken_when": "tomorrow morning", ...}`
    static func describe(_ entry: AlarmService.Entry, clock: AlarmClock) -> [String: JSONValue] {
        var object: [String: JSONValue] = ["state": .string(entry.state.rawValue)]
        if let label = entry.label { object["label"] = .string(label) }
        if let time = ringTime(entry, clock: clock) { object["time"] = .string(clock.clock(time)) }
        if entry.repeats { object["repeats"] = .string(clock.repeatWords(entry.days)) }
        switch entry.state {
        case .set:
            if let next = entry.next {
                object["rings_at"] = .string(clock.stamp(next))
                object["day"] = .string(clock.dayWord(next))
                object["spoken_when"] = .string(clock.spokenWhen(next))
            }
        case .snoozed:
            if let next = entry.next { object["rings_again_at"] = .string(clock.clock(next)) }
        case .ringing, .paused:
            break
        }
        return object
    }

    /// "7:00 AM" in the owner's format.
    static func chatTime(_ entry: AlarmService.Entry, clock: AlarmClock) -> String {
        if let time = entry.time { return clock.chatTime(time) }
        if let fixed = entry.fixed { return clock.chatTime(fixed) }
        return "Alarm"
    }

    /// "Tomorrow", "Weekdays", "Ringing", "Snoozed".
    static func chatWhen(_ entry: AlarmService.Entry, clock: AlarmClock) -> String {
        switch entry.state {
        case .ringing: return "Ringing now"
        case .snoozed: return entry.next.map { "Snoozed until \(clock.chatTime($0))" } ?? "Snoozed"
        case .paused: return "Paused"
        case .set:
            if entry.repeats { return clock.chatRepeat(entry.days) }
            return entry.next.map(clock.chatDay) ?? "Set"
        }
    }

    // MARK: Labels

    /// A short label, or nil: trimmed, without quotes or a trailing "alarm", at most 40 characters.
    static func cleanLabel(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’."))),
              !text.isEmpty else { return nil }
        for prefix in ["the ", "my ", "an ", "a "] where text.lowercased().hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.lowercased().hasSuffix(" alarm") { text = String(text.dropLast(" alarm".count)) }
        text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !["alarm", "wake up", "wake-up", "wakeup"].contains(text.lowercased()) else { return nil }
        return String(text.prefix(40))
    }

    static func displayLabel(_ label: String) -> String {
        label.prefix(1).uppercased() + label.dropFirst()
    }

    private static func matchKey(_ text: String) -> String {
        (cleanLabel(text) ?? text).lowercased()
    }

    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
