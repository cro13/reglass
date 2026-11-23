import Foundation

// The timer list (message 1100) goes out through the assistant service: the firmware reads it on the assistant's own
// message channel, and every svc15 send must keep its place in the service's ordered outbox.
extension AssistantService {
    enum TimerListSend {
        case sent
        /// A voice turn is open; try again when it ends.
        case turnOpen
        /// Not registered on a link (or the link dropped); the next registration sends it.
        case unavailable
    }

    /// Sends one timer list on the message channel (m0) as a bare DataX message of type 1100, the route the firmware
    /// reads and a device test proved. Needs the assistant registered on the current link and no turn open.
    func sendTimerList(_ payload: [UInt8]) async -> TimerListSend {
        guard !stopped, let reg = registration, reg.registered, let m0 = reg.m0 else { return .unavailable }
        guard turn == nil else { return .turnOpen }
        do {
            try await send(reg.mux, m0, payload, type: TimerListMessages.syncType)
            return .sent
        } catch {
            return .unavailable
        }
    }
}
