import CoreBluetooth
import Foundation

extension ReGlassError {
    /// Why Bluetooth can't be used in `state`, or nil while it may still come on. After a full wait, an unanswered
    /// permission prompt counts as denied and any other in-between state as off.
    static func unavailable(_ state: CBManagerState, afterWaiting: Bool = false) -> ReGlassError? {
        switch state {
        case .poweredOn: return nil
        case .unsupported: return .bluetoothUnsupported
        case .unauthorized: return .bluetoothDenied
        case .poweredOff: return .bluetoothOff
        default:
            guard afterWaiting else { return nil }
            return CBManager.authorization == .notDetermined ? .bluetoothDenied : .bluetoothOff
        }
    }
}

/// True for errors that mean the LE link needs pairing or lost it: the request was turned down on the iPhone or by
/// the glasses, or the glasses forgot this iPhone.
func isPairingFailure(_ error: Error) -> Bool {
    let error = error as NSError
    switch error.domain {
    case CBErrorDomain:
        return [CBError.Code.peerRemovedPairingInformation, .encryptionTimedOut].map(\.rawValue).contains(error.code)
    case CBATTErrorDomain:
        return [CBATTError.Code.insufficientAuthentication, .insufficientAuthorization,
                .insufficientEncryptionKeySize, .insufficientEncryption].map(\.rawValue).contains(error.code)
    default:
        return false
    }
}

/// A pairing failure that specifically means the glasses no longer accept the bond this iPhone still holds: the
/// encrypted read is refused because the keys don't match (seen after the glasses are factory-reset while iOS keeps
/// its old pairing record). A retry can't fix it — iOS has to drop its keys first (Settings → Bluetooth → Forget
/// This Device). This is narrower than `isPairingFailure`, which also covers a prompt the person declined.
func isStaleBondFailure(_ error: Error) -> Bool {
    let error = error as NSError
    switch error.domain {
    case CBErrorDomain:
        return error.code == CBError.Code.peerRemovedPairingInformation.rawValue
    case CBATTErrorDomain:
        return [CBATTError.Code.insufficientEncryption,
                .insufficientEncryptionKeySize].map(\.rawValue).contains(error.code)
    default:
        return false
    }
}

/// iOS still holds the previous L2CAP channel on this PSM (CBInternalErrorDomain 24, seen right after a channel
/// closed). Worth one retry.
struct ChannelStillClosing: Error {}

func isChannelStillClosing(_ error: Error) -> Bool {
    let error = error as NSError
    return error.domain == "CBInternalErrorDomain" && error.code == 24
}

/// Domain and code only: enough to tell what iOS did, nothing about the glasses or the person.
func logDescription(_ error: Error) -> String {
    if let error = error as? ReGlassError { return "\(error)" }
    if error is CancellationError { return "cancelled" }
    let ns = error as NSError
    return "\(ns.domain) \(ns.code)"
}

extension CBManagerState {
    var logName: String {
        switch self {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "not allowed"
        case .poweredOff: return "off"
        case .poweredOn: return "on"
        @unknown default: return "state \(rawValue)"
        }
    }
}

extension CBPeripheralState {
    var logName: String {
        switch self {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        @unknown default: return "state \(rawValue)"
        }
    }
}
