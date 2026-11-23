# What the glasses can do with ReGlass

> **Tested on one Ray-Ban Meta Clubmaster (Audio, no camera) pair**, on firmware builds 1082194281 and 1086324946.
> Other models and builds may behave differently. [Compatibility](COMPATIBILITY.md)

This page lists what ReGlass can do with the glasses, area by area. Each row has a status:

| Status | Meaning |
|---|---|
| **Proven** | Works on the tested hardware. |
| **Built, unproven** | ReGlass has the code, but it hasn't been confirmed on the glasses yet. |
| **Not available** | ReGlass can't do it. The row says why. |

For setup, start with the [README](../README.md) and [GETTING-STARTED.md](GETTING-STARTED.md). For what setup changes
on your glasses, read [OWNERSHIP.md](OWNERSHIP.md).

## Connection

| Capability | What you can do with it in ReGlass | Status |
|---|---|---|
| Finding the glasses | Setup lists the glasses near your iPhone, including a pair iOS already has connected, with a signal strength. iOS pairs them if it needs to. | Proven |
| Becoming the owner | Setup makes ReGlass the glasses' owner, in place of the Meta AI app. See [OWNERSHIP.md](OWNERSHIP.md). | Proven |
| Staying connected | ReGlass keeps a Bluetooth link to the glasses while it runs in the background, also with the iPhone locked. **Settings → Stay connected** turns this off. | Proven |
| Reconnecting by itself | When the glasses come back in range, wake up, or Bluetooth comes back on, ReGlass reconnects with its own key. It doesn't need Meta for that. | Proven |
| Coming back after iOS ends ReGlass | iOS can end a background app to free memory. When the glasses next need ReGlass, iOS should start it again in the background. iOS never restarts an app you swiped away. | Built, unproven |
| One app at a time | The glasses talk to one app at a time. While ReGlass owns them, Meta AI can't connect. | Proven |

After the iPhone restarts, ReGlass's key stays locked until you unlock the iPhone once. Until then ReGlass can't
connect, and it says so.

## Status

| Capability | What you can do with it in ReGlass | Status |
|---|---|---|
| Glasses battery | The level, on Home and in Settings. While the glasses are out of reach, ReGlass shows the last reading and says how old it is. | Proven |
| Case battery | The case has no radio of its own. It reports its level only through the glasses sitting in it. So the reading is live only while the glasses are in the case. Out of the case, ReGlass shows the last reading and when it was seen. | Proven |
| Worn | On your face, not worn, or in the case. ReGlass uses this to decide where to say a reminder: on the glasses when you wear them, otherwise on the iPhone. | Proven |
| Charging | Whether the glasses are charging. | Proven |
| "Not charging" warning | If the glasses sit in the case below 80 % for a minute without charging, ReGlass warns you to check how they rest in it. | Built, unproven |
| Firmware | The firmware build, in **Settings → About these glasses**. | Proven |
| Serial number and model code | In **Settings → Developer**. Setup and every reconnect check that the serial matches. | Proven |

## Wake word

| Capability | What you can do with it in ReGlass | Status |
|---|---|---|
| "Hey Meta" | Say "Hey Meta" and then your request. ReGlass answers instead of Meta AI. | Proven |
| Touch and hold | Touch and hold the touchpad, wait for the chime, then speak. ReGlass answers. | Proven |
| Follow-up without the wake word | After each reply a soft chime plays, and the glasses listen a few seconds more. Just ask the next thing. | Proven |
| "Hey Meta" over a reply | Saying the wake word while the assistant's voice is speaking stops it, and ReGlass listens. | Proven |
| Which wake word is installed | On Audio firmware, **Settings → Wake word** shows what the glasses report, such as Hey Meta, a custom set, an install that didn't finish, or no wake word files. | Proven |
| A custom wake word | Import a set made for the Audio firmware your glasses run in **Settings → Wake word**, then install it. ReGlass checks each file against the set's manifest. See [WAKE-WORD.md](WAKE-WORD.md). | Built, unproven |
| Putting "Hey Meta" back | Tap **Download Factory Set** using your Meta sign-in, or import a factory set made for the firmware your glasses run, then tap **Restore Hey Meta**. ReGlass checks each file against the set's manifest. Factory download and restore were tested after a reset and an update to firmware 1086324946. See [WAKE-WORD.md](WAKE-WORD.md#after-a-factory-reset). | Proven |
| A custom wake word after the glasses restart | Whether a custom wake word still works after the glasses restart hasn't been tested. | Built, unproven |
| Training your own wake word | Not in this version. It is Phase 2 in [ROADMAP.md](ROADMAP.md). | Not available |

