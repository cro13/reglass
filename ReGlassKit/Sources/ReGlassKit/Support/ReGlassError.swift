import Foundation

/// Everything that can go wrong, in terms the app can act on. Internal code may use its own error types, but
/// anything that leaves ReGlassKit's public API is a `ReGlassError`. Never put payloads, tokens or keys in a case.
public enum ReGlassError: Error, Equatable, Sendable {
    // Bluetooth
    case bluetoothUnsupported
    case bluetoothOff
    case bluetoothDenied
    /// iOS no longer knows these glasses (forgotten in Settings, or reset).
    case glassesUnknown
    /// Nothing answered in time: asleep, folded in the case, out of range, or another app holds them.
    case noAnswer
    case pairingDeclined
    /// The glasses were set up on this iPhone before and iOS still holds the old bond, so the encrypted link is
    /// refused. iOS has to forget the glasses first (Settings → Bluetooth → Forget This Device).
    case bondStale
    /// The link dropped while something was using it.
    case linkLost
    /// The glasses sent something ReGlassKit can't use. `detail` is short and log-safe.
    case protocolFailure(String)
    /// A bounded wait expired. `what` names the wait.
    case timedOut(String)

    // Identity and ownership
    /// The saved key can't be read yet: the iPhone hasn't been unlocked since it started.
    case keyUnavailable
    /// ReGlass has no saved key or identity for these glasses.
    case noSavedIdentity
    /// The glasses turned ReGlass's key down (they were set up with another app since).
    case keyRefused
    /// Different glasses answered than the ones ReGlass saved.
    case serialMismatch
    /// The trusted reconnect after setup didn't complete (trust, serial and battery all confirmed).
    case verificationIncomplete
    /// A different Meta account owns these glasses.
    case wrongOwnerAccount

    // Meta
    /// This build has no Meta client tokens (Secrets.xcconfig missing).
    case missingClientCredentials
    /// This build has no usable generated sign-in function table.
    case missingSignInData
    /// No usable Meta sign-in: never signed in, or it expired.
    case signInRequired
    /// Meta's service refused a request. Only the HTTP status is kept.
    case metaRejected(status: Int)
    /// The network request failed (URLError code).
    case network(code: Int)

    // Wake word
    /// Changing the wake word is only available on the firmware the wake word files were made for.
    case wakeWordUnavailable
    /// The wake word files on the glasses aren't a set ReGlass knows, so it changed nothing.
    case wakeWordUnrecognised
    /// This copy of ReGlass has wake word files that fail their checks; nothing was sent.
    case wakeWordFilesDamaged
    /// The glasses need more charge before they take new files. Nothing changed.
    case glassesNeedCharge
    /// The glasses are too warm to take new files. Nothing changed.
    case glassesTooWarm
    /// The glasses turned the change down before any file went over (their app-manager code). Nothing changed.
    case wakeWordDeclined(code: Int)
    /// Files went over but the change couldn't be confirmed: the wake word may not work until a set is installed.
    case wakeWordNotConfirmed
    /// Meta's original files are already recorded on the glasses (an earlier restore didn't finish), so restoring
    /// them again could leave a half-written file in place. Installing a custom set first rewrites everything.
    case wakeWordRestoreNeedsCustom
    /// A wake word set picked in Files can't be used. `reason` says what is wrong, in plain words (file names at
    /// most). Nothing was copied.
    case wakeWordSetInvalid(String)
    /// A factory download failed. Only a fixed, user-facing reason is kept, never server text or signed URLs.
    case wakeWordDownloadFailed(String)

    case cancelled
}

extension ReGlassError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .wakeWordDownloadFailed(let reason): return reason
        case .bluetoothUnsupported: return "This iPhone has no Bluetooth."
        case .bluetoothOff: return "Bluetooth is off. Turn it on in Control Center."
        case .bluetoothDenied: return "ReGlass isn't allowed to use Bluetooth. Turn it on in Settings → ReGlass."
        case .glassesUnknown: return "This iPhone no longer knows these glasses. Set them up again."
        case .noAnswer: return "Your glasses aren't answering. Wake them, keep them close, and close Meta AI."
        case .pairingDeclined: return "The Bluetooth pairing request was declined."
        case .bondStale: return "These glasses were paired with this iPhone before. Open Settings → Bluetooth, tap the ⓘ next to them and Forget This Device, then try again."
        case .linkLost: return "The connection to your glasses dropped."
        case .protocolFailure: return "Your glasses answered in a way ReGlass didn't expect."
        case .timedOut: return "Your glasses stopped answering."
        case .keyUnavailable: return "Unlock your iPhone so ReGlass can read its saved key."
        case .noSavedIdentity: return "ReGlass isn't set up on these glasses yet."
        case .keyRefused: return "Your glasses no longer accept ReGlass's key."
        case .serialMismatch: return "Different glasses answered than the ones ReGlass set up."
        case .verificationIncomplete: return "ReGlass couldn't confirm the secure connection."
        case .wrongOwnerAccount: return "A different Meta account owns these glasses."
        case .missingClientCredentials: return "This build of ReGlass has no Meta client credentials."
        case .missingSignInData:
            return "This build is missing Meta sign-in data. Run tools/meta-tokens/extract_meta_tokens.py, then rebuild ReGlass."
        case .signInRequired: return "Sign in with Meta to continue."
        case .metaRejected(let status): return "Meta declined the request (HTTP \(status))."
        case .network: return "No connection to Meta. Check that your iPhone is online."
        case .wakeWordUnavailable: return "Changing the wake word isn't available for this firmware."
        case .wakeWordUnrecognised: return "ReGlass doesn't recognise the wake word files on your glasses, so it left them as they are."
        case .wakeWordFilesDamaged: return "The wake word files are missing or damaged. Nothing was sent."
        case .glassesNeedCharge: return "Your glasses need more charge first. Nothing changed. Charge them a little and try again."
        case .glassesTooWarm: return "Your glasses are too warm right now. Nothing changed. Let them cool down and try again."
        case .wakeWordDeclined: return "Your glasses can't take a new wake word right now. Nothing changed. Try again in a few minutes."
        case .wakeWordNotConfirmed: return "The wake word didn't finish installing, so it may not work. Keep your glasses close and install it again."
        case .wakeWordRestoreNeedsCustom: return "An earlier restore didn't finish. Install a custom wake word first, then restore Hey Meta. Nothing changed."
        case .wakeWordSetInvalid(let reason): return "ReGlass can't use this set. " + reason + " Nothing was copied."
        case .cancelled: return "Cancelled."
        }
    }
}

extension ReGlassError {
    /// Maps any error to a `ReGlassError` for the public API.
    static func from(_ error: Error) -> ReGlassError {
        if let kitError = error as? ReGlassError { return kitError }
        if error is CancellationError { return .cancelled }
        if let url = error as? URLError { return url.code == .cancelled ? .cancelled : .network(code: url.code.rawValue) }
        return .protocolFailure(String(describing: type(of: error)))
    }
}
