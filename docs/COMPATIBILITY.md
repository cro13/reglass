# Compatibility

ReGlass talks to the glasses directly, without Meta's app or SDK. Small differences between models or firmware can
break it. This page says what was tested, and how to report what you find.

## Tested

| | Tested with |
|---|---|
| Glasses | **Ray-Ban Meta Clubmaster (Audio)**, the model without a camera. One pair. |
| Glasses firmware | Two builds: **1082194281**, and **1086324946**, which ReGlass installed itself. You'll find the version in **Settings → Firmware**. |
| iPhone | An iPhone on **iOS 27**. ReGlass needs iOS 27 or newer. |
| Build | **Xcode 27** with the iOS 27 SDK. |

What works on this setup, and what doesn't, is in [GLASSES.md](GLASSES.md).

## Not tested

- **Every other Meta glasses model.** That includes Ray-Ban Meta models with a camera, Oakley Meta models and Meta
  glasses with a display. They may not be found during setup, may refuse the hand-over, or may speak to the iPhone
  differently.
- **Other firmware.** ReGlass installs Meta's own updates on the Clubmaster (Audio); see [FIRMWARE.md](FIRMWARE.md).
  A build other than the two above can change how the glasses behave, also on the tested model.
- **Firmware updates on other models.** Tested only on the Clubmaster (Audio), which updates over Bluetooth. Other
  Meta glasses may update over Wi-Fi or another connection ReGlass doesn't handle yet. ReGlass only offers updates to
  glasses that report an Audio firmware build.
- **The wake word on other firmware.** ReGlass downloads the factory set for the firmware your glasses run and
  installs a set only on the firmware it was made for. It was tested on the two builds above. See
  [WAKE-WORD.md](WAKE-WORD.md).
- **Other iPhones.** Only one iPhone was tested. Older iOS versions can't install ReGlass.

If you try another model, read [OWNERSHIP.md](OWNERSHIP.md) first. Setup makes ReGlass the owner, and to go back you
set the glasses up again in Meta AI.

## Report your results

Use the **Compatibility report** issue form on GitHub. Give the glasses' retail model name, model code from
**Settings → Developer** and firmware from **Settings → About these glasses**. Include the iPhone model, iOS
version and the ReGlass version or commit.

Use the form's table to mark which areas worked, failed or weren't tried. Add a note if something only worked
part of the time. [What the glasses can do](GLASSES.md)

If something failed, include the relevant lines from the activity log. Read them before sharing and remove device
identifiers, serial numbers, credentials and personal data. [Collecting and sharing logs](TROUBLESHOOTING.md#read-and-share-the-activity-log)
