import Foundation

/// Why a wake word read or install stopped, in log-safe words. Mapped to a `ReGlassError` at the public boundary.
enum WakeWordFault: Error, CustomStringConvertible {
    /// A reply that can't be read.
    case malformed(String)
    /// The Airship transfer of one file failed.
    case transfer(String)
    /// The glasses turned something down: a file status, a rejection, a refused channel.
    case refused(String)
    /// The app manager answered the OTA application start or stop with this code.
    case application(code: Int64, starting: Bool)
    /// A bounded wait ran out.
    case timedOut(String)
    /// The link dropped or reconnected under the run.
    case connectionChanged
    /// The glasses skipped the wake model, so a fresh set changed nothing that matters.
    case wakeFileSkipped
    /// The readback after the install does not show the new set enabled.
    case readbackMismatch
    /// The installed resources are not a set ReGlass knows.
    case unrecognisedResources
    /// Firmware other than the one the sets were made for.
    case unsupportedFirmware
    /// The set is made for another firmware build than the glasses run (nothing sent).
    case setForOtherFirmware(set: String, glasses: String)
    /// A bundled file failed its size or SHA-256 check.
    case damagedSet(String)
    /// Hey Meta asked for while Meta's fixed version is already recorded: the glasses would skip files whose
    /// version matches, partial ones included, so nothing is sent.
    case restoreNeedsFreshSet

    var description: String {
        switch self {
        case .malformed(let what): return "unreadable reply (\(what))"
        case .transfer(let what): return "transfer stopped (\(what))"
        case .refused(let what): return "refused (\(what))"
        case .application(let code, let starting):
            return "OTA application \(starting ? "start" : "stop") answered \(code)"
        case .timedOut(let what): return "timed out waiting for \(what)"
        case .connectionChanged: return "the connection changed"
        case .wakeFileSkipped: return "the glasses skipped the wake model"
        case .readbackMismatch: return "the readback does not show the new set enabled"
        case .unrecognisedResources: return "unrecognised resources installed"
        case .unsupportedFirmware: return "unsupported firmware"
        case .setForOtherFirmware(let set, let glasses): return "set made for \(set), glasses run \(glasses)"
        case .damagedSet(let what): return "wake word file missing or failed its check (\(what))"
        case .restoreNeedsFreshSet: return "factory version already recorded; restoring it again could skip partial files"
        }
    }

    /// The public error. Once the install request has gone out (`changing`), anything that is not a clean refusal
    /// before the first file means the result is unconfirmed.
    static func reglassError(_ error: Error, changing: Bool) -> ReGlassError {
        if error is CancellationError { return changing ? .wakeWordNotConfirmed : .cancelled }
        if let fault = error as? WakeWordFault {
            switch fault {
            case .unsupportedFirmware: return .wakeWordUnavailable
            case .setForOtherFirmware(let set, let glasses):
                return .wakeWordSetInvalid("It's made for firmware \(set), and your glasses run \(glasses). "
                    + (set == glasses ? "" : "Download the factory set again, or use a set made for \(glasses)."))
            case .unrecognisedResources: return .wakeWordUnrecognised
            case .damagedSet: return .wakeWordFilesDamaged
            case .restoreNeedsFreshSet: return .wakeWordRestoreNeedsCustom
            case .application(let code, true) where !changing:
                switch code {
                case 6, 14, 15: return .glassesNeedCharge   // low battery, must charge, power policy
                case 7: return .glassesTooWarm
                default: return .wakeWordDeclined(code: Int(code))
                }
            case .timedOut(let what) where !changing: return .timedOut(what)
            case .connectionChanged where !changing: return .linkLost
            case .malformed(let what) where !changing: return .protocolFailure(what)
            case .refused(let what) where !changing: return .protocolFailure(what)
            default: return changing ? .wakeWordNotConfirmed : .protocolFailure(fault.description)
            }
        }
        let kitError = ReGlassError.from(error)
        if changing, kitError != .keyRefused, kitError != .serialMismatch { return .wakeWordNotConfirmed }
        return kitError
    }
}
