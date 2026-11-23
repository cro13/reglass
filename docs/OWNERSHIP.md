# What setup does to your glasses

Ray-Ban Meta glasses accept **one owner app** at a time. Normally that's Meta AI. ReGlass's setup makes ReGlass the
owner instead. This page explains what that means for you. It doesn't explain how the hand-over works.

Tested only with the Ray-Ban Meta Clubmaster (Audio). See [COMPATIBILITY.md](COMPATIBILITY.md).

## Before you start

- **Close the Meta AI app.** Swipe it away in the iPhone's app switcher. The glasses talk to one app at a time, so an
  open Meta AI can keep ReGlass from reaching them.
- **Use the Meta account that owns the glasses.** You sign in with Meta during setup. Meta checks that you own the
  glasses before ReGlass takes over.
- **Read the risks.** Setup uses client values from your copy of Meta AI for Android. Meta's terms don't permit
  third-party apps to use these values. Using them may breach those terms, and Meta could restrict your account.
  [Meta client tokens and risks](META-CREDENTIALS.md#risks)

Signing in changes nothing on the glasses. Nothing changes until you tap **Transfer to ReGlass**.

## What changes

- **ReGlass becomes the glasses' one owner.** It makes a key of its own. Meta signs the hand-over, and the glasses
  check Meta's signature before accepting the new key.
- **Meta AI can no longer connect** while ReGlass owns the glasses. "Hey Meta" now starts ReGlass.
- **Your glasses stay linked to your Meta account.**
- **Reconnecting uses ReGlass's own key.** After setup, everyday reconnection happens directly over Bluetooth.

## What doesn't change

- The firmware, unless you install an update Meta offers (see [FIRMWARE.md](FIRMWARE.md)).
- The wake word. "Hey Meta" stays, unless you install a custom one yourself (see [WAKE-WORD.md](WAKE-WORD.md)).
- Your Meta account.

## ReGlass's key

- **It stays on your iPhone.** It is stored encrypted, and the encryption key lives in the iPhone's Keychain, for this
  device only. It is never synced to iCloud, and it can't be restored onto another iPhone.
- **The app never deletes it.** Not when you forget the glasses, and not when you sign out of Meta. A later setup on
  the same iPhone reuses it.
- **Deleting ReGlass deletes it.** iOS removes an app's files with the app. If you delete ReGlass while it owns your
  glasses, set them up again afterwards, in ReGlass or in Meta AI.
- **A new iPhone needs a new setup.** The key doesn't move with your backups.
- After the iPhone restarts, the key stays locked until you unlock the iPhone once. Until then ReGlass can't connect.

## Forget these glasses

**Settings → Forget These Glasses**:

- ReGlass stops connecting to the glasses and removes its record of them.
- Its key stays sealed on this iPhone, so a later setup can reuse it.
- **Nothing changes on the glasses.** ReGlass is still their owner, so Meta AI still can't connect. To switch back, see
  the next section.

**Settings → Sign Out of Meta** forgets only ReGlass's saved Meta sign-in. It doesn't change your glasses or
ReGlass's key.

## Going back to Meta AI

1. In ReGlass, forget the glasses (or turn off **Stay connected**), so ReGlass lets go of them.
2. Open the Meta AI app and set the glasses up again there, as you would with new glasses.

Meta AI is then the owner again, and ReGlass can't connect. ReGlass shows "Owner app: Not ReGlass any more" in
Settings.

To come back to ReGlass later, close Meta AI and use **Settings → Reconnect or Set Up Again** in ReGlass.

## If the glasses turn ReGlass down

If someone sets the glasses up with another app, the glasses no longer accept ReGlass's key. ReGlass then shows that
it isn't the owner any more, and offers to set them up again.
