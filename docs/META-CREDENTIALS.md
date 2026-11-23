# Meta client tokens

ReGlass's setup needs three client tokens and a sign-in function table from Meta AI for Android. This page explains
what they are, how to get them yourself, and the risks.

## What they are

Meta's services expect three client tokens from Meta AI for Android (package `com.facebook.stella`). The tokens start
with `HW|`, `AR|` and `FRL|` and identify the client. You also need your own Meta account for sign-in.

The function table maps the IDs in Meta's sign-in screens to function names so ReGlass can read the screens.

Setup uses them for two things:

- **Signing in with Meta.** You type your email, pick your account, and enter the code Meta emails you. `FRL|`
  identifies the app for this sign-in. `AR|` turns the sign-in into the token that Meta's pairing service accepts.
- **The hand-over of ownership.** Your glasses accept one owner. ReGlass asks Meta to sign the hand-over to
  ReGlass's own key. Meta's pairing service expects the `HW|` token for that request.

After setup, ReGlass reconnects to the glasses with its own key. It uses the client tokens again if you set up the
glasses again or need to renew your Meta sign-in for wake word downloads or firmware updates.

## Why ReGlass doesn't include them

They belong to Meta. ReGlass is open source, so putting them in the repository would publish Meta's app credentials
to everyone. Use the helper in `tools/meta-tokens/` to extract the values from your copy of the app for your own
build. The same helper extracts the sign-in function table from your copy of the app.

## Get the Android app

You need the files of the Meta AI **Android** app: the base APK and its split APKs, or one bundle file that holds
them. You don't need to open the app or sign in to it.

### Option A: Google Play, on an Android phone or tablet you own

1. Install Meta AI from Google Play. You don't have to open it.
2. Install `adb` on your Mac. It comes with Google's
   [SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools) and with Android Studio.
3. On the device, turn on Developer options and USB debugging. The steps differ by maker. Connect the device and
   allow your Mac when the device asks.
4. List the app's files:

   ```sh
   adb shell pm path com.facebook.stella
   ```

   Each line is one APK: `base.apk` and a few `split_config.*.apk`.
5. Copy them all into a new folder:

   ```sh
   mkdir -p "$HOME/meta-ai"
   for apk in $(adb shell pm path com.facebook.stella | sed 's/^package://' | tr -d '\r'); do
     adb pull "$apk" "$HOME/meta-ai/"
   done
   ```

You'll give this folder to the script.

### Option B: a mirror such as APKMirror

Download the Meta AI bundle (`.apkm`, `.xapk` or `.apks`). Any architecture or screen variant should work. Before
using the generated files, verify the bundle with `apksigner` through the script. This is required for mirror
downloads because ReGlass uses the generated sign-in table to read Meta's sign-in screens.

### Verify with apksigner

`apksigner` comes with the Android SDK build-tools, which Android Studio installs. The script looks for it on your
PATH, in `$ANDROID_HOME` and `$ANDROID_SDK_ROOT`, and in `~/Library/Android/sdk` and `~/Android/Sdk`. You can also
pass `--apksigner PATH` to point to the executable. It needs Java.

The script runs `apksigner verify --print-certs` on each APK it scans, then compares the verified signer certificate
fingerprints with Meta's published list. For a mirror download, confirm the script reports `apksigner (full
cryptographic verification)` and succeeds. The built-in fallback only reads the embedded certificate, so an APK that
was changed and still carries Meta's certificate can pass that check.

## Run the script

You need Python 3.9 or newer. Apple's Command Line Tools include `python3`, and Xcode installs those tools. To check,
type `python3 --version` in Terminal. If macOS offers to install the tools, accept.

From the ReGlass folder, use the command for your download. For a mirror bundle, replace `/path/to/apksigner`
with the path to the executable in your Android SDK build-tools.

```sh
python3 tools/meta-tokens/extract_meta_tokens.py ~/Downloads/meta-ai.apkm --apksigner /path/to/apksigner
python3 tools/meta-tokens/extract_meta_tokens.py ~/meta-ai                  # the folder from adb
```

The script:

1. Reads Meta's public list of signing certificates from `https://www.meta.ai/.well-known/assetlinks.json`. This is
   its only network request. To work offline, download that file beforehand and pass `--assetlinks assetlinks.json`.
