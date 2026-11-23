# Architecture

ReGlass is one iOS app, two Swift packages and one widget extension. This page shows how they fit together. For an
overview, see the [README](../README.md); for building, [GETTING-STARTED.md](GETTING-STARTED.md); for the look,
[DESIGN.md](DESIGN.md).

## Modules

| Module | Folder | What it does | Depends on |
|---|---|---|---|
| **ReGlassKit** | `ReGlassKit/` | The glasses engine: Bluetooth, the encrypted link, Meta sign-in, ownership, status, touches, the wake word, timers and the glasses' assistant service. No UIKit. | libopus (through `alta/swift-opus`) |
| **ReGlassAssistant** | `ReGlassAssistant/` | The brain and voice: Claude over HTTPS, Apple's and ElevenLabs' voices, speech to text, the Keychain key store, and the turn runner that joins them. | nothing third-party, not ReGlassKit |
| **The app** | `ReGlass/` | Joins the two: screens, the assistant controller, Chats · Notes · Reminders, connectors, the interpreter, setup. | both packages |
| **ReGlassWidgets** | `ReGlassWidgets/` | The widget extension: the Live Activity for alarms and for reminders due within the hour, on the Lock Screen and in the Dynamic Island. | shares one file with the app |

The two packages don't know about each other. The app connects them. ReGlassKit's own rules and public API are in
[`ReGlassKit/DESIGN.md`](../ReGlassKit/DESIGN.md).

### The app's folders

| Folder | Contents |
|---|---|
| `Core/` | `GlassesController` (the one owner of the live connection), discovery, the activity log, app lifecycle |
| `Onboarding/` | Setup: find the glasses, sign in with Meta, transfer ownership |
| `Home/` | The Glasses screen, Settings, the wake word screen |
| `Assistant/` | `AssistantController` (one voice turn from wake to reply), the audio session, barge-in, follow-ups, recording chats, the Keys and speech screens |
| `Chats/`, `Library/`, `Store/`, `Search/` | Chats, Notes and Reminders, their stores, and search across them |
| `Connectors/` | One folder per connector, plus the protocol and the registry (see [CONNECTORS.md](CONNECTORS.md)) |
| `Interpreter/` | The live interpreter (see [INTERPRETER.md](INTERPRETER.md)) |
| `TapToStop/` | What a tap on the glasses stops |
| `Design/` | `Theme` (colours, motion) and shared components |

## The glasses link

Each layer only talks to the one next to it. The app sees only ReGlassKit's public API.

```text
┌───────────────────────────────────────────────────────────────┐
│  App: GlassesController, AssistantController, TapToStop,      │
│       TimerService, screens                                   │
└───────────────────────────────▲───────────────────────────────┘
                                │  public API
┌───────────────────────────────┴───────────────────────────────┐
│  ReGlassKit public API: GlassesConnection, GlassesOwnership, │
│  GlassesAssistantLink, GlassesTimers, WakeWordInstaller       │
├───────────────────────────────────────────────────────────────┤
│  Services: status · assistant (wake, microphone, replies,     │
│  announcements) · timers · touches · wake word                │
├───────────────────────────────────────────────────────────────┤
│  Encrypted link: every connection is encrypted, and           │
│  ReGlass's owner key proves it is the glasses' owner         │
├───────────────────────────────────────────────────────────────┤
│  Bluetooth LE: finding, iOS pairing, staying connected        │
└───────────────────────────────▲───────────────────────────────┘
                                │
                         Ray-Ban Meta glasses
```

Only ReGlassKit's `Bluetooth/` folder touches CoreBluetooth. Meta's servers are used only for sign-in and the
hand-over of ownership during setup (see [OWNERSHIP.md](OWNERSHIP.md)); reconnecting never needs them.

## One voice turn

```text
"Hey Meta" / touch and hold
        │
        ▼
 1. Wake ─────────── the glasses open an assistant turn; ReGlassKit tells the app
        │
        ▼
 2. Microphone ───── the glasses stream your voice; ReGlassKit decodes it to 16 kHz audio
        │
        ▼
 3. Recognition ──── Transcriber: Apple's on-device recognizer, or ElevenLabs if chosen;
        │            it decides when you've finished, and the glasses stop listening
        ▼
 4. Claude ───────── TurnRunner sends the words, the date and time zone, and the tools of
        │            the connectors that are on; it runs Claude's tool calls on the iPhone
        │            and loops until Claude answers (web search runs on Anthropic's side)
        ▼
 5. Voice ────────── the reply is cut into sentences; the voice (Apple's, or ElevenLabs if
        │            set up) speaks each one as it arrives
        ▼
 6. Glasses ──────── ReGlassKit encodes the audio and streams it to the glasses in real time;
                     a chime at the end opens a short follow-up window
```

Notes:

- **Who decides.** ReGlassKit carries audio and turn messages. The app decides when you stopped speaking, when the
  turn ends and whether to listen for a follow-up.