## Touch controls

| Capability | What you can do with it in ReGlass | Status |
|---|---|---|
| Touch and hold | Starts ReGlass (see above). | Proven |
| Tap | Plays or pauses music. This is the glasses' own behaviour; ReGlass leaves it alone. | Proven |
| Swipe forward or back | Volume up or down. The glasses' own behaviour. | Proven |
| Double tap | Skips to the next track. The glasses' own behaviour. | Proven |
| Tap to stop the assistant | One tap while the assistant's voice is speaking, or while ReGlass is saying an announcement, stops it. This works only if the glasses tell the iPhone about the tap, and they are known to do that only in some situations. If music is playing, the same tap may also pause it. If a tap doesn't work, say "Hey Meta, stop". | Built, unproven |
| Tap to stop a ringing timer | The glasses stop their own timer chime on a tap, without ReGlass. Expected from how the glasses work; not yet checked with ReGlass. | Built, unproven |
| New meanings for gestures | ReGlass can't give double tap, swipes or other gestures a new job. The glasses keep them for their built-in functions. | Not available |

## Microphones

| Capability | What you can do with it in ReGlass | Status |
|---|---|---|
| The assistant microphone | After the wake word, the glasses send your voice from a microphone mix focused on your mouth. ReGlass turns it into text on the iPhone: Apple's on-device speech recognition by default, ElevenLabs if you choose it. See [VOICE.md](VOICE.md). | Proven |
| Ignoring other voices in follow-ups | In the follow-up window, speech much quieter than yours (a TV, people nearby) is ignored. | Proven |
| The multi-microphone stream | The glasses can also send the raw sound of all their microphones. The live interpreter uses it to hear the person in front of you. While a translation plays, the stream loses much of its sound. See [INTERPRETER.md](INTERPRETER.md). | Proven |

ReGlass opens the microphones only for the assistant and the interpreter. It doesn't record in the background.

## Speech output

| Capability | What you can do with it in ReGlass | Status |
|---|---|---|
| Replies | The assistant's voice plays in the glasses' speakers. It starts while the rest of the reply is still being made. | Proven |
| Announcements without a wake word | ReGlass can speak on its own: a timer that ended, a reminder that's due. If you aren't wearing the glasses, or they aren't connected, the iPhone speaks or alerts instead. | Proven |
| The listening chime | A soft two-note chime at the end of a reply means the glasses are listening for a follow-up. | Proven |
| Music dips under the voice | Music from the iPhone gets quieter while the assistant's voice speaks, then comes back up. | Proven |
| Replies through another speaker | When the iPhone's sound goes to a car or another Bluetooth speaker, the reply plays there instead of in the glasses, with the music dipped. See "Why audio going elsewhere matters" below. | Built, unproven |

## Timers on the glasses

| Capability | What you can do with it in ReGlass | Status |
|---|---|---|
| Timers that ring on the glasses | "Set a timer for ten minutes to check the oven." The glasses keep the timer and chime by themselves, even if the iPhone is out of reach. Then the assistant's voice says what it was for. | Proven |
| Ask about and cancel timers | "How long's left on the pasta?", "Cancel the laundry timer." | Proven |
| A backup when the glasses don't ring | If the glasses restarted, were folded or out of range, ReGlass says the timer anyway, on the glasses or on the iPhone. | Built, unproven |
| Alarms, reminders and events on the glasses | ReGlass sends only running timers to the glasses. Alarms ring on the iPhone, and ReGlass says reminders itself. Sending anything else to the glasses' own clock isn't proven, and could wipe the timers. | Not available |

