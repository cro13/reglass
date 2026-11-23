# Getting started

Build and sign ReGlass in Xcode, install it on your iPhone, and ask your first question through your glasses.

> [!IMPORTANT]
> ReGlass has been tested on one pair of Ray-Ban Meta Clubmaster (Audio) glasses. Setup uses Meta's signed
> hand-over to make ReGlass the owner app. To use the glasses with Meta AI again, set them up there.
> [Ownership](OWNERSHIP.md) · [Compatibility](COMPATIBILITY.md)

## What you need

- A Mac with **Xcode 27 or newer** and the iOS 27 SDK. Open Xcode once to finish its initial setup.
- An **iPhone running iOS 27 or newer** and a cable to connect it to the Mac.
- An **Apple Account with a signing team** in **Xcode → Settings → Accounts**. A free Personal Team may work for the
  default build. Signing its Time Sensitive Notifications entitlement with a Personal Team is unconfirmed.
- Charged **Ray-Ban Meta glasses** and the Meta account you used to set them up in Meta AI.
- Your own copy of **Meta AI for Android** and **Python 3.9 or newer** for the token script.
  [Get the Android app](META-CREDENTIALS.md#get-the-android-app)
- An **Anthropic API key** with API billing set up. [Anthropic Console](https://console.anthropic.com)

The default build uses Time Sensitive Notifications for reminders. If Xcode says your team lacks that capability,
you can remove the `com.apple.developer.usernotifications.time-sensitive` key and its value from
`ReGlass/ReGlass.entitlements`. Reminders then follow your Focus settings like ordinary notifications.
Optional iCloud sync needs a paid team. [iCloud sync](ICLOUD.md)

## Build and install

### 1. Clone the repository

```sh
git clone https://github.com/cro13/reglass.git
cd reglass
```

### 2. Set your team and bundle ID

```sh
cp Local.xcconfig.example Local.xcconfig
```

Open `Local.xcconfig` in a text editor and set your team ID and bundle ID.

- `DEVELOPMENT_TEAM` is your 10-character Apple team ID. If you have a paid membership, look under Membership details
  on the Apple Developer website. You can also open your **Apple Development** certificate in Keychain Access and
  look for **Organizational Unit**. If you need a certificate, choose your team in **Xcode → Settings → Accounts**
  and open **Manage Certificates**.
- `PRODUCT_BUNDLE_IDENTIFIER` is a unique bundle ID you choose, such as `com.yourname.reglass`. The widget extension
  uses that ID with `.widgets` appended.

Git ignores this file. Keep the same team and bundle ID for future builds so iOS can update your existing installation.

### 3. Run the Meta token script

From the repository root, run the script in `tools/meta-tokens/` on your own copy of the Meta AI Android app. It
writes your Meta client values and the sign-in data ReGlass needs into git-ignored files. The credential guide gives
the command and explains the account risks. [Meta credentials](META-CREDENTIALS.md)

### 4. Open the project

Open the included Xcode project from the repository root.

```sh
open ReGlass.xcodeproj
```

Xcode resolves the Swift packages, including swift-opus, on the first build.

If you edit `project.yml` or add or remove source files, install XcodeGen and run `xcodegen generate` from the
repository root. [Install XcodeGen](https://github.com/yonaskolb/XcodeGen#installing)

### 5. Run on your iPhone

1. Connect your iPhone to the Mac and unlock it. If it asks whether to trust this computer, tap **Trust**.
2. In Xcode, select the **ReGlass** scheme and your iPhone as the run destination.
3. Choose **Product → Run**.
4. If prompted, turn on Developer Mode under **Settings → Privacy & Security → Developer Mode** on the
   iPhone. Restart when prompted, confirm the setting after the restart, then run again.
5. If iOS shows **Untrusted Developer**, open **Settings → General → VPN & Device Management** on your iPhone.
   Select your developer certificate, then tap **Trust** or **Allow & Restart** if prompted. Open ReGlass again.

## Set up your glasses

Close Meta AI on the iPhone by swiping it away in the app switcher. Unfold the glasses or open their case to wake them,
and keep them close to your iPhone.

1. Open ReGlass and tap **Connect Your Glasses**. Allow Bluetooth if iOS asks. If you tapped **Not Now** earlier,
   tap **Set Up** on the **Connect your glasses** card in **Chats**.
2. Under **Choose your glasses**, tap your pair.
3. On **Sign in with Meta**, tap **Continue with Email**. Use the Meta account that owns the glasses. Follow Meta's
   prompts to choose your account and enter the code it emails you. If ReGlass stays on **You're signed in**, tap
   **Continue**.
4. On **Make ReGlass their app**, tap **Transfer to ReGlass**. If iOS shows a Bluetooth pairing request as ReGlass
   connects, tap **Pair**. ReGlass then uses Meta's signed hand-over and reconnects with its own key.
5. Wait for **You're all set**, then tap **Open ReGlass**.

## Add and test your Anthropic key

1. Tap the gear at the top right of **Chats** to open **Settings**.
2. In **Assistant → Keys**, find **Claude key** under **Anthropic** and tap **Add Key**.
3. Paste your Anthropic API key and tap **Save**. ReGlass tests it against the selected model. With the default model
   and web search available, you'll see “Works. Claude Haiku 5.5 is ready.” Tap **Test** to check it again.
4. Allow speech recognition if iOS asks. If the **Assistant** section says speech recognition is still downloading,
   keep your iPhone online while it finishes.

## Restore “Hey Meta” if it’s missing

Your glasses come with “Hey Meta.” A factory reset without Meta AI can leave the wake word files missing.

1. With your glasses connected, open **Settings → Wake word**. Turn on **Listen for “Hey Meta”**.
2. Under **Wake word sets**, tap **Download Factory Set**, then **Download**. Sign in with Meta on that screen first
   if prompted.
3. When the download finishes, tap **Restore Hey Meta**, then **Restore** to install the set. Keep your glasses
   close and ReGlass open until it finishes. [Wake word setup](WAKE-WORD.md)

## Ask your first question

Put on the glasses and say “Hey Meta, how many minutes are in two hours?” You can also touch and hold the touchpad,
wait for the chime, then ask. Open **Chats** to see the exchange. [Using ReGlass](USING.md)

## If setup gets stuck

If connecting hangs after a factory reset, go to **Settings → Bluetooth** on the iPhone. Tap the info button beside
the glasses and choose **Forget This Device**. Restart the glasses, return to ReGlass and tap **Try Again**.
[Troubleshooting](TROUBLESHOOTING.md)

## Update your build

Run `git pull` in the repo, then open the updated project and run it on your iPhone again. Run `xcodegen generate`
if you changed `project.yml` or added or removed source files. Install over your existing app with the same team
and bundle ID to keep your setup, keys, chats and library. If an install signed with a Personal Team expires, run
it again from Xcode.
