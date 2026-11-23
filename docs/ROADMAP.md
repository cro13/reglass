# Roadmap

What's in ReGlass now, what comes next, and ideas for later. Nothing here is a promise. ReGlass is tested only with
the Ray-Ban Meta Clubmaster (Audio); see [COMPATIBILITY.md](COMPATIBILITY.md).

## v1: what's in

**The glasses** (details and status in [GLASSES.md](GLASSES.md))

- Setup: find the glasses, sign in with Meta, make ReGlass the owner. See [OWNERSHIP.md](OWNERSHIP.md).
- Stays connected in the background and reconnects by itself, with its own key.
- Status: glasses and case battery, worn, charging, firmware.
- "Hey Meta" and touch and hold start ReGlass. Follow-ups without the wake word.
- Timers that ring on the glasses.
- Downloading the verified factory set directly from Meta, or importing a set you already have, to restore
  "Hey Meta" or install a custom set. See
  [WAKE-WORD.md](WAKE-WORD.md).

**The assistant**

- Claude for the answers, with web search: Haiku 5.5 by default, or Sonnet 5.5, Opus 5.5 or Fable 5.2.
- Apple's on-device voice and speech recognition by default; ElevenLabs as an option. See [VOICE.md](VOICE.md).
- Replies stream into the glasses as they're made. Saying "Hey Meta" over a reply stops it.
- Talk to ReGlass: type a request and hear the answer.

**Your things**

- Chats · Notes · Reminders, with categories, search and Recently Deleted.
- Connectors: timers, reminders, notes, lists, Calendar, Alarms, Apple Music, Weather. See
  [CONNECTORS.md](CONNECTORS.md).
- Everything stays on the iPhone, unless you build with iCloud. See [ICLOUD.md](ICLOUD.md) and
  [PRIVACY.md](PRIVACY.md).

**Experimental**

- The live interpreter: the other person's language into English. See [INTERPRETER.md](INTERPRETER.md).

## Next: more AI providers

- **OpenAI**, beside Anthropic's Claude, for the answers.
- **Other providers** after it.

## Phase 2: train your own wake word

Today a custom wake word needs files you build yourself. Phase 2 makes that something anyone can do, without putting
any Meta files in this repository.

- **A trainer that reads your own files.** Training will use a base model you supply yourself or obtain through the
  verified factory download. The trainer itself is still planned. The repository ships no Meta files, and the
  trainer never uploads them.
- **Public speech data, fetched by script.** A script downloads openly licensed speech recordings to train against.
  They aren't stored in the repository.
- **A guided recording of your voice.** Step by step, you record your wake word, and a few other phrases, in more
  than one place and tone.
- **A set the app can import.** The trainer packages the result into a wake word set that ReGlass checks and
  installs, as it does today.

Open questions: how well a model trained on one voice wakes for that voice in noise, how often it wakes by mistake,
and whether it survives the glasses restarting.

## Later ideas

- **More models.** Reports from other Meta glasses, and fixes for what differs. See
  [COMPATIBILITY.md](COMPATIBILITY.md).
- **Tap to stop, confirmed.** Find out when the glasses report a tap to the iPhone.
- **Spoken walking directions.** Turn-by-turn, said on the glasses, from the iPhone's location.
- **An interpreter both ways.** Your English spoken aloud in the other language, for the other person.
- **Apple Reminders.** Link a ReGlass list to an Apple Reminders list.
- **Apple Weather** as a second forecast source.
- More ideas, built on what the glasses already do: [GLASSES.md](GLASSES.md#building-on-these).
