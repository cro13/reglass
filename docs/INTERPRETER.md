# Live interpreter

> **Experimental.** The interpreter works, but it has rough edges. It was tested by one wearer, with one pair of
> Ray-Ban Meta Clubmaster (Audio) glasses. Expect missed words, and tell us what happens.

The interpreter helps you understand someone who speaks another language. They talk, and you hear what they said in
English, in your glasses.

## What it does

- **One way.** It translates the other person's language into English, for you. It doesn't translate your words for
  them.
- **Your own English is ignored.** ReGlass recognises your English and leaves it out. You can talk normally.
- **Hands-free.** Once it's on, you don't need the wake word. It keeps listening until you stop it.
- **Real time.** Each sentence is translated as soon as it's said, while the person goes on talking. Real time is on
  by default.
- **About 30 languages.** French, German, Italian, Spanish, Portuguese, Romanian, Dutch and Polish, plus others such
  as Greek, Turkish, Japanese and Chinese.

Each session is saved in Chats, on your iPhone.

## What you need

- **A Claude key.** Claude does the translating.
- **An ElevenLabs key that can do speech to text, with ElevenLabs Scribe chosen as your speech recognition.**
  ElevenLabs recognises the other person's speech; Apple's recognizer isn't used for the interpreter. Choosing Scribe
  in **Settings → Assistant → Voice and speech** switches **all** your speech recognition to ElevenLabs, not only the
  interpreter's, so every voice request then goes to ElevenLabs too. Add the key in **Settings → Assistant → Keys**.
  See [VOICE.md](VOICE.md) and [PRIVACY.md](PRIVACY.md).
- **Your glasses, connected.**
- **No phone call.** The interpreter doesn't run during a call.

## Start it

It's off by default. Start it in either of these ways:

- **By voice:** "Hey Meta, interpreter, French", or "Hey Meta, start interpreting Spanish". If you don't name a
  language, ReGlass asks which one. Starting by voice needs the **Interpreter** connector switched on in
  **Settings → Assistant → Connectors** (it's marked Experimental).
- **In the app:** **Settings → Assistant → Live interpreter**. Choose the language and tap Start.

ReGlass says "Interpreting French. Go ahead." and starts listening.

## Stop it

- Say **"stop interpreting"** (or "Hey Meta, stop").
- Tap Stop on the Live interpreter screen.
- It stops by itself after **five quiet minutes**, for a call or Siri, or if the glasses stop sending sound.

## How it listens

ReGlass tries three ways to hear the other person, in this order:

1. **The glasses' multi-microphone stream.** All the glasses' microphones, not just the ones aimed at your mouth.
   This is the best way to hear someone in front of you.
2. **The iPhone's microphone,** if the glasses don't open that stream. iOS won't start the iPhone's microphone while
   ReGlass is in the background, so this works only when you start the interpreter with ReGlass open on screen.
   Keep the iPhone out, near the conversation.
3. **The glasses' assistant microphone.** ReGlass keeps one reply open, so the glasses don't stop listening. This
   microphone is focused on your mouth, so the other person sounds quiet, and ReGlass boosts them.

The activity log says which one is in use.

## What happens to the sound

- **Your own voice is reduced.** A beamformer combines the glasses' microphones to turn your voice down and keep the
  other person's. Its settings are fixed: they were calibrated once, offline, on one wearer. They may fit your head
  and your frame less well.
- **The level is evened out.** A gain stage cuts low rumble, raises quiet speech and limits loud peaks. It holds still
  while you speak, so your louder voice doesn't turn the other person down.
- **Recognition.** ElevenLabs Scribe turns the sound into text. It is locked to the language you chose.
- **Translation.** Claude translates each sentence on its own, with a short prompt of its own and no tools.
- **The voice.** The assistant's voice says the English translation in your glasses.
- **Room on the link.** Translations play at a lower audio quality, to leave room on the Bluetooth link for the
  microphones. Whether this helps is unproven.
- **The keep-alive moves.** ReGlass plays a silent sound to keep running in the background. While the multi-microphone
  stream is open, that sound plays on the iPhone's speaker instead of the glasses, because audio sent to the glasses
  starves their microphone stream. You won't hear it. See
  [GLASSES.md](GLASSES.md#why-audio-going-elsewhere-matters).
- Music stays dipped for the whole session.

## Known limits

- **Words can be missed while a translation plays.** While the assistant's voice speaks, the glasses' microphone
  stream drops to a fraction of its normal rate. Words said during a translation can be lost. Short turns work best.
- **Tested on one wearer and one pair.** The beamformer was calibrated on that wearer. Other heads, other frames and
  other models may work worse.
- **Loud places.** Nearby voices can be picked up and translated.
- **Very short replies.** One-word answers ("Oui", "Non") are the hardest to recognise.
- **Starting by voice with the iPhone locked** can't use the iPhone's microphone (see above).
- **Cost.** ElevenLabs bills speech to text for every second the interpreter listens, silence included. Claude and the
  voice are billed per sentence on top.

## Privacy

While the interpreter runs:

- **The sound of the conversation goes to ElevenLabs,** for the whole session, to be turned into text. That includes
  the other person's voice, and yours.
- **The recognised text goes to Anthropic,** to be translated by Claude.
- **The translation goes to ElevenLabs** to be spoken, if the assistant's voice is an ElevenLabs voice. Apple's voice
  speaks on the iPhone.
- **Chats keeps each session** on your iPhone.
- **The activity log** records interpreter states, counts, languages and timings. It never holds what you said.

Tell the other person that you're using a translator that sends the conversation to online services. Recording or
transcribing people can need their consent where you are. More in [PRIVACY.md](PRIVACY.md).

## Reporting a problem

Use the **Bug report** form on GitHub. Include these details.

- **What was said,** in your own words ("she asked where the station was"), and in which language.
- **Roughly when,** for example "about two minutes in" or the time of day, so the log lines can be found.
- **What happened:** nothing translated, a wrong translation, a cut-off, the session stopping.
- **How it listened:** started by voice or on the screen, with ReGlass open or in the background.
- **Your setup.** Include your glasses model and firmware (Settings → About these glasses), your iPhone model and
  iOS version, and the ReGlass commit you built.
- **The log, if you can.** Filter the activity log for `Interpreter`. Read the lines before sharing and remove
  device identifiers and any personal data. [Collecting and sharing logs](TROUBLESHOOTING.md#read-and-share-the-activity-log)

**Never post recordings of other people.** Don't attach audio of anyone who hasn't agreed to it.