- **Routes.** `EffortRouter` sends quick commands ("set a timer", "pause") with less thinking, so they answer
  faster, and everything else with more.
- **Another speaker.** When the iPhone's audio goes to a car or another Bluetooth speaker, `AssistantController`
  plays the reply there and sends the glasses a short silence instead (see
  [GLASSES.md](GLASSES.md#why-audio-going-elsewhere-matters)).
- **Barge-in.** A new "Hey Meta" mid-reply stops the reply and starts a new turn.
- **Chats.** `ChatRecorder` writes each turn into Chats: what you said, what the tools did, and the reply.
- **Typed requests** (Talk to ReGlass, Chats, the Reminders bar) use the same `TurnRunner`, without the glasses.
- **Logs** hold states, counts, sizes, timings and short device identifiers such as serial suffixes and abbreviated
  Bluetooth identifiers. They never hold transcripts, replies, notes, keys, tokens or audio.

## Where data lives

| What | Where | Synced? |
|---|---|---|
| Chats | SwiftData store in the app's Application Support folder | Never |
| Notes, reminders and list items | A separate SwiftData store, readable after the first unlock so voice notes save with the iPhone locked | Only in a build with iCloud, through your private iCloud database. See [ICLOUD.md](ICLOUD.md). |
| Claude and ElevenLabs keys | Keychain, this device only | Never. Not in backups either. |
| ReGlass's owner key, the glasses' records, the Meta sign-in cache | Encrypted files in Application Support; their encryption keys in the Keychain, this device only | Never. A backup can't open them on another device. |
| Timers, settings and switches | Files and user defaults on the iPhone | Never |
| The activity log | The iPhone's unified log and `Application Support/ReGlass/events.log`. The file starts over at about 2 MB and is included in iPhone backups. | Never |

Like any app's files, the stores can be part of your iPhone's own backups. The keys never are.

The activity log is a developer tool. In **Settings → Developer**, tap **Version** five times to show **Activity
log**. Read it before sharing the file with **Export**. [Collecting and sharing logs](TROUBLESHOOTING.md#read-and-share-the-activity-log)

What goes to Anthropic, ElevenLabs and Open-Meteo is in [PRIVACY.md](PRIVACY.md).

## Connectors

A connector is one thing the assistant can reach: timers, reminders, calendar, music, weather.

- `Connector` (`ReGlass/Connectors/Connector.swift`) describes one: its name, examples, group, status, setup
  button, tools and optional settings.
- `ConnectorRegistry` (`ReGlass/Connectors/ConnectorRegistry.swift`) lists every connector, remembers each on/off
  switch, refreshes their status when ReGlass comes to the foreground, and is the assistant's `ToolProvider`.
- `AssistantTool` (`ReGlassAssistant/Sources/ReGlassAssistant/Tools/AssistantTool.swift`) is one tool Claude can
  call. It never throws, and it has 10 seconds.

Before every request, `TurnRunner` asks the registry for the tools of the connectors that are switched on and usable.
The list of connectors, and how to write one, is in [CONNECTORS.md](CONNECTORS.md).

## Build setup

- **XcodeGen.** `project.yml` describes the project. The generated `ReGlass.xcodeproj` is committed, so building
  needs only Xcode. After you add or remove files, or change `project.yml`, run `xcodegen generate` and commit the
  result.
- **Xcode 27 or newer, iOS 27 SDK.** The app targets iOS 27 and iPhone only.
- **`Config.xcconfig`** holds the team, the bundle ID and the Meta client token settings, all empty. It includes two
  optional, git-ignored files:
  - **`Local.xcconfig`**: your team and bundle ID. Copy `Local.xcconfig.example`.
  - **`Secrets.xcconfig`**: Meta's client tokens, needed for setup and signing in for factory wake word downloads. Copy `Secrets.xcconfig.example`, or let the
    helper in `tools/meta-tokens/` write it. See [META-CREDENTIALS.md](META-CREDENTIALS.md).
- **Sign-in data** (`ReGlassKit/Sources/ReGlassKit/Resources/Generated/bloks-functions.txt`, git-ignored): the
  function names Meta's sign-in screens use, written by the same helper from your copy of the Meta AI app. ReGlassKit
  bundles it when present; without it, setup and factory downloads can't sign in and say so.
- **The widget extension's bundle ID** is the app's ID plus `.widgets`, with the same team.
- **Packages.** ReGlassKit pins `alta/swift-opus` at exactly 0.0.2 (source only). ReGlassAssistant has no
  dependencies. Xcode fetches swift-opus on the first build.
- **The shared file.** `ReGlass/Connectors/Alarms/ReGlassAlarmMetadata.swift` is compiled into both the app and the
  widget extension. If the two disagreed, the Lock Screen countdown would show blank.

Third-party components and their licences are in [THIRD_PARTY.md](../THIRD_PARTY.md).
