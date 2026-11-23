# Firmware updates

How ReGlass finds and installs firmware updates for your glasses, what you see while it runs, and what to do if it
stops.

> **Tested only with the Ray-Ban Meta Clubmaster (Audio), the model without a camera.** That model has no Wi-Fi, so
> its updates travel over Bluetooth, and that is the only path ReGlass handles. Other Meta glasses may get their
> updates over Wi-Fi or another connection ReGlass doesn't support yet. ReGlass only offers updates to glasses that
> report an Audio firmware build; update any other glasses in the Meta AI app. See
> [COMPATIBILITY.md](COMPATIBILITY.md).

## What the update is

ReGlass downloads Meta's signed firmware with your Meta sign-in and sends the update to your glasses unchanged.
The glasses check Meta's signature themselves before they install it.

ReGlass never makes, changes or installs any other firmware.

## Finding an update

ReGlass checks Meta's update service when your glasses connect, every few hours while ReGlass runs, and when you
open it. It checks at most once every six hours and only while you're signed in with Meta.

When there is an update:

- a notification tells you, once for each new version;
- a banner under your glasses at the top of **Chats** shows the version and how long it takes. **Later** puts it away
  until Meta offers a newer version;
- **Settings → Firmware** shows it too, with the version your glasses run now.

To check yourself, open **Settings → Firmware**.

## Before you start

- **Battery at 60 % or more.** ReGlass checks this before it starts sending and again just before your glasses
  install the update.
- **Off the charger.** Your glasses don't update while they charge.
- **Glasses close to your iPhone**, and about 20 minutes. You don't need to wear them.

## Installing

1. Open **Settings → Firmware**, or tap **View** on the banner in Chats.
2. Tap **Update Glasses**, read the confirmation, and tap **Install**.
3. Leave ReGlass open. It keeps the screen on by itself, so you don't need to touch anything. You can put the phone
   down.

The update runs full screen, in four steps:

| Step | What happens |
|---|---|
| Get the update from Meta | ReGlass downloads it (about 11 MB) and checks it against Meta's checksum. |
| Send it to your glasses | The update goes to your glasses piece by piece. This is the long part. The screen shows how much has arrived and about how long is left. |
| Your glasses install it and restart | Your glasses have the whole update. They install it and restart on their own, in about 10 seconds: the update was already saved while it was being sent. |
| Check the new version | ReGlass reconnects and reads the version your glasses now run. |

**What your glasses show:** while the update is being sent, the light on your glasses blinks white and orange. That's
normal. It means they are receiving the update.

## Why it takes about 20 minutes

These glasses have no Wi-Fi, so the update travels over Bluetooth. Bluetooth isn't what's slow. Your glasses save each
piece to their storage as it arrives, and that takes time. If the pieces come too fast, the glasses fall behind and
drop the connection. ReGlass sends 1 KB at a time and pauses briefly to give the glasses time to save each piece.
That's about 10 KB a second. The whole transfer took 19 minutes on the tested pair.

## If you leave ReGlass

iOS pauses apps that aren't on screen, and a paused app can't keep sending. If you switch away or lock your iPhone
before your glasses start installing, a notification asks you to come back (if ReGlass may send notifications).
You have 20 seconds. If you don't come
back in time, the update stops and nothing is installed. Start it again later.

Once your glasses are installing the update, leaving ReGlass doesn't matter: they finish on their own.

## Stopping

**Stop Update** is there until your glasses start installing. It asks first. Your glasses keep the version they have,
and you can start again later. Once they're installing, nothing can stop it. Don't turn your glasses off while they
restart.

## When it ends

| What you see | What it means |
|---|---|
| **Your glasses are up to date** | Your glasses restarted on the new version. |
| **Update stopped** | You stopped it, or ReGlass was off screen too long. Nothing was installed. |
| **The update didn't finish** | Something stopped it, for example a low battery, a dropped connection or your glasses saying no. The message says what. Before the install, nothing changes on your glasses. |
| **Your glasses are finishing the update** | Your glasses have the whole update and are installing it, but ReGlass couldn't confirm the result. Wait for them to restart, then check **Settings → Firmware**. |

## Things to know

- **It can't be undone.** Meta only offers its newest version, so there is no way back to the one before.
- **Wake word sets.** Each set is made for one firmware version. After updating, download the factory set again
  before restoring "Hey Meta", or install a custom set made for the new firmware version. See [WAKE-WORD.md](WAKE-WORD.md).
- **What goes to Meta:** your Meta sign-in, your glasses' serial number and their device type, each time ReGlass
  asks for an update, and your sign-in again to download it. ReGlass always asks for the full update, not a partial
  one. See [PRIVACY.md](PRIVACY.md).
- **Ownership doesn't change.** ReGlass stays your glasses' owner. See [OWNERSHIP.md](OWNERSHIP.md).
