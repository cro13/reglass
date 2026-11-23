# Factory wake word download checks

The app's **Settings → Wake word → Download Factory Set** action asks Meta for the factory files that belong to the
firmware the glasses run, using the signed-in wearer's account and the saved glasses' serial number. See
[WAKE-WORD.md](../../docs/WAKE-WORD.md). It takes the seven spoken prompts from Meta's English language pack, each
checked against the pack's own `manifest.json`, and the "Hey Meta" model from Meta's current full firmware image,
checked against the known model fingerprints. It saves only the complete checked set; installing it is a separate
action. This folder contains only offline tests.

Run on macOS with Xcode command-line tools:

```sh
python3 tools/factory-wake-word/test_factory_download.py
```

The tests compile the production downloader with the real ReGlassKit files it needs (no stand-ins). They check the
two constellation queries (fixed endpoint, token only in the header, the glasses' build and `luna.language_en_us` in
the language query, `0` and full-update-only in the firmware query), parsing and refusing language offers, reading
the prompts of variant `en_US.mai_03` from a language pack and refusing changed, missing or unlisted prompts, the
Hey Meta model search, the permitted HTTPS CDN URLs and the download's input checks. They build synthetic language
packs in a temporary directory, with no Meta request or login.

To also check a Meta firmware image you already hold locally:

```sh
python3 tools/factory-wake-word/test_factory_download.py --firmware /path/to/firmware.bin
```

The image must contain a "Hey Meta" model whose fingerprint is in `WakeWordSet.heyMetaModelFingerprints`. It is only
read in place; it is never copied into the repository or uploaded. Do not commit Meta's files or signed download URLs.

A passing offline test does not establish that Meta still serves these files or accepts the current queries.
Validate that from the signed-in app on compatible glasses. A changed server response fails without saving a set.