The glasses hold up to eight running timers and forget them when they restart. ReGlass keeps the full list on the
iPhone and sends it again whenever the glasses reconnect.

## Music and Bluetooth audio

| Capability | What you can do with it in ReGlass | Status |
|---|---|---|
| Headphones for the iPhone | The glasses stay normal Bluetooth headphones for music and other iPhone sound. | Proven |
| The touchpad controls your music app | Tap, double tap and swipes keep controlling Music or any other music app, because ReGlass never takes over the iPhone's "Now Playing" controls. | Proven |
| Apple Music by voice | "Play some jazz", "skip", "what's playing?" See [CONNECTORS.md](CONNECTORS.md#apple-music). | Proven |
| Adaptive Volume and Spatial Audio | Switch the glasses' own Adaptive Volume and Spatial Audio on or off in **Settings → Sound**, or by voice. The glasses accept the setting, but ReGlass can't read it back, and the effect hasn't been confirmed by ear. | Built, unproven |

### Why audio going elsewhere matters

The glasses use one Bluetooth radio for two things: ordinary audio (music) and the link the assistant runs on. A
steady audio stream to the glasses can take most of the radio's time and starve the assistant's link. This includes
the silent sound ReGlass plays to keep running in the background. When that happens, replies cut off after a few
seconds and the microphone stream loses sound.

The same thing happens when the iPhone streams audio to another device, such as a car. That device then sets the
radio's timing, and the glasses get too little of it.

So ReGlass:

- plays replies through the iPhone's sound output when the iPhone's audio goes to a car or another Bluetooth speaker;
- plays its silent keep-alive sound on the iPhone's own speaker while the interpreter's multi-microphone stream is
  open. With the keep-alive on the glasses, that stream lost about three quarters of its sound; on the iPhone's
  speaker, it lost none;
- plays interpreter translations at a lower quality, to leave room on the link. Whether this helps is unproven.

## Software

| Capability | What you can do with it in ReGlass | Status |
|---|---|---|
| Firmware updates | ReGlass checks Meta for updates and offers them in a notification and in Chats. **Settings → Firmware** sends Meta's signed update to the glasses over Bluetooth and shows full-screen progress. Updating the tested pair from 1082194281 to 1086324946 took about 19 minutes to send and 10 seconds to install and restart. This path was tested on the Clubmaster (Audio). [Firmware updates](FIRMWARE.md) | Proven |

## Not available

| Capability | Why | Status |
|---|---|---|
| Camera, photos and video | This model has no camera. | Not available |
| Display | This model has no display. | Not available |
| Head gestures (nod, shake) and motion data | The glasses have motion sensors, but no way for an iPhone app to receive their data was found on this firmware. | Not available |
| Reading iPhone notifications on the glasses | The glasses don't read iPhone notifications by themselves on this firmware, and ReGlass doesn't read other apps' notifications. | Not available |
| Other apps' messages (WhatsApp, Messenger, texts) | Under Meta AI, these came through Meta's own services. With ReGlass as the owner, nothing sends them. ReGlass never reads or sends messages through the glasses. | Not available |

## Building on these

Ideas that combine what already works. Open an issue before you start a big one; see
[CONTRIBUTING.md](../CONTRIBUTING.md) and [CONNECTORS.md](CONNECTORS.md).

- **Spoken walking directions.** Announcements without a wake word, plus the iPhone's location and Apple Maps
  directions: "Turn left in 50 metres", said at the right moment, with the iPhone in your pocket.
- **A briefing when you put the glasses on.** The worn status, plus Calendar and Weather: the first thing of the day,
  said once.
- **Battery nudges.** The glasses' battery and the "not charging" check: a spoken warning before the glasses run
  out, or when they don't charge in the case.
- **Step by step.** Follow-ups without the wake word: a recipe or a checklist one step at a time, with "next" and
  "repeat".
- **Where are my glasses?** The last time the link was up, plus the iPhone's location at that moment.
- **Tap to stop, confirmed.** Find out when the glasses report taps to the iPhone, on your model, and report it.
- **Other models.** Try ReGlass on other Meta glasses and fill in a report. See [COMPATIBILITY.md](COMPATIBILITY.md).
