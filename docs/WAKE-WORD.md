# The wake word

How you start ReGlass on your glasses, download or import a factory restore set, and install a custom set.
Tested on one Ray-Ban Meta Clubmaster (Audio) pair on firmware builds 1082194281 and 1086324946.
[Compatibility](COMPATIBILITY.md)

## How it works

Your glasses come with the wake word **"Hey Meta"**. Once ReGlass owns them (see [OWNERSHIP.md](OWNERSHIP.md)):

- **Say "Hey Meta"**, then what you need. ReGlass answers instead of Meta AI.
- **Touch and hold the touchpad**, wait for the chime, then speak. ReGlass answers too.
- After each reply the glasses listen a few seconds more, so a follow-up needs no wake word.

**Settings → Wake word** shows what your glasses report on Audio firmware. It shows Hey Meta, a custom set, a change
that didn't finish, or that the glasses have no wake word files.

**Listen for "Hey Meta"** switches wake word listening on the glasses on or off. It's on by default. ReGlass writes
this setting and the assistant setting the first time it connects to a pair.

### After a factory reset

A factory reset without the Meta AI app leaves the glasses with no wake word files, and with the assistant and wake
word switches off. "Hey Meta" then does nothing. To bring it back:

1. Connect the glasses to ReGlass. It switches the assistant and "Hey Meta" back on by itself.
2. In **Settings → Wake word**, tap **Download Factory Set**, then **Restore Hey Meta**.

Tested on the Clubmaster Audio after a reset and an update to firmware 1086324946.

## ReGlass includes no wake word files

The files behind "Hey Meta" are Meta's. ReGlass doesn't include them. You can download the exact factory set
directly from Meta using your own sign-in, or import a set you already have. Your glasses already have
"Hey Meta", so most people never need to put it back.

ReGlass can install a **wake word set you already have**: Meta's factory set, to put "Hey Meta" back after a custom
one, or a custom set. Sets you import stay on your iPhone, in ReGlass's own storage. They are left out of iCloud and
computer backups, and ReGlass never uploads them. Never add wake word files to the ReGlass repository: a set holds
Meta's files, or files made from them.

## Downloading the factory set

1. Set up your glasses with ReGlass and sign in with Meta.
2. Open **Settings → Wake word**. If needed, use **Sign In with Meta** or **Sign In Again** on this screen;
   it opens the email-code flow without changing ownership. Then tap **Download Factory Set** and confirm.
3. ReGlass asks Meta's update service for the files that belong to the firmware your glasses run. It
   sends your sign-in, the glasses' serial number and their firmware version. It downloads about 13 MB: the
   English language pack for the seven spoken prompts, and Meta's current full firmware image, which contains the
   "Hey Meta" model. The firmware image is only read to take out that model; it is never flashed.
4. ReGlass checks everything against Meta's own data: each prompt against the checksum in the language pack's
   manifest, the firmware image against Meta's checksum, and the model against the fingerprint of Meta's
   "Hey Meta" model. Only the complete, verified eight-file set is saved on this iPhone, marked with the firmware
   it was made for. The full packages are discarded. You can cancel while downloading; an existing saved set stays
   in place if anything fails.
5. To change the glasses, tap **Restore Hey Meta** and confirm separately.

A set is made for one firmware version, and ReGlass installs it only on glasses running that version. **After a
firmware update, download the factory set again.** The "Hey Meta" model was the same in firmware 1082194281 and
1086324946. If a future firmware brings a model ReGlass doesn't recognise, or Meta refuses your sign-in or returns
files that don't match its own checksums, ReGlass saves nothing. You can still import your own verified factory
set. No Meta files, signed URLs or user tokens are committed to the repository.

## What a set is

A set is a folder with nine files: `manifest.json` and the eight files the glasses keep for their English wake word.

| File | What it is |
|---|---|
| `WAKE_WORD_MODEL` | The wake word model the glasses listen with. |
| `BATTERY_LOW`, `BATTERY_LOW_SHUTDOWN`, `BLUETOOTH_NOT_CONNECTED`, `DOWNLOADING_RESOURCES`, `OPEN_C50_APP`, `SETUP_ACTION_BUTTON`, `THERMAL_HIGH_SHUTDOWN` | Short spoken prompts the glasses play by themselves (low battery, no connection and so on). They are replaced together with the model, so every set carries all seven. |

## Importing a set

1. Put the set on your iPhone: a folder, or a `.zip` of the folder, in Files (on the iPhone or in iCloud Drive).
2. Open **Settings → Wake word** and tap **Import a Set**. Pick the folder or the `.zip`.
3. ReGlass checks everything before it copies anything:
   - `manifest.json` follows the format below and says which firmware the set is made for;
   - exactly the eight files are listed and present, each with the size and SHA-256 in the manifest;
   - each file has its own id, and the wake word model looks like one;
   - a factory set must be Meta's: Meta's file ids and Meta's "Hey Meta" model. A set with the proven version
     (1082207660.en_US.mai_03) must match it exactly, every size and SHA-256.

   If one check fails, ReGlass says which, and copies nothing. Importing never touches your glasses.

