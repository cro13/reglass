import Foundation

/// Which DataX channel is talking to which service. Keyed on the originator bit (0x8000): a local map for
/// channels this side opened and a peer map for channels the glasses opened, so the same low id on both sides
/// never collides. Local channels start at 2 (0x8001 is the link-setup channel).
///
/// Lock-guarded rather than an actor: every operation is a short synchronous map read or write, and both the
/// multiplexer and the session touch it.
final class ChannelRegistry: @unchecked Sendable {
    private struct State {
        var local: [Int: Int] = [:]
        var peer: [Int: Int] = [:]
        var nextChannel = DataXChannel.firstLocal
    }
    private let state = Locked(State())

    /// Allocate the next channel id for a channel this side opens, with the originator bit set.
    func nextLocalChannel() -> Int {
        state.withLock { s in
            let channel = s.nextChannel
            s.nextChannel += 1
            return DataXChannel.originatorBit | channel
        }
    }

    /// Record the service of a channel this side opened.
    func bindLocal(_ channelId: Int, _ serviceId: Int) {
        state.withLock { $0.local[channelId & 0x7FFF] = serviceId }
    }

    /// Record the service named on an inbound frame, whichever side opened the channel.
    func bindInbound(_ channelId: Int, _ serviceId: Int) {
        state.withLock { s in
            if channelId & DataXChannel.originatorBit != 0 { s.peer[channelId & 0x7FFF] = serviceId }
            else { s.local[channelId & 0x7FFF] = serviceId }
        }
    }

    /// The service on `channelId`, or 0 when nothing has named one.
    func serviceForInbound(_ channelId: Int) -> Int {
        state.withLock { s in
            (channelId & DataXChannel.originatorBit != 0 ? s.peer : s.local)[channelId & 0x7FFF] ?? 0
        }
    }

    func closeInbound(_ channelId: Int) {
        state.withLock { s in
            if channelId & DataXChannel.originatorBit != 0 { s.peer[channelId & 0x7FFF] = nil }
            else { s.local[channelId & 0x7FFF] = nil }
        }
    }
}
