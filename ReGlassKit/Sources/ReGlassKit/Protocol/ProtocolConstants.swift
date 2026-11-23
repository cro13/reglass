import Foundation

// AirShield and DataX constants shared by the glasses and ReGlass.

/// DataX service ids ReGlass talks to.
enum DataXService {
    /// svc5, the AirShield link-setup handshake.
    static let linkSetup = 5
    /// svc15 (Oxide), the glasses' assistant: wake, microphone, replies.
    static let assistant = 15
    /// svc20 (Airship), file transfer: carries the wake word files.
    static let airship = 20
    /// svc22, where the phone sets the glasses' clock. Its answer also lists the installed language resources.
    static let deviceInfo = 22
    /// svc28 starts and stops applications and pushes battery, charging and wear status.
    static let status = 28
    /// svc29, the resource OTA service that installs a language feature's files.
    static let resourceOta = 29
    /// svc31, the glasses' settings service (adaptive volume, spatial audio).
    static let settings = 31
    /// svc36, ownership and trust.
    static let identity = 36
    /// svc72 controls 6-channel outward microphone capture for live translation.
    static let liveTranslation = 72
    /// svc100 reports the serial number, firmware build and model.
    static let peerBuildInfo = 100
}

/// DataX channel ids with a fixed meaning. The high bit (`originator`) says who opened a channel.
enum DataXChannel {
    /// RequestEncryption and the sealed EndLinkSetup ride the secure variant of channel 1.
    static let linkSetup = 0x8001
    /// EnableEncryption rides the plain variant of channel 1.
    static let enableEncryption = 0x0001
    /// Set on a channel id opened by this side.
    static let originatorBit = 0x8000
    /// Local channels start at 2: channel 0x8001 is link setup, so starting at 1 would collide with it.
    static let firstLocal = 0x0002
}

/// COMMAND-frame message types on svc5.
enum LinkSetupMessageType {
    static let requestEncryption = 1
    static let enableEncryption = 2
    static let endLinkSetup = 0x1000
}

/// svc36 message types (ownership and trust).
enum IdentityMessageType {
    /// phone → glasses, TX trust `{1: SHA256(appPubkey), 2: ECDSA sig(64), 3: provisioningCapabilities}`.
    static let enableTrust = 0x1000
    /// glasses → phone, RX trust `{1: keyHint, 2: sig(64), 3: provisioningCapabilities}`.
    static let enableTrustEC = 0x1001
    static let skipChallenge = 0x2000
    static let skipChallengeAck = 0x2001
    static let startChangeOwnerRequest = 0x2002
    static let startChangeOwnerResponse = 0x2003
    static let finishChangeOwnerRequest = 0x2004
    static let finishChangeOwnerResponse = 0x2005
    static let identityRequest = 0x3000
    static let identityResponse = 0x3001
}

/// svc36 verdict and status codes.
enum IdentityStatus {
    static let success = 0x1000
    static let failure = 0x1001
    static let notSupported = 0x1002
    static let unavailable = 0x1003
    static let keyNotFound = 0x1010
    static let invalidReceipt = 0x1040
    static let invalidNonce = 0x1041
    /// The glasses already have an owner, and the receipt names a different account.
    static let invalidUserId = 0x1042
    /// The glasses turned our app key down.
    static let invalidAppIdentity = 0x1043
    static let invalidSignature = 0x1044
    static let invalidTime = 0x1045
}

/// svc28 (status) message types.
enum StatusMessageType {
    /// Subscribes to device-state pushes.
    static let initialize = 1000
    static let initializeResponse = 1001
    /// Full device-state snapshot.
    static let deviceState = 2005
}

/// svc28 subscription selector for device-state pushes (message 2005).
let deviceStateSubscription: Int64 = 1

/// svc100 message types for reading the glasses' build information.
enum PeerBuildInfoMessageType {
    /// TX: the phone announces itself, which makes the glasses answer.
    static let peerAppInfo = 1
    /// RX: the glasses' build info.
    static let peerDeviceInfo = 3
}

/// svc22 message types for setting the clock and listing installed resources.
enum DeviceInfoMessageType {
    /// Sends the phone's clock and time zone.
    static let deviceInfoRequest = 1
    /// The glasses list installed language resources by artifact (tag 14) and feature (tag 16).
    static let deviceInfoResponse = 2
}

/// svc31 settings message types.
enum SettingsMessageType {
    /// Writes settings, including Adaptive Volume (tag 80) and Spatial Audio (tag 286).
    static let set = 2
    /// RX: `{1: status}`, where `status == 2` is success.
    static let setResponse = 3
}

/// svc28 (app manager) message types for starting and stopping a glasses application.
enum AppManagerMessageType {
    static let startApp = 2000
    static let startAppResponse = 2001
    static let stopApp = 2002
    static let stopAppResponse = 2003
}

/// svc29 (resource OTA) message types.
enum ResourceOtaMessageType {
    /// TX: the install request (key, one row per file, resources-only flag).
    static let install = 1
    /// RX: progress stage.
    static let progress = 2
    /// RX: the glasses rejected the install.
    static let rejected = 3
    /// RX: one file's status (1 complete, 2 or 3 send it).
    static let fileStatus = 4
    /// RX: empty install completion.
    static let completion = 7
    /// TX: feature status request; ReGlass only ever sends ENABLE.
    static let featureStatus = 8
    /// RX: the feature status answer.
    static let featureStatusResponse = 9
}

/// svc20 (Airship) message types, as the Audio MCU's OTA receiver uses them.
enum AirshipMessageType {
    /// TX: file offer `{1: uuid, 2: size, 3: "ota", 4: filename}`.
    static let offer = 1
    /// RX: cursor `{1: offset, 2: Adler-32 of the bytes before it}`.
    static let cursor = 2
    /// TX: up to 1024 file bytes.
    static let data = 4
    /// TX: a cursor every 64 KiB. The receiver says nothing when it matches.
    static let check = 5
    /// TX: the final cursor.
    static let complete = 6
    /// RX: the receiver's drop `{1: uuid}`: the file arrived (transport only, not installation). TX: decline.
    static let drop = 7
    /// TX: the sender releases the file `{1: uuid}`; also withdraws an unfinished one.
    static let removed = 8
    /// RX: a file offer from the glasses (not ours).
    static let peerOfferAlternate = 12
}

/// Generic DataX status codes used across services.
enum DataXStatus {
    /// Every service answers this on success. Also the EndLinkSetup acknowledgement.
    static let success = 0x1000
    /// What a peer answers for a service it does not host.
    static let serviceNotFound = 0xC001
}

/// Field 3 of EnableTrust / EnableTrustEC: `provisioningCapabilities`, a varint. 2 == EC P-256.
let provisioningCapabilitiesEC = 2

/// The link-setup key-exchange curve. It is NOT x25519.
let ecCurveSecp256r1 = 0

/// DataX message ceiling, imposed by the 14-bit length field.
let dataXMaxMessage = 16383

/// Relay substream control code referenced when a dropped link is diagnosed: stream 0 LOST.
let streamCommandLost = 1
