# Privacy

ReGlass has no server and no account of its own. Nothing goes to the people who make ReGlass. What leaves your
iPhone goes straight from the iPhone to the services on this page, with your own keys, when a feature needs it.

This page lists what stays on the iPhone, and what goes where, to whom and when. Each item was checked against the
code. If you change the code, check this page again.

## At a glance

| Who | When | What they get |
|---|---|---|
| **Anthropic** (Claude) | Every request you speak or type; typed notes without a title; interpreter sentences | Text, never audio: your words, a context note, tool results. Web searches run on Anthropic's side. |
| **ElevenLabs** | Only if you add a key and choose ElevenLabs (the interpreter needs Scribe chosen); saving a key runs one test call | Your audio for Scribe; reply text for the voice; the interpreter's audio |
| **Apple** | Music requests, place names, iCloud (only in a build with it) | Search terms for Apple Music, places to look up, your library through iCloud |
| **Open-Meteo** | When you ask about the weather | Coordinates, rounded to about a kilometre |
| **Meta** | During setup, a factory wake word download you confirm, and firmware update checks (at most every six hours) | Your sign-in, glasses' serial and firmware details, and the hand-over of ownership |
| **Your glasses** | While connected, over an encrypted Bluetooth link | Replies, announcements, timers, sound settings |

Every service also sees your iPhone's IP address, as any server does. Each one keeps what it gets as its own privacy
policy says. Deleting something in ReGlass doesn't delete what a service already received.

## What stays on the iPhone

- **Your voice, by default.** Apple's speech recognizer runs on the iPhone. With it, the audio never leaves the iPhone.
- **The voice, by default.** Apple's voice is made on the iPhone. With it, the reply's text never leaves the iPhone.
- **"Hey Meta" over a reply.** ReGlass listens for it with Apple's on-device recognizer, whatever you chose.
- **Chats, notes, reminders and lists.** In local stores on the iPhone. Notes, reminders and lists sync only in a build
  with iCloud (see below). Chats never sync.
- **Search across Chats, Notes and Reminders.** It runs on the iPhone.
- **Your calendars and music library.** ReGlass reads them on the iPhone. They go to Claude only as tool results,
  when you ask about them (see Anthropic).
