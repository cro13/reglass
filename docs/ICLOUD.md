# iCloud sync

iCloud sync is off by default: ReGlass keeps notes, reminders and lists on the iPhone. If you build ReGlass
yourself, you can turn on sync through your own private iCloud database. It's a build setting, not a switch in the
app.

## What syncs

**Syncs:** notes, reminders and list items, which make up ReGlass's library. Items in Recently Deleted sync too, so
something you put back on one device comes back on the other.

**Never syncs:**

- Chats. They have their own store, which never syncs, whatever the build.
- Keys. They stay in the iPhone's Keychain, on that iPhone only.
- Settings, such as the voice and the connectors. They stay on each iPhone.
- The activity log.

The library goes to the private database of your Apple Account, in the container `iCloud.<your bundle ID>`. Only your
account can read it. Apple encrypts iCloud data, but ReGlass doesn't use CloudKit's end-to-end encrypted fields.

## What you need

- **A paid Apple Developer Program membership.** A free account (a Personal Team in Xcode) can't use iCloud: Xcode
  can't sign a build that asks for it.
- **Your own team and bundle ID** in `Local.xcconfig`. The container is named after the bundle ID.
- **An iCloud account on the iPhone.** Without one, ReGlass works as before, on the iPhone only.

## Turn it on

1. Copy `Local.xcconfig.example` to `Local.xcconfig`, if you haven't. Set `DEVELOPMENT_TEAM` and a
   `PRODUCT_BUNDLE_IDENTIFIER` of your own. `Local.xcconfig` is git-ignored.
2. Add this line to it:

   ```
   REGLASS_ICLOUD = YES
   ```

3. Open `ReGlass.xcodeproj` and build to your iPhone. You don't need to run XcodeGen: the switch is in the xcconfig.

With automatic signing, Xcode adds iCloud (CloudKit) and Push Notifications to your App ID and registers the
container. If it can't, do it on the Apple Developer website, under Certificates, Identifiers & Profiles:

1. Under Identifiers, add an iCloud Container called `iCloud.<your bundle ID>`.
2. Edit your App ID: turn on iCloud with CloudKit, and choose that container. Turn on Push Notifications.
3. Build again.

### What the switch does

`REGLASS_ICLOUD = YES` changes three things, all in `Config.xcconfig`:

- **Entitlements:** the app is signed with `ReGlass/ReGlass-iCloud.entitlements` instead of
  `ReGlass/ReGlass.entitlements`. It adds the CloudKit container and `aps-environment`, for CloudKit's silent
  pushes.
- **Code:** Swift compiles with the `REGLASS_ICLOUD` condition. The library's store then uses your private CloudKit
  database (`LibraryStore.cloudKitDatabase`), and the app registers for remote notifications at launch.
- **Background mode:** `Info.plist` always lists `remote-notification`; only a build with iCloud registers for the
  pushes, so a change from another device can wake ReGlass.

The widget extension gets none of this.

### Check that it works

ReGlass's activity log says "Library: syncs with iCloud" at launch, and "iCloud: registered for change
notifications" soon after. Write a note on one device. It shows up on the other within a minute or so while ReGlass
is open there.

### Turn it off

Remove the line from `Local.xcconfig`, or set it to `NO`, and build again. The iPhone keeps everything it has, on
the iPhone only. What's in iCloud stays there.

## Development and production

Every CloudKit container has two environments, **Development** and **Production**. They have separate data and
separate schemas.

Which one a build uses depends on how it's signed, not on Debug or Release:

- **Development:** anything Xcode installs on your iPhone, Debug or Release.
- **Production:** builds signed for distribution, such as TestFlight and the App Store.

The entitlements say `aps-environment = development`. When Xcode exports a build for distribution, it signs it with
`production` instead.

Data doesn't move between the two. Notes from a build Xcode installed don't appear in a TestFlight build, and the
other way round.

### Before your first TestFlight build

In Development, CloudKit creates the record types as ReGlass saves its first note, reminder and list item.
Production never changes its schema by itself:

1. With a build from Xcode, save at least one note, one reminder and one list item, so every record type exists in
   Development.
2. Open the [CloudKit Console](https://icloud.developer.apple.com), choose your container, and deploy the schema to
   Production.
3. Do it again whenever a model gains a property.

Without this, sync fails in TestFlight and App Store builds.

## Caveats

- **Changing the models.** Add a property only with a default value. Never rename or retype one: iCloud keeps the old
  field, other devices still send it, and Production can't remove a field once it's deployed. The models' rules are
  in `ReGlass/Store/LibraryModels.swift`.
- **Turning it on uploads what's there.** Notes, reminders and lists already on the iPhone go to iCloud on the first
  sync.
- **Sync isn't instant.** While ReGlass is open, changes arrive within seconds or a minute. In the background, iOS
  delivers CloudKit's pushes when it chooses, and less often in Low Power Mode.
- **Two iPhones both ring.** Each device with ReGlass places alerts for the synced reminders, so a reminder can go off
  on both.
- **Changes at the same time.** If one note changes on two devices at once, one change wins.
- **Signing out of iCloud.** Signing out, or switching to another Apple Account, can remove that account's synced
  notes and reminders from the iPhone. They stay in iCloud and come back when you sign in again.
- **If iCloud refuses the store** at launch (the container isn't set up for your team, say), ReGlass logs it and keeps
  the library on the iPhone for that launch.
- **Storage.** The library counts toward your iCloud storage. It's small: text only.