2. Checks each APK it scans for a signer certificate Meta lists for `com.facebook.stella`. It checks the package
   name when it can read the manifest and verifies the APK's signature when `apksigner` is available.
3. Reads the three client tokens from your copy of the app. It needs exactly one value of each.
4. Finds the sign-in function table in the app's code and checks that the IDs and names are unique.
5. Writes `Secrets.xcconfig` and `bloks-functions.txt`.

When it succeeds, it prints the signature check result, the token lengths, the function count and the output paths.
`--out PATH` writes the config at the given path and the table beside it. If `PATH` is a folder, both files go there.
`--force` replaces existing output files. `--show-candidates` lists the token candidates in masked form.
`--help` lists the other options.

If you already have `Secrets.xcconfig`, add `--sign-in-table-only` to generate just the table. In that mode,
`--out PATH` sets the table's output file or folder.

## What it writes

It writes `Secrets.xcconfig` in the root of the ReGlass folder:

```
REGLASS_META_HW_TOKEN = HW|...
REGLASS_META_AR_TOKEN = AR|...
REGLASS_META_FRL_TOKEN = FRL|...
```

The script writes the sign-in table to
`ReGlassKit/Sources/ReGlassKit/Resources/Generated/bloks-functions.txt`. Each line contains an ID and a function name.
Both default outputs are git-ignored and written with mode 0600. Keep them local.

## How the build uses it

`Config.xcconfig` includes the file with `#include? "Secrets.xcconfig"`. The `?` means a missing file isn't a build
error. The build copies the three values into the app's Info.plist, and the app reads them from there during setup.

Swift Package Manager bundles the sign-in table as a ReGlassKit resource when the file is present. The app loads
the table from that bundle. After you generate or replace either file, build and install the app again.

## Check that it worked

Start setup on your iPhone. The sign-in step shows a notice and disables Continue with Email if the build is
missing the sign-in table or the client credentials. If you see the notice, run the helper and make sure both files
are in their default locations. If `Secrets.xcconfig` already exists and the table is missing, use
`--sign-in-table-only`. Build again, and clean the build folder if the notice is still there.

The script can't tell whether Meta still accepts the values. You find out when you sign in.

## When it fails

- **"not signed with a certificate Meta publishes"** or **"signature is NOT valid"**: don't use that file. Get the app
  from Google Play or from another source.
- **"none found"**: you probably passed only a split APK. Pass the whole bundle, or the folder, so the base APK is
  included. If the script still finds nothing, Meta may have changed the app. Try `--scan-all`, or another version.
- **"different values"**: the script won't guess. Run it again with `--show-candidates` to inspect the masked
  results locally. If you open an issue, share the error message with the values removed.
- **Missing or invalid sign-in function table.** Pass the base APK or the whole bundle. If the base APK is
  already included, try a different Meta AI version.
- **"Couldn't read Meta's certificate list"**: check your connection. Or download the file with
  `curl -fsSO https://www.meta.ai/.well-known/assetlinks.json` and pass `--assetlinks assetlinks.json`.

## Risks

Read this before you start.

- Meta's terms don't permit third-party apps to use these values. Using them may breach those terms, and Meta could
  restrict your account.
- **Meta can change or revoke the values at any time.** If that happens, sign-in or the hand-over stops working. You
  would need the values from a newer version of Meta AI: get the new app and run the script again with `--force`.
- **You use this at your own risk.** There is no warranty.
- **ReGlass isn't affiliated with Meta.** Meta doesn't make, endorse or support it.
- **Keep both files local.** Never commit or share `Secrets.xcconfig` or the generated sign-in table. Never post
  the tokens in issues, chats, screenshots or logs. A built `.app`, `.ipa` or Xcode archive contains your Meta
  client values and the generated sign-in data, so keep those builds private too. To get help, describe the error
  with the values removed.