- **Keys, ReGlass's owner key and the Meta sign-in.** See [Where things are stored](#where-things-are-stored).
- **Settings and switches.** Your choices for connectors, the Claude model, voice and speech stay on this iPhone.
- **The activity log.** See [Logs](#logs).

## Anthropic (Claude)

Claude writes every answer, so Anthropic gets a request each time you ask something. Requests go over HTTPS to
`api.anthropic.com` with your Anthropic key, for the model you chose in **Settings → Assistant → Model**. With
Sonnet 5.5, Opus 5.5 or Fable 5.2, a request that Anthropic's safety checks decline can be answered by another
Claude model instead (Anthropic's server-side fallback); it stays with Anthropic.

What a request holds:

- **Your words, as text.** What you said after the wake word, written down on the iPhone (or by ElevenLabs Scribe, if
  you chose it). Never the audio.
- **What you type:** in the Ask ReGlass bar in Chats, a reply in a chat, Talk to ReGlass, and the bar on
  Reminders.
- **A context note:** the date, the local time and your time zone; the names of your categories; which list is open on
  screen.
- **Earlier words of the conversation.** A follow-up carries the turns before it. A new request carries your previous
  exchange, what you said and the reply, if it was in the last five minutes. A reply in an older chat carries what was
  said earlier in that chat.
- **The tools of the connectors that are on,** and the **results** of the tools Claude calls. A result can hold your
  data: matching notes, your reminders and list items, calendar events, a forecast with its place name (your town,
  for the weather where you are), what's playing.
- **Web search and web pages.** These run on Anthropic's side, as Claude's own server tools. Claude writes the search
  query, and may put your city or region in it. ReGlass gives the search tool only your time zone as a location.
  Pages are fetched by Anthropic, not by your iPhone.

Other requests to Anthropic:

- **Typed notes without a title.** When you write a note in the Notes bar, its text (up to 4,000 characters) and your
  category names go to Claude, which suggests a title and a category. Notes you say by voice don't need this.
- **The interpreter.** The text of each sentence it heard, to be translated.
- **Checks with no content.** Test on the Keys screen, and a connection warm-up when you wake the assistant, read the
  model's details. They carry your key and nothing you said.

## ElevenLabs

Nothing goes to ElevenLabs unless you add an ElevenLabs key and choose ElevenLabs in **Settings → Assistant → Voice and
speech**. The interpreter needs ElevenLabs Scribe chosen there, which sends all your speech recognition to ElevenLabs.
One exception: saving a key runs a short test, a Scribe session with no audio, or the word "Hello" spoken in your
chosen ElevenLabs voice if you set a voice ID. Requests go to `api.elevenlabs.io` with your ElevenLabs key.

- **With ElevenLabs Scribe:** your voice, from the wake word to the end of each request, streamed while you speak.
  With it go the names of towns near you, to help Scribe spell them. ReGlass works those names out on the iPhone (see
  Apple).
- **With an ElevenLabs voice:** the text of each reply, sentence by sentence, and of announcements such as a timer
  that ended or a reminder that's due.
- **Reminder alert sounds, with an ElevenLabs voice:** when ReGlass places a reminder's iPhone alert, it sends the
  reminder's line once ("Hey, your reminder to … is up.") and keeps the recording on the iPhone as the alert's sound.
- **The interpreter:** the sound of the conversation for the whole session, the other person's voice and yours, to
  Scribe. The English translation goes to the ElevenLabs voice if that's the voice you chose.
- **Tests and checks:** Test on Voice and speech says "Hi, this is how ReGlass sounds."; Test on the Keys screen says
  "Hello." when a voice ID is set. Checks of the key's speech to text send no audio.

ElevenLabs offers zero retention only on enterprise plans, so ReGlass doesn't ask for it. See
[VOICE.md](VOICE.md#privacy).

## Apple

- **Speech recognition** runs on the iPhone. iOS downloads its English model once from Apple; no audio is sent.
- **The voice** is made on the iPhone.
- **Apple Music (MusicKit).** When you ask for music, the search terms go to Apple Music's catalog, under your Apple
  ID. Music plays in the Music app.
- **Place lookups (MapKit).** Place names you ask about, such as "tomorrow in Lyon", go to Apple's geocoder. For the
  weather where you are, ReGlass asks it for the name of the place at your position. If you allowed location
  and chose ElevenLabs Scribe, ReGlass also looks up the towns at and around your last known position, a few seconds
  after launch and when you have moved, and keeps their names on the iPhone. This list is what Scribe gets; with the
  iPhone's own recognizer, ReGlass doesn't make it.
- **Apple Weather (WeatherKit)** is not used. The code is there, but switched off; ReGlass gets forecasts from
  Open-Meteo.
- **iCloud.** Only in a build with `REGLASS_ICLOUD = YES`: notes, reminders, list items and Recently Deleted sync
  through your private iCloud database, and the iPhone registers for CloudKit's change notifications. Chats, keys,
  settings and the log never sync. See [ICLOUD.md](ICLOUD.md).
- **Calendars, alarms and notifications** use Apple's frameworks on the iPhone. If your calendars sync with an
  account, such as iCloud or Google, iOS does that, not ReGlass.

## Open-Meteo

When you ask about the weather, with the Weather connector on, ReGlass asks
[Open-Meteo](https://open-meteo.com) for a forecast over HTTPS. The request holds the place's latitude and longitude,
rounded to two decimals (about a kilometre), and nothing else: no key, no account, no ID. The place is where you are,
your home city, or the town you named.

## Meta

ReGlass contacts Meta during setup, when you explicitly download a factory wake word set, and to look for firmware
updates:

- **Signing in:** your email, the account you pick, the code Meta emails you, and a random ID ReGlass made for this
  install. The pictures on Meta's account picker load from Meta's servers. ReGlass uses client tokens from your copy
  of Meta AI for Android. [Meta client tokens](META-CREDENTIALS.md)
- **The hand-over:** your sign-in and what Meta needs to sign it, including your glasses' serial number and the public
  half of ReGlass's new key. See [OWNERSHIP.md](OWNERSHIP.md).
- **Factory wake word download:** only after you tap **Download Factory Set** and confirm, ReGlass uses your
  Meta sign-in and sends your glasses' serial number and firmware details to Meta's update service. The signed
  download URLs stay in memory. The package downloads use separate sessions with no login header or cookies.
  ReGlass verifies the packages, saves only the eight factory files locally, and discards the full packages.
  It never uploads wake word files. The saved set stays out of iCloud and computer backups.
- **Firmware update checks:** while you're signed in, ReGlass asks Meta's update service whether there is new
  firmware for your glasses: when they connect, every few hours while ReGlass runs and when you open it, at most once
  every six hours. It sends your Meta sign-in, your glasses' serial number and their device type. An update you
  install is downloaded from Meta with your sign-in and sent to your glasses. See [FIRMWARE.md](FIRMWARE.md).

ReGlass keeps the sign-in on the iPhone, encrypted. **Settings → Sign Out of Meta** deletes it.

**Everyday reconnection uses Bluetooth and ReGlass's own key.** It needs no Meta request. ReGlass contacts Meta
again only if you sign in, set glasses up again, confirm a factory wake word download, or to look for and install
firmware updates. Assistant conversations
are not sent to Meta. Your glasses stay linked to your Meta account.

## Your glasses

ReGlass talks to the glasses over Bluetooth, on an encrypted link. It sends them the replies' audio, announcements,
running timers, the sound settings you choose and, if you install one, a wake word set. The glasses send their status
and, after the wake word or a touch and hold, or while the interpreter runs, their microphones.

ReGlass opens the microphones only for the assistant and the interpreter. It doesn't record in the background.

## Where things are stored

| What | Where | Synced | In iPhone backups |
|---|---|---|---|
| Claude and ElevenLabs keys | The Keychain, readable after the first unlock, this device only | Never | They never move to another iPhone |
| ReGlass's owner key, the glasses' records, the Meta sign-in | Encrypted files in the app's Application Support folder; their keys in the Keychain, this device only | Never | The files can be in a backup, but can't be opened on another iPhone |
| Chats | A local store in Application Support | Never | Yes |
| Notes, reminders, list items, categories and Recently Deleted | A separate local store in Application Support | Only in a build with iCloud | Yes |
| Timers, the alarms ReGlass set, reminder alerts, reminder alert sounds | Small files in the app's folders | Never | Yes |
| Settings: connector switches, voice choice, ElevenLabs voice ID, home city, the nearby town names | The app's settings (user defaults) | Never | Yes |
| The activity log | `Application Support/ReGlass/events.log` in the app's container, plus the iPhone's system log | Never | Yes, the file is included |

- **File protection.** The stores and files are locked until you unlock the iPhone once after it starts, so voice
  notes can still be saved with the iPhone locked.
- **Backups.** An iPhone backup to iCloud or to a Mac includes your chats, library and activity log like other app
  files. Wake word sets are excluded. [Wake word storage](WAKE-WORD.md#reglass-includes-no-wake-word-files)
- **Deleting ReGlass** deletes its files and its key from the iPhone. See [OWNERSHIP.md](OWNERSHIP.md).

### Recently Deleted

Deleted chats, notes, reminders and list items wait in **Recently Deleted** for 30 days, then ReGlass erases them for
good. Find it at the end of Chats, Notes or Reminders. **Delete** or **Delete All** there erases at once.

## Logs

The activity log is a developer tool. ReGlass writes each line to the iPhone's system log and to
`Application Support/ReGlass/events.log`. The file starts over at about 2 MB and is included in iPhone backups.
You choose whether to share it.

The log holds states, counts, sizes, timings and short device identifiers, such as the end of the glasses' serial
number and abbreviated Bluetooth identifiers. It never holds what you said, replies, notes, keys, tokens or audio.

In ReGlass, open **Settings → Developer** and tap **Version** five times. Open **Activity log** under **Logs** to
read or filter it. **Export** opens the iPhone share sheet for the whole file. Read the log before sharing and
remove device identifiers and any other personal data. [Collecting and sharing logs](TROUBLESHOOTING.md#read-and-share-the-activity-log)

## No analytics

ReGlass has no analytics, no telemetry, no crash reporter and no ads. Its only third-party code is libopus, built from
source through swift-opus for the glasses' audio ([THIRD_PARTY.md](../THIRD_PARTY.md)). The network requests are the
ones on this page.

iOS's own diagnostics, such as iPhone Analytics, follow your iPhone's settings, not ReGlass's.

## The interpreter and other people

The interpreter sends the sound of a conversation, including the other person's voice, to ElevenLabs, and its text to
Anthropic. Tell the other person you're using a translator that sends the conversation to online services. Recording or
transcribing people can need their consent where you are. See [INTERPRETER.md](INTERPRETER.md#privacy).