ReGlass keeps one factory set and one custom set. Importing another of the same kind replaces it.

## Installing

Tap **Install** on the custom set, or **Restore Hey Meta** on the factory set, and confirm. Keep the glasses close
and ReGlass open: it takes about a minute. ReGlass checks the files again, lets go of the everyday connection,
sends the set, switches it on and reads back what the glasses list. Then it reconnects as usual. The row shows the
progress, then the outcome.

- **Send Again** sends the custom set your glasses already list once more, for example after an install that didn't
  finish.
- **Remove** deletes a set from your iPhone only. Your glasses keep what they have. A custom set ReGlass has
  installed stays recognised on the glasses after you remove it, so you can still put Hey Meta back later.
- **Putting Hey Meta back:** import your factory set, then tap **Restore Hey Meta**. If an earlier restore didn't
  finish, ReGlass asks you to install a custom set first. The factory set always goes in under Meta's own version,
  and the glasses skip files whose version they already have, so a second restore could keep a half-written file.

## The set format

`manifest.json`, version 1:

| Key | Value |
|---|---|
| `schema` | `1` |
| `format` | `"reglass-wake-word-set"` |
| `role` | `"custom"` or `"factory"` |
| `name` | A custom set's name in ReGlass, at most 40 characters. Optional. |
| `firmware` | The firmware build the set is made for, e.g. `"1086324946"`. ReGlass installs it only on glasses running that build. |
| `feature` | `"luna.language_en_us"`, the glasses' English wake word. |
| `artifactId` | The id the glasses list the set under: letters, digits and punctuation, no spaces or `/`, at most 32 characters. A custom set can't use Meta's id (`967781345973994`). |
| `version` | The set's version, same characters, at most 18 for a custom set. ReGlass adds a dash and five hex digits on every install (`-3fa9c`), because the glasses skip a file whose version they already have. |
| `entries` | Exactly eight objects, one per file: `filename`, `size` (bytes, at most 2 MB), `sha256` (64 lowercase hex digits), `uuid` (the file's id, a UUID, unique within the set and different from the factory set's ids). |

A factory set uses `"role": "factory"`, Meta's own `artifactId` and `version`, and must match the factory set ReGlass
has on record exactly. Sets in the earlier `"wearwolf-wake-word-set"` format are read too. A folder of the eight
factory files without any manifest is accepted only if it is the factory set, byte for byte. Unknown keys are ignored.

Example, with placeholder values:

```json
{
  "schema": 1,
  "format": "reglass-wake-word-set",
  "role": "custom",
  "name": "My Wake Word",
  "firmware": "1082194281",
  "feature": "luna.language_en_us",
  "artifactId": "my-wake-word-01",
  "version": "mywake-0001",
  "entries": [
    { "filename": "BATTERY_LOW", "size": 10000,
      "sha256": "<64 lowercase hex digits>", "uuid": "<a UUID of your own>" },
    { "filename": "BATTERY_LOW_SHUTDOWN", "size": 10000,
      "sha256": "<64 lowercase hex digits>", "uuid": "<a UUID of your own>" },
    { "filename": "BLUETOOTH_NOT_CONNECTED", "size": 10000,
      "sha256": "<64 lowercase hex digits>", "uuid": "<a UUID of your own>" },
    { "filename": "DOWNLOADING_RESOURCES", "size": 10000,
      "sha256": "<64 lowercase hex digits>", "uuid": "<a UUID of your own>" },
    { "filename": "OPEN_C50_APP", "size": 10000,
      "sha256": "<64 lowercase hex digits>", "uuid": "<a UUID of your own>" },
    { "filename": "SETUP_ACTION_BUTTON", "size": 10000,
      "sha256": "<64 lowercase hex digits>", "uuid": "<a UUID of your own>" },
    { "filename": "THERMAL_HIGH_SHUTDOWN", "size": 10000,
      "sha256": "<64 lowercase hex digits>", "uuid": "<a UUID of your own>" },
    { "filename": "WAKE_WORD_MODEL", "size": 700000,
      "sha256": "<64 lowercase hex digits>", "uuid": "<a UUID of your own>" }
  ]
}
```

The order of `entries` doesn't matter: ReGlass always sends the seven prompts first and the model last. The wake
word model must start with the four bytes `XRSP`, as every model the glasses have taken so far does.

## Risks

- **An interrupted install can leave the wake word not working** until a set is installed again. Changing the
  glasses' files isn't all-or-nothing. If the battery dies, the connection drops or ReGlass is closed halfway,
  install the set again (or another one).
- **Whether a custom set still works after your glasses restart hasn't been tested.**
- **"Installed" means your glasses list the set**, not that it's the one listening. Say the wake word to check.
- ReGlass installs a set only on the firmware it's made for. It doesn't replace wake word files it doesn't
  recognise on the glasses, and it refuses any set that fails a check.
- A custom model you didn't make yourself may wake too often, or not at all. Keep your factory set so you can put
  Hey Meta back.

## Training your own wake word

Not in this version: phase 2. See [ROADMAP.md](ROADMAP.md).
