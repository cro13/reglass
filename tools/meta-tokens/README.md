# Meta client tokens helper

`extract_meta_tokens.py` reads the Meta AI Android app that you supply. It needs Python 3.9 or newer and uses only
the standard library.

The credential guide covers how to get the app and the risks. [Meta credentials](../../docs/META-CREDENTIALS.md)

## Usage

```sh
python3 tools/meta-tokens/extract_meta_tokens.py ~/Downloads/meta-ai.apkm   # a bundle: .apkm, .xapk or .apks
python3 tools/meta-tokens/extract_meta_tokens.py ~/meta-ai                  # a folder: base.apk + split_config.*.apk
python3 tools/meta-tokens/extract_meta_tokens.py base.apk --out /tmp/Secrets.xcconfig
python3 tools/meta-tokens/extract_meta_tokens.py ~/meta-ai --sign-in-table-only
```

In order, it:

1. Reads the SHA-256 certificate fingerprints Meta publishes for `com.facebook.stella` at
   `https://www.meta.ai/.well-known/assetlinks.json`. Use `--assetlinks FILE` to pass a saved copy instead.
2. Checks each APK it scans for a signer certificate Meta lists and checks the package name when it can read the
   manifest. Mirror downloads require full cryptographic verification with `apksigner` from Android SDK build-tools.
   Confirm the script reports `apksigner (full cryptographic verification)` and succeeds. Pass `--apksigner PATH` if
   the script can't find it. The built-in certificate reader can't establish that the APK is intact.
3. Scans `classes*.dex`, plus secondary DEX under `assets/`, for strings shaped like
   `HW|<app ID digits>|<32 hex digits>` (and the same for `AR|` and `FRL|`). It needs exactly one distinct value per
   prefix. It also finds the sign-in function table and checks that its function IDs and names are unique.
4. Writes both output files with mode 0600. It refuses to replace an existing output unless you pass `--force`, and
   warns if Git doesn't ignore an output file.

## Outputs

- `Secrets.xcconfig` at the repo root contains the three client tokens.
- `ReGlassKit/Sources/ReGlassKit/Resources/Generated/bloks-functions.txt` contains the function IDs and names
  ReGlass needs for sign-in.

Git ignores both default outputs. With `--out PATH`, the script writes the config at `PATH` and the table beside
it. A directory receives both files with their default names.

Use `--sign-in-table-only` to generate the table when you already have `Secrets.xcconfig`. In this mode,
`--out PATH` sets the table's output file or folder.

See `--help` for options including `--show-candidates` to list masked token candidates and `--scan-all` to include
native libraries, resources and assets.

| Exit code | Meaning |
| --- | --- |
| 0 | Output written |
| 1 | Tokens missing or ambiguous |
| 2 | Bad input |
| 3 | App check failed |
| 4 | Output not written |
| 5 (`EXIT_TABLE`) | Sign-in function table missing or invalid |

## What it never does

- Print, log or send a token value. Output shows only lengths and, with `--show-candidates`, masked forms such as
  `HW|10...47 (length 52)`.
- Download an app, upload anything, or contact Meta beyond reading the public certificate list.
- Install, run or change the app. It reads the archives in memory. The only other file it writes is a temporary copy
  of an APK taken from a bundle, so apksigner can check it. That copy is deleted right after.
- Read an existing `Secrets.xcconfig`.

## Tests

```sh
python3 tools/meta-tokens/test_extract_meta_tokens.py
```

The tests use only synthetic data: fake apps, fake tokens and throwaway certificates. They make no network requests.
If `apksigner` and `openssl` are installed, one test signs a fake APK with a throwaway key and checks that apksigner
and the built-in reader agree.
