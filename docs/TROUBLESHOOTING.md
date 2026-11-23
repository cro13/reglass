# Troubleshooting

Find your problem below and work through the checks in order. Quoted lines are what ReGlass shows or says.

Most checks start in **Settings**: the gear button at the top right of Chats, Notes or Reminders. If nothing here
helps, [collect the log](#collect-logs-with-consoleapp) and [report the issue](#report-an-issue).

## Setup can't sign in with Meta

**Continue with Email is greyed out, with "This build has no Meta client credentials. Run the token script in
tools/meta-tokens (see docs/META-CREDENTIALS.md), then rebuild ReGlass."**

The build has no Meta client tokens.

1. Run the token script. See [META-CREDENTIALS.md](META-CREDENTIALS.md).
2. Check that the file is in the root of the ReGlass folder, next to `Config.xcconfig`, and is named exactly
   `Secrets.xcconfig`.
3. Build and run again from Xcode. If the notice stays, choose **Product → Clean Build Folder**, then run again.

The same cause shows as "This build can't set up glasses" later in setup.

**Continue with Email is greyed out, with "This build is missing Meta sign-in data."**

The token script writes the sign-in data to `ReGlassKit/Sources/ReGlassKit/Resources/Generated/bloks-functions.txt`.
If you already have `Secrets.xcconfig`, run the script with `--sign-in-table-only` to generate just the table.
Check that the table is there, then build and run again from Xcode. [Meta credentials](META-CREDENTIALS.md)

**Sign-in starts, but doesn't go through**

- "Meta sign-in couldn't be completed. Try again." or "No connection to Meta. Check that your iPhone is online.":
  check that the iPhone is online, then try again.
- "A different Meta account owns these glasses": tap **Sign In Again** and use the account you set the glasses up
  with in Meta AI.
- "Meta sign-in didn't go through": your sign-in may have expired. Tap **Sign In Again**.
- "Meta didn't accept the hand-over": sign in again with the account that owns the glasses. If it keeps failing, Meta
  may have changed or revoked the client tokens. Get a newer Meta AI Android app and run the script again with
  `--force`.

## Setup can't find or reach the glasses

- **Meta AI is still open.** The glasses talk to one app at a time. Swipe Meta AI away in the iPhone's app switcher,
  then tap **Search Again** or **Try Again**. Setup says so as "Your glasses aren't answering. Wake them, keep them
  close, and close Meta AI." or "Your glasses stopped answering".
- **The glasses are in a closed case, folded or asleep.** Open the case or unfold them, and keep them next to the
  iPhone. "Looking for your glasses…" with nothing listed means ReGlass hears nothing yet.
- **Bluetooth is off or not allowed.** "Turn on Bluetooth": turn it on in Control Center. "Allow Bluetooth": tap
  **Open Settings** and turn on Bluetooth for ReGlass.
- **iOS pairing.** If iOS shows a pairing request, accept it. "Pairing was declined" means it was turned down; try
  again and accept. In **iPhone Settings → Bluetooth**, check that the glasses are listed and connected.
- **Battery.** Charge the glasses if they're low.
- **"These are different glasses"**: another pair answered. Choose the right pair, or tap **Transfer to ReGlass**
  to set up these.
- **"Unlock your iPhone"**: after a restart, ReGlass's saved key stays locked until you unlock the iPhone once.
  Unlock it, then try again.
- **"ReGlass's saved key is damaged"**: delete ReGlass, install it again and set the glasses up again. Your glasses
  aren't affected.
- **It fails after "Making ReGlass the owner".** Ownership may already have moved. **Try Again** reconnects with
  ReGlass's saved key first.
- **"Setup didn't finish"**: try again. If it keeps failing, [collect the log](#collect-logs-with-consoleapp) and
  open an issue.

## The glasses won't reconnect

Look at **Settings → Status → Connection**, or the card on the Glasses screen (tap the glasses card at the top of
Chats).

| It says | What to do |
|---|---|
| "Not connected" and "Stay connected is off…" | Turn on **Stay connected** in Settings, or tap **Connect**. |
| "Looking for glasses" | Take the glasses out of the case or unfold them, keep them close, and close Meta AI. Then tap **Reconnect** in Settings. |
| "Bluetooth is off" | Turn Bluetooth on in Control Center. |
| "Bluetooth not allowed" | Allow Bluetooth for ReGlass in **iPhone Settings → ReGlass**. |
| "Unlock your iPhone" | After a restart, unlock the iPhone once, then tap **Try Again**. |
| "Needs attention": "Your glasses no longer accept ReGlass's key." | They were probably set up again with Meta AI. Close Meta AI and tap **Reconnect or Set Up Again**. It tries ReGlass's key first and offers a transfer only if that fails. |

Also check:

- **You swiped ReGlass away.** iOS never starts an app you swiped away by itself. Open ReGlass once.
- **"This iPhone no longer knows these glasses. Set them up again."** This happens if you removed them in **iPhone
  Settings → Bluetooth**. Tap **Reconnect or Set Up Again** in Settings.
- **Settings → About these glasses → Owner app** says "Not ReGlass any more": another app owns them now. See
  [OWNERSHIP.md](OWNERSHIP.md#if-the-glasses-turn-reglass-down).

## No answer to "Hey Meta"

First, read the footer of the **Assistant** section in Settings. It says in one line whether the assistant can work:

- "Add your Claude key to start.": add it in **Settings → Assistant → Keys**.
- "Speech recognition is still downloading on this iPhone.": keep the iPhone online and try again in a few minutes.
- "It's ready once your glasses are connected.": see [The glasses won't reconnect](#the-glasses-wont-reconnect).
- "Ready on your glasses.": the setup is fine. Read on.

If you hear an apology, it says what's wrong:

| You hear | What to do |
|---|---|
| "I need an Anthropic key first. Add one in ReGlass, under Keys." | Add your Claude key. |
| "Unlock your iPhone once, then ask me again." | Unlock the iPhone once after a restart. |
| "Anthropic didn't accept my key. Check it in ReGlass." | Open **Keys** and tap **Test**. Replace the key if it fails. |
| "There's a billing problem with the Anthropic account." | Check your plan and credits in the Anthropic Console. |
| "Your phone seems to be offline, so I can't answer right now." | Check Wi-Fi or mobile data. |
| "Sorry, I couldn't reach Claude. Please try again." | A network problem on the way to Anthropic. Try again. |
| "I'm still getting speech recognition ready on your iPhone." | iOS is downloading its speech model. Wait a minute. |

More checks:

- **Test the key.** **Settings → Assistant → Keys → Test** checks the model chosen in **Settings → Assistant →
  Model** (Claude Haiku 5.5 here). "Works. Claude Haiku 5.5 is ready." is good. "Claude Haiku 5.5 isn't available to
  this account." means your Anthropic account can't use that model: choose another. "Works. Claude Haiku 5.5 is
  available, but web search isn't." means answers work, but web search doesn't; check your organisation's settings in
  the Anthropic Console.
- **Test without the glasses.** Type a request in **Settings → Assistant → Talk to ReGlass**. If that answers, the
  problem is between the glasses and ReGlass.
- **No chime at all.** The wake word didn't reach ReGlass. Check that the glasses are connected and that Meta AI is
  closed. Try touch and hold instead of "Hey Meta".
- **"Hey Meta" does nothing, but touch and hold works.** Open **Settings → Wake word**. If it says your glasses have no
  wake word files (this happens after a factory reset without Meta AI), tap **Download Factory Set**, then **Restore
  Hey Meta**. Also check that **Listen for "Hey Meta"** is on. Details in
  [WAKE-WORD.md](WAKE-WORD.md#after-a-factory-reset).
- **Speech recognition is off.** In **iPhone Settings → ReGlass**, check that Speech Recognition is on.
- **It answers, but says it can't do that.** The connector for it may be off, or need a permission. Open **Settings →
  Assistant → Connectors**. Weather without location asks which town you mean.
- **With ElevenLabs Scribe.** **Settings → Assistant → Voice and speech** shows key problems, such as "Your ElevenLabs
  key can't transcribe yet." or "ElevenLabs needs you to accept its speech to text terms once." While ElevenLabs turns
  the key away, ReGlass listens with the iPhone's recognizer. See [VOICE.md](VOICE.md).

## No voice heard

- **The iPhone's audio goes elsewhere.** When the iPhone plays to a car, CarPlay, or another Bluetooth speaker or
  headphones, ReGlass plays the reply there instead of in the glasses. Check the audio output in Control Center, or
  disconnect the other device. Why: [GLASSES.md](GLASSES.md#why-audio-going-elsewhere-matters).
- **Volume.** Swipe forward on the touchpad to turn the glasses up. For replies on the iPhone, use the iPhone's volume.
- **Typed requests.** Talk to ReGlass plays through the iPhone's audio, or the glasses when they're connected as its
  headphones. A request typed in Chats is read aloud only when the iPhone's audio goes to headphones or the glasses;
  otherwise the reply shows as text.
- **The voice itself.** In **Settings → Assistant → Voice and speech**, tap **Test**. If the ElevenLabs voice fails,
  Apple's voice speaks instead; Talk to ReGlass then shows "Apple's voice stood in:" and why. A used-up ElevenLabs
  quota is a common cause.
- **Replies cut off after a few seconds.** Another Bluetooth audio stream is starving the glasses' link. See
  [GLASSES.md](GLASSES.md#why-audio-going-elsewhere-matters).

## The interpreter won't start

Open **Settings → Assistant → Live interpreter**. The line above **Start** says what's missing:

| It says | What to do |
|---|---|
| "Connect your glasses to ReGlass first." | See [The glasses won't reconnect](#the-glasses-wont-reconnect). |
| "Add your Claude key first. ReGlass needs it to interpret." | Tap **Open Keys** and add it. |
| "The interpreter needs an ElevenLabs key. Add one in ReGlass's Keys." | Tap **Open Keys** and add an ElevenLabs key that can do speech to text. |
| "The interpreter needs ElevenLabs to understand other languages. Choose ElevenLabs in ReGlass's speech recognition settings." | In **Settings → Assistant → Voice and speech**, under Speech recognition, choose **ElevenLabs Scribe**. |
| "ElevenLabs can't understand speech for ReGlass right now, so the interpreter can't hear other languages." | Check the key's status in Voice and speech: speech to text allowed for the key, the terms accepted, quota left. |
| "The interpreter can't run during a phone call." | End the call first. |
| "ReGlass is still getting your glasses ready. Try again in a moment." | Wait a few seconds. |

Also check:

- **Starting by voice.** "Hey Meta, interpreter, French" needs the **Interpreter** connector switched on in **Settings
  → Assistant → Connectors**. It's off at first, and marked Experimental.
- **Real time off.** **Start** then waits for you: say "Hey Meta" to begin.
- **The iPhone's microphone.** Real time may fall back to it. That needs the Microphone permission, and works only with
  ReGlass open on screen. If you turned it down, tap **Open iPhone Settings** under the Real time switch.

More in [INTERPRETER.md](INTERPRETER.md).

## Alarms don't ring

- **The permission.** In **Settings → Assistant → Connectors → Alarms**, "Allow ReGlass to set alarms on this
  iPhone." means it was never allowed: tap **Allow Alarms**. "Alarms are off for ReGlass. Turn them on in iPhone
  Settings." means you turned it down: tap **Open iPhone Settings** and allow it there.
- **Asked by voice first.** iOS asks for the permission only with ReGlass on screen. If the assistant says "Alarms
  aren't allowed for ReGlass yet. Open ReGlass on your phone once to allow alarms.", open ReGlass and allow it.
- **After a restart.** "ReGlass can't reach its alarms until the iPhone has been unlocked once since it restarted."
  Unlock the iPhone once.
- **Volume.** Alarms play at the iPhone's own alarm volume, which apps can't set. Check **Ringtone and Alerts** in
  **iPhone Settings → Sounds & Haptics**.
- **A locked or hidden app.** If you locked ReGlass with Face ID (touch and hold its icon, then **Require Face ID**),
  or hid it, iOS may hold back its alerts and Lock Screen items. Remove the lock and set the alarm again. How AlarmKit
  treats locked apps hasn't been tested with ReGlass.
- **Clock app alarms.** ReGlass can't see, change or cancel alarms made in the Clock app.
- **The limit.** ReGlass keeps at most 20 alarms. Cancel one to set another.

**Reminders that don't alert:** the **Reminders** connector needs Notifications (**Allow Notifications**). When you
wear the glasses, ReGlass says the reminder there instead of alerting the iPhone. Reminders are time-sensitive
notifications: check that your Focus allows time-sensitive notifications.

## Read and share the activity log

The activity log is a developer tool. ReGlass writes every line to the iPhone's system log and to
`Application Support/ReGlass/events.log`. The file starts over at about 2 MB and is included in iPhone backups.
It holds states, counts, sizes, timings and short device identifiers, such as the end of the serial number and
abbreviated Bluetooth identifiers. It never holds what you said, replies, notes, keys, tokens or audio.

1. In ReGlass, go to **Settings → Developer** and tap **Version** five times. The **Logs** section stays visible
   after this.
2. Open **Activity log**. Use **Filter** to find the lines around the problem.
3. Tap **Export** to open the iPhone share sheet. It exports the whole file, even when you filter the view.

Read the log before sharing. For a public issue, copy just the relevant lines and remove serial number endings,
Bluetooth identifiers and anything else personal.

### Collect logs with Console.app

If you can't open Settings or need to watch the system log live, use Console on a Mac.

1. Connect the iPhone to the Mac with a cable. Unlock it, and tap **Trust** if it asks.
2. Open **Console.app** (in Applications → Utilities).
3. Select the iPhone in the sidebar, under Devices.
4. In the **Action** menu, turn on **Include Info Messages** and **Include Debug Messages**.
5. In the search field, type `reglass` and choose **Subsystem** in the menu that appears. The subsystems are
   `reglass.app` (the app, including the glasses engine's lines) and `reglass.kit` (the glasses engine).
6. Click **Start** to stream, then make the problem happen again. iOS doesn't keep these lines for long, so stream
   first, then reproduce.
7. Select the lines from just before the problem to just after, choose **Edit → Copy**, and paste them into a text
   file.

Read every line before you share it, and cut anything personal, such as a serial number.

## Report an issue

Search the existing issues on GitHub, then use the **Bug report** form. Include the following details.

- what you did, what happened, and what you expected;
- the ReGlass commit you built;
- your iPhone model and iOS version;
- the glasses model and firmware (**Settings → About these glasses**);
- the log lines, if you have them.

For results from other glasses, use the form in [COMPATIBILITY.md](COMPATIBILITY.md#report-your-results). For the
interpreter, see [INTERPRETER.md](INTERPRETER.md#reporting-a-problem).

**Never post these,** in issues, screenshots or logs, not even partly masked:

- Meta's client tokens (`HW|`, `AR|`, `FRL|`) or your `Secrets.xcconfig`;
- your Claude or ElevenLabs key;
- your Meta account email, or sign-in codes;
- your glasses' serial number or other device identifiers (**Settings → Developer** shows the full serial number);
- log lines or screenshots with personal content: what was said, notes, names, places;
- recordings of anyone who hasn't agreed.

If you posted one by mistake, delete it, revoke the key with its service (the Anthropic Console or ElevenLabs), and
tell the maintainers privately.

**Security problems** don't go in public issues. Report them privately, as [SECURITY.md](../SECURITY.md) describes.

Want to fix it yourself? See [CONTRIBUTING.md](../CONTRIBUTING.md).
