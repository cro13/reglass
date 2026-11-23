import Foundation

/// One decoded DataX message: its header and its application payload.
struct DataXMessage: Sendable, Equatable {
    let info: MessageInfo
    let payload: [UInt8]
}

/// The DataX channel multiplexer riding on one `SecureChannel`. An actor: the reader task, the consumer, the
/// command tasks and the trust/provisioning flows all reach it.
///
/// Reading model: one background reader decodes link frames into an unbounded queue; `receive` drains a
/// pushback inbox first, then that queue. `pushback`/`poll` let a flow (trust, provisioning) take the messages
/// it recognises and return the rest in order, so unrelated traffic is never lost.
actor DataXMultiplexer {
    private let link: SecureChannel
    let registry: ChannelRegistry

    /// Messages returned to the front, ahead of anything the reader has produced.
    private var inbox: [DataXMessage] = []
    /// Filled by the reader task; one consumer drains it.
    private let fromReader = AsyncQueue<DataXMessage>()
    private var reader: Task<Void, Never>?

    /// RX messageType delta-decode cache: a follow-up frame on a channel reports type 0 and inherits the last.
    private var rxLastType: [Int: Int] = [:]
    /// The DataX stream after the last whole message: the start of the next, cut wherever a frame ended.
    private var carry: [UInt8] = []
    /// This connection's one channel per service, for `sendOnService`.
    private var serviceChannels: [Int: Int] = [:]

    init(_ link: SecureChannel, _ registry: ChannelRegistry) {
        self.link = link
        self.registry = registry
    }

    /// True once `startReader` has run.
    var hasReader: Bool { reader != nil }

    /// Start the one task that reads the link into this connection. The caller owns the handle and cancels it.
    @discardableResult
    func startReader() throws -> Task<Void, Never> {
        guard reader == nil else { throw ReGlassError.protocolFailure("this connection already has a reader") }
        let task = Task { await self.runReader() }
        reader = task
        return task
    }

    private func runReader() async {
        do {
            while true {
                for message in try decode(try await link.receive()) { fromReader.push(message) }
            }
        } catch is CancellationError {
            fromReader.finish(throwing: CancellationError())
        } catch {
            fromReader.finish(throwing: error)
        }
    }

    /// Allocate a local channel id for `serviceId` and bind it in the registry.
    func openChannel(_ serviceId: Int) -> Int {
        let channelId = registry.nextLocalChannel()
        registry.bindLocal(channelId, serviceId)
        return channelId
    }

    /// End a channel this side opened: an empty message whose service tag is 0, then forget its binding. Sent
    /// before the binding goes, so a peer channel with the same low id is never touched.
    func closeLocalChannel(_ channelId: Int) async throws {
        guard channelId & DataXChannel.originatorBit != 0 else {
            throw ReGlassError.protocolFailure("only a channel this side opened can be closed")
        }
        try await send(channelId, [], serviceId: 0)
        registry.closeInbound(Self.mirror(channelId))
    }

    /// Send one DataX message on `channelId`. The service tag rides a channel's first message only.
    func send(_ channelId: Int, _ payload: [UInt8], messageType: Int? = nil, serviceId: Int? = nil) async throws {
        let header = try DataXHeader.build(channelId: channelId, dataLen: payload.count,
                                           serviceId: serviceId, messageType: messageType)
        try await link.send(header + payload)
    }

    /// Send on this connection's single channel for `serviceId`, opening it the first time. The glasses answer
    /// on every open channel of a service, so one channel per request would multiply every reply.
    func sendOnService(_ serviceId: Int, _ messageType: Int, _ payload: [UInt8]) async throws {
        if let known = serviceChannels[serviceId], registry.serviceForInbound(known & 0x7FFF) == serviceId {
            try await send(known, payload, messageType: messageType)
            return
        }
        let channel = openChannel(serviceId)
        serviceChannels[serviceId] = channel
        try await send(channel, payload, messageType: messageType, serviceId: serviceId)
    }

    /// Close this connection's single channel for `serviceId` (the one `sendOnService` opened), if there is one,
    /// and forget it so a later `sendOnService` opens a fresh one. The firmware installer uses this to close
    /// svc29 when the glasses report REBOOT or COMPLETE.
    func closeServiceChannel(_ serviceId: Int) async throws {
        guard let known = serviceChannels.removeValue(forKey: serviceId) else { return }
        try await closeLocalChannel(known)
    }

    /// Send a bare DataX status/error frame: an error-id tag, zero payload, on `channelId`.
    func sendStatus(_ channelId: Int, _ errorId: Int) async throws {
        try await link.send(try DataXHeader.build(channelId: channelId, dataLen: 0, errorId: errorId))
    }

    /// The next DataX message, decrypting more link frames as needed.
    func receive() async throws -> DataXMessage {
        if !inbox.isEmpty { return deliver(inbox.removeFirst()) }
        return deliver(try await fromReader.next())
    }

    /// Return messages to the front of the inbox, in their original order.
    func pushback(_ messages: [DataXMessage]) {
        inbox.insert(contentsOf: messages, at: 0)
    }

    /// Read whatever is already decoded, without waiting on the peer at all.
    func poll() -> DataXMessage? {
        if !inbox.isEmpty { return deliver(inbox.removeFirst()) }
        guard let message = fromReader.poll() else { return nil }
        return deliver(message)
    }

    /// Fill in the service on a closing frame and forget the channel. An empty OTA-style close can carry no
    /// service tag, so the service is resolved from the registry before the binding is dropped.
    private func deliver(_ message: DataXMessage) -> DataXMessage {
        guard message.info.flags.isClosed else { return message }
        let service = message.info.serviceId != 0 ? message.info.serviceId
            : registry.serviceForInbound(message.info.channelId)
        registry.closeInbound(message.info.channelId)
        var info = message.info
        info.serviceId = service
        return DataXMessage(info: info, payload: message.payload)
    }

    private func decode(_ plaintext: [UInt8]) throws -> [DataXMessage] {
        try splitMessages(plaintext).map { DataXMessage(info: applyTypeCache($0.info), payload: $0.payload) }
    }

    /// Fill `messageType` from the per-channel cache when a frame reports type 0 without an error.
    private func applyTypeCache(_ info: MessageInfo) -> MessageInfo {
        if info.messageType != 0 {
            rxLastType[info.channelId] = info.messageType
            return info
        }
        if !info.flags.hasError, let cached = rxLastType[info.channelId] {
            var copy = info
            copy.messageType = cached
            return copy
        }
        return info
    }

    /// Walk `plaintext` into DataX messages by `wireTotal = 4 + length`. The frames' data concatenates into one
    /// stream and a message runs wherever a frame cuts it, header included. The pad comes off first: walking it
    /// as data would let a message one byte short of the frame's end take the pad for its last byte, and the
    /// byte it was owed, at the head of the next frame, would then be read as a header.
    private func splitMessages(_ plaintext: [UInt8]) throws -> [DataXMessage] {
        let stream = carry + withoutPad(plaintext)
        var messages: [DataXMessage] = []
        var pos = 0
        while stream.count - pos >= 4 {
            let wireTotal = try DataXHeader.parse(Array(stream[pos..<(pos + 4)])).wireTotal
            if stream.count - pos < wireTotal { break }
            let whole = Array(stream[pos..<(pos + wireTotal)])
            let info = try DataXHeader.parse(whole)
            messages.append(DataXMessage(info: info, payload: Array(whole[info.headerLen..<wireTotal])))
            pos += wireTotal
        }
        carry = Array(stream[pos...])
        return messages
    }

    /// The acknowledgement channel for a channel: clear the originator bit.
    nonisolated static func mirror(_ channelId: Int) -> Int { channelId & 0x7FFF }
}

/// A frame's plaintext without its modified PKCS#7 tail. The glasses never end a frame's data in bytes that
/// read as valid padding, so this only strips a real pad.
func withoutPad(_ plaintext: [UInt8]) -> [UInt8] {
    guard let last = plaintext.last.map(Int.init) else { return plaintext }
    let padLen = (last + 0x40) & 0xFF
    if (1...16).contains(padLen), plaintext.count >= padLen,
       ((plaintext.count - padLen)..<plaintext.count).allSatisfy({ Int(plaintext[$0]) == last }) {
        return Array(plaintext[0..<(plaintext.count - padLen)])
    }
    return plaintext
}
