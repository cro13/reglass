import Foundation
import ReGlassAssistant

// Claude's timer tools. Results are compact JSON facts for Claude (it words the spoken reply, numbers as words);
// the `ToolAction` is the line Chats shows. Labels go to Claude and Chats only, never to the activity log.

struct SetTimerTool: AssistantTool {
    let service: TimerService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "set_timer",
            description: """
            Starts a countdown timer. It rings on the user's glasses (they chime by themselves), and when it ends ReGlass \
            says aloud what it was for. Use it only when the user says "timer" or "countdown": "set a timer for ten \
            minutes", "pasta timer, eight minutes", "make me a timer to check on my food in one minute". When they say \
            "remind me" or "a reminder" instead, use set_reminder, even for a few minutes. Not for a time of day ("at \
            seven") or a date: those are alarms or reminders. Up to eight timers can run at once. Returns the timer as \
            set (label, length in seconds, local end time) and where it rings: "glasses", or "iphone" when the glasses \
            aren't connected, in which case tell the user briefly that you'll tell them on their phone.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "seconds": [
                        "type": "integer",
                        "description": """
                        The timer's length in seconds, from 1 to 86400 (24 hours). Convert what the user said: one \
                        minute is 60, a minute and a half or one and a half minutes is 90, a quarter of an hour is 900, \
                        half an hour is 1800, two hours is 7200.
                        """,
                    ],
                    "label": [
                        "type": "string",
                        "description": """
                        What the timer is for, in one to three lowercase words: the thing to check or do, as the user \
                        put it, such as "food", "pasta", "laundry" or "call mum". Never "timer". Leave it out when the \
                        user gave no reason.
                        """,
                    ],
                    "announcement": [
                        "type": "string",
                        "description": """
                        What ReGlass says aloud when the timer ends: one or two short sentences, numbers written as words, \
                        such as "Your food timer is up. Time to check on your food." Leave it out for a timer without a \
                        label.
                        """,
                    ],
                ],
                "required": ["seconds"],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let seconds = input["seconds"]?.int ?? input["seconds"]?.string.flatMap { Int($0) }
        guard let seconds, (1...TimerService.maxSeconds).contains(seconds) else {
            return .failure("Timers can run from one second to twenty-four hours.",
                            action: ToolAction(title: "Couldn't set a timer", detail: "Timers run up to 24 hours"))
        }
        let label = TimerSpeech.cleanLabel(input["label"]?.string)
        let announcement = label == nil ? nil : TimerSpeech.cleanAnnouncement(input["announcement"]?.string)
        switch await service.add(seconds: seconds, label: label, announcement: announcement, requestedAt: context.date) {
        case .failure(.tooMany):
            return .failure("Eight timers are already running, the most ReGlass can keep. One has to be cancelled first.",
                            action: ToolAction(title: "Couldn't set a timer", detail: "Eight timers are already running"))
        case .success(let added):
            let ends = TimerTools.clock(added.timer.due, in: context.timeZone)
            var timer: [String: JSONValue] = ["length_seconds": .int(added.timer.seconds), "ends_at": .string(ends)]
            if let label { timer["label"] = .string(label) }
            var result: [String: JSONValue] = [
                "timer": .object(timer),
                "rings_on": added.onGlasses ? "glasses" : "iphone",
                "running_timers": .int(added.running),
            ]
            if !added.onGlasses {
                result["note"] = "The glasses aren't connected, so the iPhone will say when it's done."
            }
            let detail = [label.map(TimerSpeech.displayLabel), "ends \(TimerSpeech.clockTime(added.timer.due))",
                          added.onGlasses ? "on your glasses" : "on your iPhone"]
                .compactMap { $0 }.joined(separator: " · ")
            return .success(TimerTools.json(.object(result)),
                            action: ToolAction(title: "Set a timer for \(TimerSpeech.shortDuration(added.timer.seconds))",
                                               detail: detail))
        }
    }
}

struct ListTimersTool: AssistantTool {
    let service: TimerService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "list_timers",
            description: """
            Lists the timers that are running, with what each is for and the time left. Use it for "how long's left on \
            the pasta?", "what timers do I have?", or to find out which timer the user means. Not for reminders \
            (list_reminders). Returns each timer's label (missing for a plain timer), its length and the seconds left, \
            soonest first; an empty list means no timers are running.
            """,
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let timers = await service.timers
        let now = Date()
        let detail = timers.isEmpty ? "None running" : "\(timers.count) running"
        return .success(TimerTools.json(["timers": .array(timers.map { TimerTools.describe($0, now: now, in: context.timeZone) })]),
                        action: ToolAction(title: "Checked your timers", detail: detail))
    }
}

struct CancelTimerTool: AssistantTool {
    let service: TimerService

    var definition: ToolDefinition {
        ToolDefinition(
            name: "cancel_timer",
            description: """
            Cancels running timers so they don't ring. To cancel one, pass its label ("cancel the pasta timer": \
            "pasta"), or its length in seconds for a timer without a label ("cancel the ten-minute timer": 600). Pass \
            all as true for "cancel all my timers". With neither, it cancels the only running timer. If more than one \
            timer could be meant, nothing is cancelled and the candidates come back so you can ask which one. Only for \
            timers: "cancel the food reminder" is cancel_reminder. Returns what was cancelled and how many are still \
            running.
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "label": ["type": "string", "description": "The label of the timer to cancel, such as \"pasta\"."],
                    "seconds": [
                        "type": "integer",
                        "description": "The full length in seconds of the timer to cancel, for a timer without a label.",
                    ],
                    "all": ["type": "boolean", "description": "True to cancel every running timer."],
                ],
                "additionalProperties": false,
            ])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let label = TimerSpeech.cleanLabel(input["label"]?.string)
        let seconds = input["seconds"]?.int
        let all = input["all"]?.bool ?? false
        let now = Date()
        switch await service.cancel(label: label, seconds: seconds, all: all) {
        case .nothingRunning:
            return .success(TimerTools.json(["cancelled": [], "running": []]),
                            action: ToolAction(title: "No timer to cancel", detail: "None running"))
        case .noMatch:
            let running = await service.timers
            return .success(TimerTools.json(["cancelled": [], "no_match": true,
                                             "running": .array(running.map { TimerTools.describe($0, now: now, in: context.timeZone) })]),
                            action: ToolAction(title: "No timer to cancel", detail: "None matched"))
        case .whichOne(let candidates):
            return .success(TimerTools.json(["cancelled": [], "which_one": .array(candidates.map {
                TimerTools.describe($0, now: now, in: context.timeZone)
            })]), action: ToolAction(title: "Asked which timer to cancel", detail: "\(candidates.count) could be meant"))
        case .cancelled(let timers):
            let left = await service.timers.count
            let title: String
            if timers.count == 1, let only = timers.first {
                title = only.label.map { "Cancelled the \($0) timer" }
                    ?? "Cancelled a \(TimerSpeech.shortDuration(only.seconds)) timer"
            } else {
                title = "Cancelled \(timers.count) timers"
            }
            return .success(TimerTools.json(["cancelled": .array(timers.map { TimerTools.describe($0, now: now, in: context.timeZone) }),
                                             "still_running": .int(left)]),
                            action: ToolAction(title: title, detail: left == 0 ? "None left" : "\(left) still running"))
        }
    }
}

enum TimerTools {
    /// `{"label": "pasta", "length_seconds": 480, "seconds_left": 222, "ends_at": "19:58"}`
    static func describe(_ timer: TimerService.Timer, now: Date, in timeZone: TimeZone) -> JSONValue {
        var object: [String: JSONValue] = [
            "length_seconds": .int(timer.seconds),
            "seconds_left": .int(timer.secondsLeft(at: now)),
            "ends_at": .string(clock(timer.due, in: timeZone)),
        ]
        if let label = timer.label { object["label"] = .string(label) }
        return .object(object)
    }

    /// "19:58" in the request's time zone, for Claude (who says it as words).
    static func clock(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}
