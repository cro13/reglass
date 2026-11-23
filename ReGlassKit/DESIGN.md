# ReGlassKit design

ReGlassKit is ReGlass's own engine for Ray-Ban Meta glasses (tested with the Clubmaster, Audio). It talks to the
glasses directly over Bluetooth LE, with no Meta SDK. Keep it small and plain.

## Scope

1. **Find** the glasses: peripherals iOS already holds with Meta's service (FD5F), plus an LE scan; let iOS pair.
2. **Sign in with Meta**: the native email-code flow (Meta's server-driven "Bloks" screens), then the OIDC code →
   token → FRLA exchange, cached encrypted on the device. One method only.
3. **Transfer ownership** to ReGlass: ReGlass's own P-256 owner key, Meta's pairing backend, svc36 change-owner.
4. **Connect** with the saved key: Bluetooth L2CAP → AirShield encrypted link → DataX channels → svc36 trust →
   EndLinkSetup → READY, reconnecting with backoff.
5. **Status**: svc28 battery / charging / case battery / worn, svc100 serial / firmware / model.
6. **Wake word**: read which wake word set is installed (one empty svc22 request), and the install transaction for a
   set (Meta's factory "Hey Meta" set, or a custom one). Every set is made for one firmware build and goes only to
   glasses on that build. ReGlass ships **no** wake word files: `WakeWordLibrary` imports a set the wearer already
   has (a folder or `.zip` with `manifest.json` and the eight files, docs/WAKE-WORD.md), or downloads the factory
   set for the glasses' firmware from Meta after an explicit request. `FactoryWakeWordDownload` checks the seven
   prompts against the language pack's own manifest and takes the "Hey Meta" model from Meta's full firmware image
   by its fingerprint; it never flashes that image. The library keeps a checked copy in Application Support, left
   out of backups. A factory set must carry Meta's file ids and "Hey Meta" model; `load()` checks every file again
   before anything is sent. After a factory reset the store is empty, and the installer installs into it.
7. **Assistant service**: svc15 on the live connection, as the Audio glasses speak it (IDNM protobuf turn messages).
   Registration on every link, envelope acks, segmented-message reassembly, turn tracking, the "still working"
   keep-alive, microphone decode to 16 kHz PCM, reply encode (libopus CELT CBR) with real-time pacing, the 6001 wait,
   turn-less reply pushes (announcements: `Assistant/AssistantPushes.swift`), and passive logging of what the glasses
   send on their own. The svc72 live-translation microphone (6 channels) serves the app's interpreter. The contract
   with the app is `Assistant/AssistantLink.swift`.
8. **Timers**: running timers in the glasses' own scheduler, which chimes them without the phone (svc15 message 1100
   on the assistant's message channel), kept in step with the app's list, and the glasses' `tar_alert` when one rings,
   matched back to the timer. The app owns the list (`GlassesConnection.timers`, `Timers/GlassesTimers.swift`); wire
   format and firmware notes are in `Timers/TimerListMessages.swift`.
9. **Touch input**: a passive, receive-only decoder of the svc28 touch pushes, 2011 "captouch" (DeviceState field 5)
   and 2035 "action button" (field 29), with Meta's value names, published as
   `GlassesConnection.inputs()`. A repeat of the same kind within 250 ms is dropped. Only those two push types count
   (the 2005 snapshot carries last-known values, not new touches). Nothing is sent to get them. Logs kinds and timings
   only (`Device/GlassesInput.swift`).
10. **Firmware updates.** Check Meta's offers for Audio firmware, verify the downloaded image against Meta's
    checksum, then send the signed image over Bluetooth. The glasses verify Meta's signature and install the
    update. See [Firmware updates](../docs/FIRMWARE.md).

Out of scope: bug reports and resource operations beyond firmware and wake word updates; the assistant's legacy
Thrift path; the brain, voice and speech recognition (the app's `ReGlassAssistant` does that); Live AI; custom wake word
enrolment; Hearing; the rest of the TAR service (alarms, reminders and calendar records, svc 53210: only running
timers are sent); camera / media / Wi-Fi / RFCOMM; the web-view login; wire logs.

Deliberate choices, all on the safe side: a refusal is recorded only when the glasses did not accept
the key; the live connection never marks glasses verified; a re-transfer marks the record pending right before
START_CHANGE_OWNER; pairing HTTP refuses redirects; a factory restore is refused while Meta's fixed version is
already recorded (the glasses skip files whose version matches, partial ones included); both kinds of set require
the wake model to actually transfer before ENABLE.

### Assistant service: how it behaves

- **Streaming reply:** audio is encoded and sent as the app produces it.
  The stream starts once 450 ms is buffered; if the voice falls behind, encoded silence holds real time for up to
  2.5 s (`maxReplyGap`), after which the reply ends as a voice failure.
- **Microphone:** libopus decodes straight to 16 kHz, with no resampling.
- **Who decides:** the app ends speech and the turn (`finalTranscript`, `endTurn`); recognisers, follow-up timers and
  closing phrases are the app's business. With `expectFollowUp`, ReGlassKit opens a follow-up on the wire (new
  interaction id; closing the answered one if the wearer never spoke).
- **Unconfirmed playback:** a reply that ends the turn closes it (turn message 11) after 6001 or the 10 s fallback.
- **Reply bitrate:** svc100 field 12 when it's one the glasses accept (16–48 kbps); any other value falls back to
  32 kbps.
- **One wake, one turn:** if the microphone header names a different session than the StartSession that just opened
  the turn, it stays the same turn.
- **Cancelled by the app mid-reply:** the stream is ended with 6000, as after any other mid-stream failure. A new
  wake, the glasses closing the turn or a lost link stop it without 6000.
- **Registration timing:** on READY once svc100 named the saved glasses and trust completed both ways; again 2.5 s
  after the glasses close the assistant's channels (0xC002 / 0xC010 on m0 or s0).

### Timers: how they behave

- **The whole list every time.** Each 1100 replaces every slot (eight at most, lost when the glasses restart), so
  `GlassesTimers` keeps the app's full list and sends all of it whenever it changes and again at every registration
  of the assistant. Timers already due, or due within a second, are always left out: the firmware would drop one
  5–120 s late and restart one more than 120 s late with its full duration. The start time in a record is always
  when the timer was set.
- **No list while a voice turn is open; it goes when the turn ends.** Only lists sent with no turn open are proven,
  so the list waits (`AssistantService.closeTurn` fires the hook after turn message 11). The start stays the request
  time, so the glasses run the time left; a timer that falls due before the turn ends is left out and the app
  announces it. Turn-less pushes don't hold it.
- **The alert.** `tar_alert` (any svc15 path: turn message 6, an envelope, bare) goes to `GlassesTimers` instead of
  `.glassesAnnouncement`; it searches the payload for the id of each timer it sent and yields
  `GlassesTimerAlert(id:)`, with `id` nil when none is found (the app then matches on due time). The payload never
  leaves ReGlassKit and isn't logged.

## Protocol compatibility

The protocol details below were checked on firmware 1082194281. Keep requests and responses compatible with the
tested glasses and Meta's services. Test any protocol changes on real hardware.

- Bytes on the wire, field numbers, message types, service ids, channel numbering, flags, padding, counters,
  nonces, KDF inputs, signature formats, JSON byte layouts (`PyJson`), HTTP URLs / headers / bodies.
- Ordering of steps and messages, and the timeouts / retry / backoff values.
- Protocol traps: EndLinkSetup UUIDs are RFC 4122 v4; only the opening frame of a message carries service id and
  type; the channel registry keys on the originator bit (0x8000), local channels start at 0x0002; framing is
  `4 + length`; trust is ECDSA over an already-hashed digest with fixed 32-byte r and s, s folded to the low half;
  the peer link-setup channel follows the negotiated svc5 channel (`peerLinkSetupChannel`).
- iOS connection requirements include the QCS7 counter prefix, transmit-parameter negotiation, the peer
  link-setup channel and LE pairing via an encrypted read.

## Layout and layering

One Swift package, one module (`ReGlassKit`), folders by area. Everything is `internal` except the public API below.

| Folder | Contents | May use |
|---|---|---|
| `Support/` | errors, async helpers, logging, bytes, the `FrameTransport` contract, Meta client tokens, `Vault` | Foundation, CryptoKit, Security |
| `Protocol/` | protobuf wire codec, DataX header and framing, protocol constants, link-setup messages | Support |
| `Crypto/` | AirShield: ECDH, KDF, frame cipher, handshake binding | Support, Protocol |
| `Bluetooth/` | CoreBluetooth central, discovery, iOS pairing, L2CAP `FrameTransport`, SDU framing | Support |
| `Session/` | AirShield handshake (secure channel), DataX multiplexer, channel registry, link setup, reconnecting session, trust hook | Support, Protocol, Crypto |
| `Account/` | Meta sign-in (Bloks interpreter, OIDC, token exchange, encrypted login cache) | Support (+ `Resources/`) |
| `Identity/` | owner key, identity store, svc36 trust exchange, pairing backend, ownership transfer | Support, Protocol, Crypto, Session, Account |
| `Device/` | live connection, svc28 status, svc100 device info, clock sync, peer app info, read-only wake word read (parsing from `WakeWord/`) | everything above, `WakeWord/` parsing |
| `WakeWord/` | resource OTA (svc28 app manager, svc29) and Airship (svc20) messages, the svc22 resource list, the pinned sets, the set manifest, the library of imported sets (with a small read-only ZIP reader), the install transaction and its dedicated link | everything above |
| `Firmware/` | Meta's firmware offers, image download and verification, Bluetooth transfer and installation confirmation | account, protocol, Bluetooth and session layers |
| `Setup/` | public facades used by the app (ownership transfer / reconnect flows) | everything |
| `Assistant/` | the svc15 service (`AssistantService`, an actor), its messages, microphone decoder, reply encoder and buffer, turn-less pushes, the glasses' own requests (`GlassesRequests.swift`: 1046, decoded speech requests); `AssistantLink.swift` is the app contract | Support, Protocol, Session, `ReGlassOpus`; `Device/GlassesConnection` hosts it |
| `Timers/` | the glasses' own timers: the 1100 list (`TimerListMessages`), `GlassesTimers` (the app's list kept in step, `tar_alert` matching) and its send through the assistant service | `Assistant/` internals; `Device/GlassesConnection` hosts it |

`Protocol/` and `Crypto/` are pure (no I/O, no CoreBluetooth). Only `Bluetooth/` imports CoreBluetooth. No UIKit
anywhere in ReGlassKit. No Combine.

**One third-party dependency**: libopus from `https://github.com/alta/swift-opus.git`, **exact 0.0.2**, product
`Copus` (source only, no binaries or plugins). The Audio glasses play only CELT-only CBR replies and Apple's Opus
encoder has no control for that; replies play only with libopus. Swift can't call the variadic
`opus_encoder_ctl`, so a second, tiny C target `ReGlassOpus` (`Sources/ReGlassOpus`) wraps the encoder (restricted
low delay, bitrate, VBR off, lookahead) and the decoders; only `Assistant/` imports it. Opus's licence ships as
`Resources/opus-LICENSE.txt`.

## Conventions

- Swift API Design Guidelines. lowerCamelCase for constants, clear type names (`AirShieldHandshake`,
  `DataXMultiplexer`, `OwnershipTransfer`). Short doc comments that say why, not what. Small files, one main type
  each.
- Bytes are `[UInt8]`; convert to `Data` only at Apple API edges. Never index a `Data` slice from 0.
- Integer width matters on the wire: use explicit `UInt8/UInt16/UInt32/Int32/Int64` and wrapping operators where the
  format wraps.
- Concurrency: Swift concurrency. Actors for stateful async components (session, multiplexer). Every wait must be
  cancellation-aware (use `AsyncQueue`, `OneShot`, `withTimeout` from `Support/Async.swift`, or
  `withTaskCancellationHandler`). No semaphores, no blocking the caller, no `Task.detached` without reason.
  `@unchecked Sendable` only on classes whose state is behind `Locked` or a private serial queue (say which).
  Events go out as `AsyncStream`. Timeouts are `Duration` (`.seconds(10)`).
- Errors: anything that reaches the public API is a `ReGlassError` (`Support/ReGlassError.swift`). Internal error
  enums are fine; map them at the boundary with a precise case (not `.protocolFailure` for everything).
- Logging: `kitLog("area", "…")` with areas `bluetooth`, `link`, `account`, `ownership`, `device`, `wakeword`,
  `assistant`. One line per meaningful state change. Never log tokens, codes, keys, receipts, signatures, payload
  bytes, emails, names. The assistant logs states, turn numbers, sizes, timings and message type numbers only: never
  transcripts, reply text, interaction ids, or audio.
- Keep it as small as the behaviour allows. Delete code paths nothing in scope reaches.

## Public API (what the app uses)

Full doc comments are in the sources; this is the shape.

```swift
// Support
public enum ReGlassError: Error, Equatable, Sendable, LocalizedError { … }
public enum ReGlassKitLog { public static func setSink(_: (@Sendable (String) -> Void)?) }
public enum MetaClient { public static var isConfigured: Bool { get } }

// Bluetooth
public enum GlassesBluetooth {
    public static let restoreIdentifier: String          // "reglass.central"
    public static var isAuthorized: Bool { get }        // permission already granted (no prompt would show)
    public static func start()                           // creates the central; first call may prompt. Idempotent.
}
public struct NearbyGlasses: Identifiable, Equatable, Sendable { … }   // id, advertised name, rssi, paired, pairing mode
public final class GlassesFinder: Sendable {
    public init()
    public func scan() -> AsyncThrowingStream<[NearbyGlasses], Error>
    public func pair(_ id: UUID) async throws
}

// Account
public final class MetaAccount: Sendable {
    public enum Status: Equatable, Sendable { case signedOut, signingIn, signedIn, failed(String) }
    public init(storageDirectory: URL)
    public var status: Status { get }
    public func statusUpdates() -> AsyncStream<Status>   // starts with the current status
    public func beginSignIn() throws -> MetaSignIn        // .missingClientCredentials, .missingSignInData
    public func cancelSignIn()
    public func signOut()                                 // forgets the cached login only
}
/// One sign-in conversation. Meta drives every screen; the app renders `MetaSignIn.Screen` and sends actions back.
public final class MetaSignIn { … }

// Identity / Setup
public enum SetupStage: Int, CaseIterable, Comparable, Identifiable, Sendable { case account, connect, ownership, secure, finish }
public struct GlassesSetupResult: Sendable, Equatable { … }      // serial, battery, firmware, model
public enum OwnerKeyState: Sendable { case none, present, unreadable, damaged }
public struct SavedGlasses: Sendable, Equatable { public let id: UUID; public let serial: String; public let isVerified: Bool }
public enum GlassesVault {
    public static func ownerKeyState() -> OwnerKeyState
    public static func savedGlasses() throws -> [SavedGlasses]   // ReGlassError.keyUnavailable
    public static func forget(serial: String) throws              // drops the identity; the owner key is kept
}
public final class GlassesOwnership: Sendable {
    public init(glasses: UUID, account: MetaAccount)
    public var ownerChangeAttempted: Bool { get }
    /// Make ReGlass the owner (sign-in done). Reuses a saved key, never generates a second one.
    public func transfer(progress: @escaping @Sendable (SetupStage) -> Void) async throws -> GlassesSetupResult
    /// Reconnect with the saved key and verify it. No Meta, no ownership change.
    public func reconnect(progress: @escaping @Sendable (SetupStage) -> Void) async throws -> GlassesSetupResult
}

// Device
public struct GlassesStatus: Equatable, Sendable { … }          // connection, battery, case, worn, firmware, model, serial
public final class GlassesConnection: Sendable {
    public init(glasses: SavedGlasses) throws    // ReGlassError.keyUnavailable / .noSavedIdentity
    public func updates() -> AsyncStream<GlassesStatus>
    public func start()
    public func refresh()                        // ask for a fresh status snapshot
    public func stop() async                     // returns once the link has let go
    public var assistant: any GlassesAssistantLink { get }   // svc15; one per connection
    public let timers: GlassesTimers                         // the glasses' own timers; one per connection
    public func inputs() -> AsyncStream<GlassesInputEvent>   // touches (2011 / 2035), receive-only; ends on stop
    public func readWakeWord() async throws -> InstalledWakeWord   // read-only svc22; .wakeWordUnavailable elsewhere
}
public struct GlassesInputEvent: Sendable, Equatable { … }      // kind (tap, doubleTap, hold, …) and time
public struct GlassesTimer: Sendable, Equatable { … }           // id, title, start, duration
public struct GlassesTimerAlert: Sendable, Equatable { public let id: String?; public let at: Date }   // tar_alert
public final class GlassesTimers: Sendable {
    public func set(_ timers: [GlassesTimer])                // the whole list; sent now, after the turn, or at registration
    public func alerts() -> AsyncStream<GlassesTimerAlert>   // one consumer; a new call ends the previous stream
}

// Assistant (Assistant/AssistantLink.swift)
public struct AssistantTurnID: Hashable, Sendable, CustomStringConvertible { public let raw: UInt64 }
public enum AssistantEvent: Sendable {
    case availability(Bool), wake(AssistantTurnID), micAudio(AssistantTurnID, [Int16])
    case micAudioWhileBusy(AssistantTurnID, [Int16]), micEnded(AssistantTurnID), turnClosed(AssistantTurnID)
    case liveTranslationMicAudio([[Int16]]), liveTranslationMicState(Bool)
    case glassesAnnouncement(kind: String), glassesReport(GlassesReport)
}
public enum AssistantPlayback: Sendable, Equatable { case assistant, messaging, liveTranslation }   // 5002 field 19
public enum AssistantPushResult: Sendable, Equatable { case played, refused(String), noAnswer, unavailable(String) }
public protocol GlassesAssistantLink: AnyObject, Sendable {
    var events: AsyncStream<AssistantEvent> { get }
    func userSpeechStarted(_: AssistantTurnID) async
    func finalTranscript(_: AssistantTurnID, _ text: String) async
    func speak(_: AssistantTurnID, audio: AsyncThrowingStream<[Int16], Error>, expectFollowUp: Bool) async throws
    func holdTurn(_: AssistantTurnID) async
    func endTurn(_: AssistantTurnID) async
    func startLiveTranslationMic(sourceLanguage: String, targetLanguage: String) async -> Bool
    func stopLiveTranslationMic() async
    func pushSpeechWithoutTurn(audio: AsyncThrowingStream<[Int16], Error>) async -> AssistantPushResult
    func pushSpeechWithoutTurn(audio: AsyncThrowingStream<[Int16], Error>, playback: AssistantPlayback,
                               listenAfter: Bool) async -> AssistantPushResult
}

// Wake word
public enum WakeWord: String, CaseIterable, Sendable { case heyMeta, custom }
public enum InstalledWakeWord: Sendable, Equatable { case heyMeta, custom(artifact: String), olderCustom, incomplete, unknown }
public enum WakeWordProgress: Sendable, Equatable { case connecting, sending(Double), finishing }
public final class WakeWordLibrary: Sendable {
    public init(directory: URL)                           // e.g. Application Support/ReGlass/WakeWord
    public func stored(_: WakeWord) -> StoredSet?         // .heyMeta = the factory set
    public func importSet(from: URL) async throws -> StoredSet   // .wakeWordSetInvalid(reason); copies nothing then
    public func remove(_: WakeWord) throws                // this iPhone only
    public func check(_: WakeWord) async throws           // .wakeWordFilesDamaged
}
public final class WakeWordInstaller: Sendable {
    public init(glasses: SavedGlasses) throws            // same identity checks as GlassesConnection
    /// Its own session: the app stops the live connection first and restarts it after. Returns the readback.
    public func install(_: WakeWord, from: WakeWordLibrary,
                        progress: @escaping @Sendable (WakeWordProgress) -> Void) async throws -> InstalledWakeWord
}
```

## Building

The package builds as part of the app (`xcodebuild` with Xcode 27 or newer, which also fetches swift-opus). For a
quick type-check of a few folders, `xcrun -sdk iphoneos swiftc -typecheck` works too; `Assistant/` imports the
`ReGlassOpus` C module, which a bare `swiftc` finds through a `module.modulemap` pointing at
`Sources/ReGlassOpus/include/ReGlassOpus.h`.

## Never

- Send, from the assistant or anywhere else: svc 0x2B03 request 1 or svc15 message 1034 (they send a real SMS
  through the phone's message access), or svc15 1510 (opens a message-access connection). Nor svc15 1500 (MAP
  connection check). ReGlassKit sends nothing on svc46.
- Answer the glasses' 1046 ("is this the active phone?"). It stays unanswered, and the glasses drop the text after
  2 s.
- Send a timers list (1100) except from `Timers/GlassesTimers`, and never a partial one: the glasses clear every
  timer and reminder before decoding a list, so each send replaces everything on them. It always carries the app's
  whole list of running timers (none already due), never alarms, reminders or calendar records, and never on
  svc 53210.
