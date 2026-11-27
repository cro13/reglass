# Connectors

A connector is one thing the assistant can reach: the glasses' timers, your reminders, your calendar, Apple Music,
the weather. Each one gives Claude a few tools while it's switched on.

Switch them on or off in **Settings → Connectors** (in the Assistant section). Tap a connector for its examples, its
status and its options. When a connector needs a permission, its row says so and has a button for it.

Everything here needs a Claude key (**Settings → Assistant → Keys**). What each connector sends where is in
[PRIVACY.md](PRIVACY.md). How connectors fit into ReGlass is in [ARCHITECTURE.md](ARCHITECTURE.md#connectors).

## On your glasses

### Timers

Timers that ring on your glasses. When one ends, the assistant's voice says what it was for.

- **Needs:** nothing. With the glasses connected, the glasses keep the timer and chime by themselves. Without them,
  the iPhone keeps it and speaks when it ends. See [GLASSES.md](GLASSES.md#timers-on-the-glasses).
- **Say:** "Make me a timer to check on my food in one minute", "How long's left on the pasta?", "Cancel the laundry
  timer".
- **Tools:** `set_timer`, `list_timers`, `cancel_timer`.

### Reminders

Reminders by voice. ReGlass says each one on your glasses when it's due, if you're wearing them. Otherwise your iPhone
alerts you. They live in ReGlass's Reminders tab.

- **Needs:** notifications, so the iPhone can alert you when you aren't wearing the glasses. Reminders due within the
  hour also count down on the Lock Screen, which uses the Alarms permission.
- **Say:** "Remind me in six minutes to check on the food", "Remind me tomorrow at nine to call the dentist", "Move
  the food reminder to eight", "What reminders do I have?"
- **Tools:** `set_reminder`, `list_reminders`, `change_reminder`, `cancel_reminder`, `snooze_reminder`.
- Reminders you type on the Reminders screen go off even when this connector is switched off.

### Notes

Say an idea and it's saved in ReGlass, word for word. Fillers are dropped; nothing is summarised. Ask for your notes
back any time.

- **Needs:** nothing.
- **Say:** "Take a note: a bike rack that folds into the wall", "What were my notes about the bike rack?", "That's not
  shopping, it's for work", "What did I delete?", "Put it back".
- **Tools:** `take_note`, `find_notes`, `add_to_note`, and for notes, reminders and list items alike:
  `move_to_category`, `list_recently_deleted`, `put_back`.

### Lists

Things to buy or do, with no time. ReGlass puts each one on the right list, such as Shopping or To-do, as tick-off
items in its Reminders tab.

- **Needs:** nothing. The lists are ReGlass's own. To use lists in the Reminders app, switch on
  [Apple Reminders](#apple-reminders).
- **Say:** "I need to buy milk, coffee and Coke", "What's on my shopping list?", "I bought the milk", "Clear the
  shopping list".
- **Tools:** `add_to_list`, `read_list`, `tick_off_list_item`, `get_lists`.
- The words decide: no time goes on a list, a day or time makes a reminder, "take a note" makes a note.

### Interpreter (Experimental)

Starts the live interpreter by voice. Experimental. See [INTERPRETER.md](INTERPRETER.md).

- **Needs:** an ElevenLabs key that can do speech to text, ElevenLabs Scribe chosen as your speech recognition (for
  all requests, not only the interpreter), and the glasses.
- **Say:** "Interpreter, French", "Start interpreting Spanish", "Stop interpreting".
- **Tools:** `start_interpreter`.
- With this connector off, the interpreter can't start by voice. Its screen (**Settings → Assistant → Live
  interpreter**) still works.

## On your iPhone

### Calendar

Your iPhone's calendars, including Google calendars synced into iOS. What's on, free time, and new events once you
say yes.

- **Needs:** full access to Calendars. Works with the iPhone locked, once it has been unlocked since a restart.
- **Options:** which calendars ReGlass reads (all by default), and where new events go.
- **Say:** "What's on my calendar today?", "Am I free tomorrow afternoon?", "Add lunch with Alex on Thursday at one".
- **Tools:** `list_events`, `find_free_time`, `add_event`.

### Apple Reminders

The Reminders app on your iPhone, synced through iCloud to your other Apple devices. While it's on, ReGlass keeps your
reminders, to-dos and lists there instead of in its own Reminders tab. Off by default.

- **Needs:** full access to Reminders. Works with the iPhone locked, once it has been unlocked since a restart.
- **Say:** "Remind me tomorrow at nine to call the bank", "Add milk and eggs to my Groceries list", "What's on my
  list in Reminders?", "I bought the milk".
- **Tools:** `add_apple_reminders`, `list_apple_reminders`, `complete_apple_reminder`, `get_apple_reminder_lists`.
- A reminder with a time alerts on the iPhone and your other Apple devices, but isn't said on the glasses. Say "on
  my glasses" or "in ReGlass" to use ReGlass's own Reminders instead, or switch that connector off to use Apple
  Reminders only.
- Nothing is copied between ReGlass's lists and Apple Reminders. Lists shared with you read-only can't be changed.

### Alarms

Real iPhone alarms, set by voice. They ring through Silent mode and Focus, show on the Lock Screen, and work even when
ReGlass is closed. Snooze is nine minutes.

- **Needs:** the Alarms permission.
- **Options:** every alarm ReGlass set, with Delete.
- **Say:** "Wake me at seven", "Set an alarm for six forty-five on weekdays", "What alarms do I have?"
- **Tools:** `set_alarm`, `list_alarms`, `cancel_alarm`, `snooze_alarm`.
- Countdown timers stay with Timers, which ring on the glasses.

### Apple Music

Plays Apple Music: an artist, an album, a playlist or your whole library. Skips, pauses and tells you what's on.
Music plays in the Music app, so it keeps going when ReGlass is in the background, and the glasses' touchpad keeps
controlling it.

- **Needs:** access to Apple Music. To search all of Apple Music, you also need an Apple Music subscription, and
  MusicKit switched on for your bundle ID in your Apple developer account (Identifiers → your app → App Services).
  Without those, ReGlass plays from your library. The connector's options say which applies.
- **Say:** "Play some Rihanna", "Play my Discover playlist", "Skip", "What's playing?"
- **Tools:** `play_music`, `music_control`, `now_playing`.

## Out and about

### Weather

Forecasts for where you are or any town, up to a week ahead.

- **Needs:** location, ideally **Always**, so it also works with the iPhone locked in a pocket. Without location,
  ReGlass uses the home city you set in the options.
- **Source:** [Open-Meteo](https://open-meteo.com/). No key. Your position is sent rounded to about a kilometre.
- **Say:** "What's the weather like?", "Will it rain this afternoon?", "What about tomorrow in Lyon?", "Do I need a
  jacket tonight?"
- **Tools:** `get_weather`.

## Always there

These aren't connectors. They have no switch.

- **Web search and reading web pages.** Claude can search the web and open a page to answer. Both run on Anthropic's
  side, inside the request. Needs only the Claude key. Anthropic bills searches on top of the usual usage.
- **The glasses' sound.** Once glasses are set up: "Turn on adaptive volume", "Turn off spatial audio". Tool:
  `set_glasses_audio`. See [GLASSES.md](GLASSES.md#music-and-bluetooth-audio).

## Write your own connector

A connector is a small Swift class plus one or more tools. You can build one in an afternoon. The protocol is in
`ReGlass/Connectors/Connector.swift`, the registry in `ReGlass/Connectors/ConnectorRegistry.swift`, and the tool
protocol in `ReGlassAssistant/Sources/ReGlassAssistant/Tools/AssistantTool.swift`. Read those three files first:
their comments are the rules.

### 1. Check that it fits

A tool runs on the iPhone while the wearer waits for an answer. It gets **10 seconds**. After that Claude is told it
took too long, and the call is cancelled. Good fits: reading or changing something on the iPhone, or one quick web
request. Bad fits: anything that needs a screen, a long download, or a second app.

### 2. Make a folder

`ReGlass/Connectors/<Name>/`. Put the connector and its tools there.

### 3. Write the tools

Each tool is a type that conforms to `AssistantTool`:

- **`definition`**: a `ToolDefinition` with
  - `name`: lowercase with underscores, unique across all connectors (`get_phone_battery`). A debug build stops if two
    tools share a name.
  - `description`: written for Claude. Say what the tool does, when to use it, **when not to** (name the neighbouring
    tool), and what it returns. Several sentences is normal. Keep it fixed text, with no dates or user data, so it
    stays in the cached part of the prompt.
  - `inputSchema`: a JSON Schema object, written as a `JSONValue` literal.
- **`run(_:context:)`**: does the work and returns a `ToolResult`. It never throws.
  - Return `.success(content, action:)` or `.failure(sentence)`. A failure is one plain sentence Claude can say ("ReGlass
    can't see your calendar yet. Allow access in ReGlass first.").
  - `content` is for Claude only: short plain text or compact JSON.
  - `action` is the line Chats shows for the call ("Checked your timers", "2 running").
  - `spokenReply` is optional. When every call in a round has one, ReGlass speaks those words and ends the turn
    without asking Claude again. That makes confirmations fast. Put the same words in `content`.
  - **Validate the input.** Claude can get arguments wrong; fail with a sentence, never crash. Compare enum strings
    without regard to case.
  - **Honour cancellation.** A new wake word, a dropped link or the 10-second limit cancels the task.
  - `context` tells you the date, the time zone and where the request came from (`.glasses`, `.typed`, `.chat`,
    `.reminders`).
  - Touch UIKit and other main-actor APIs inside `await MainActor.run { … }`.

### 4. Write the connector

A `@MainActor final class` that conforms to `Connector`:

| Property | What it is |
|---|---|
| `id` | Stable and lowercase. It stores the on/off switch, so never change it. |
| `name`, `symbol`, `summary`, `examples` | What Settings → Connectors shows: a name, an SF Symbol, one sentence in the owner's terms, and two or three things to say. |
| `group` | `.glasses`, `.iPhone` or `.places`: the section it sits in. |
| `status()` | `.ready`, `.needsSetup(message:action:)` or `.unavailable(reason)`. Keep it cheap: permission checks only. |
| `setUp()` | Runs when the owner taps the setup button: ask iOS for access, or open iPhone Settings. Call `ConnectorRegistry.shared.refresh()` at the end. |
| `tools` | The tools Claude gets while the connector is on and usable. |
| `isExperimental` | Optional. Shows an Experimental mark. Default `false`. |
| `onByDefault` | Optional. Whether a new install has it on. Default `true`. |
| `settingsView()` | Optional. Extra options inside the connector's screen. |

With `.needsSetup`, the tools still go to Claude, so a request gets "allow access in ReGlass first" instead of "I
can't do that". Your tool has to return that sentence itself. With `.unavailable`, the tools are left out.

### 5. Register it

Add one line to `ConnectorRegistry.makeConnectors()`. The order there is the order within its group in Settings.

```swift
all.append(PhoneBatteryConnector())
```

### 6. Add permissions, if any

- Usage strings go in `ReGlass/Info.plist`. It is written by hand, not generated.
- Entitlements go in `ReGlass/ReGlass.entitlements`, and capabilities in `project.yml`.
- Ask for a permission only in `setUp()`, when the owner taps the button, never at launch.

### 7. Regenerate the project

New files must be in the Xcode project. Run `xcodegen generate` in the repository root, and commit the updated
`ReGlass.xcodeproj` with your change.

### 8. Try it

- Settings → Connectors shows your row, its status and its examples.
- Try it typed first, in **Settings → Assistant → Talk to ReGlass**, then by voice on the glasses.
- Chats shows your `action` line for each call.
- In Console.app, the activity log (subsystem `reglass.app`) must show no content: no titles, names or what was said.
  Log states, counts and timings only.

### 9. Document it

Add a section to this page: what it does, what it needs, what to say, its tools. If it sends data off the iPhone, add
that to [PRIVACY.md](PRIVACY.md). A new service or dependency goes in [THIRD_PARTY.md](../THIRD_PARTY.md). See
[CONTRIBUTING.md](../CONTRIBUTING.md).

### Example: the iPhone's battery

A complete connector with one tool and nothing to allow. Save it as
`ReGlass/Connectors/PhoneBattery/PhoneBatteryConnector.swift`, add the line from step 5, and run `xcodegen generate`.

```swift
import UIKit
import ReGlassAssistant

/// The iPhone's own battery, by voice: "how much battery does my phone have?"
@MainActor
final class PhoneBatteryConnector: Connector {
    let id = "phone-battery"
    let name = "iPhone Battery"
    let symbol = "battery.75percent"
    let summary = "Tells you how much charge your iPhone has left, and whether it's charging."
    let examples = [
        "How much battery does my phone have?",
        "Is my iPhone charging?",
    ]
    let group = ConnectorGroup.iPhone
    let onByDefault = false

    func status() -> ConnectorStatus { .ready }

    func setUp() async {}

    var tools: [any AssistantTool] { [PhoneBatteryTool()] }
}

struct PhoneBatteryTool: AssistantTool {
    var definition: ToolDefinition {
        ToolDefinition(
            name: "get_phone_battery",
            description: """
            Returns the iPhone's battery level as a percentage, and whether it's charging. Use it for "how much \
            battery does my phone have?" or "is my phone charging?". Not for the glasses' battery. ReGlass says the \
            answer by itself, so add nothing after it.
            """,
            inputSchema: ["type": "object", "properties": [:], "additionalProperties": false])
    }

    func run(_ input: JSONValue, context: ToolContext) async -> ToolResult {
        let (level, state) = await MainActor.run { () -> (Float, UIDevice.BatteryState) in
            UIDevice.current.isBatteryMonitoringEnabled = true
            return (UIDevice.current.batteryLevel, UIDevice.current.batteryState)
        }
        guard level >= 0 else {
            return .failure("The iPhone didn't report its battery level.")
        }
        let percent = Int((level * 100).rounded())
        let charging = state == .charging || state == .full
        let reply = "Your iPhone is at \(percent) percent" + (charging ? " and charging." : ".")
        return .success(reply,
                        action: ToolAction(title: "Checked the iPhone's battery", detail: "\(percent) %"),
                        spokenReply: reply)
    }
}
```

What it shows:

- `onByDefault = false`: people switch it on in Settings → Connectors.
- No input, so the schema is an empty object.
- `spokenReply` ends the turn right after the tool, without a second round to Claude.
- The failure is one sentence the assistant's voice can say.
