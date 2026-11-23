import Foundation

/// The AirShield secure channel over one `FrameTransport`: it runs the link-setup handshake, installs the
/// per-direction frame ciphers, and then carries plaintext in and out as sealed DATA frames.
///
/// An actor so the tx cipher state (seq, chained IV) and rx cipher state are each touched from one place at a
/// time. Sends are serialised and the byte write itself is made non-cancellable (see `transmit`) so a cancelled
/// caller can never advance the cipher without the frame reaching the wire, which would desync the link.
actor SecureChannel {
    private let transport: FrameTransport

    private var txCrypto: FrameCrypto?
    private var rxCrypto: FrameCrypto?

    /// DATA frames that arrived during the handshake, handled after `open` returns.
    private var pending: [[UInt8]] = []

    /// Channel-binding material for the svc36 trust signature. Nil until `open` succeeds.
    private(set) var binding: HandshakeBinding?

    /// The peer's link-setup channel. QCS peers choose e.g. 0x9701, not always the legacy 0x8001; its encrypted
    /// EndLinkSetup follows the channel its RequestEncryption opened.
    private(set) var peerLinkSetupChannel = DataXChannel.linkSetup

    /// The code of the last skipped COMMAND frame, read when a dropped link is diagnosed. Lock-guarded so the
    /// session can read it without hopping onto the actor.
    private let lastStreamCommandBox = Locked<Int?>(nil)
    nonisolated var lastStreamCommand: Int? { lastStreamCommandBox.current }

    // Serialises the actual byte writes and keeps them in submission order.
    private var sendTail: Task<Void, Error>?

    init(_ transport: FrameTransport) {
        self.transport = transport
    }

    /// Run the AirShield handshake and install the per-direction ciphers. EndLinkSetup is NOT sent here.
    ///
    /// Transmit-parameter negotiation is always on: the phone sends RequestEncryption, waits for the peer's
    /// RequestEncryption, then answers EnableEncryption on the mirror of the peer's channel with the peer's
    /// own parameters and quirks. (ReGlass always ran with this enabled.)
    func open() async throws {
        peerLinkSetupChannel = DataXChannel.linkSetup
        let keyPair = Ecdh.generateEphemeral()
        let myPublic = keyPair.publicKey64
        let myChallenge = secureRandomBytes(16)
        let mySeed = secureRandomBytes(32)
        let myIv = secureRandomBytes(16)
        // The per-direction random preamble seq, little endian.
        let seqBytes = secureRandomBytes(4)
        let mySeq = Int64(seqBytes[0]) | (Int64(seqBytes[1]) << 8) | (Int64(seqBytes[2]) << 16) | (Int64(seqBytes[3]) << 24)

        try await sendLinkSetup(
            DataXChannel.linkSetup, LinkSetupMessageType.requestEncryption,
            try RequestEncryption(publicKey: myPublic, challenge: myChallenge).encode()
        )

        var peerRequest: RequestEncryption?
        var peerEnable: EnableEncryption?
        var myEnable: EnableEncryption?

        for _ in 0..<Self.handshakeReads {
            let sdu = try await transport.receive()
            if let first = sdu.first, Int(first) & SubstreamFraming.typeMask == FrameType.data {
                pending.append(sdu)   // an early encrypted frame, handled after open()
                continue
            }
            let info = try DataXHeader.parse(sdu)
            guard sdu.count >= info.headerLen else { throw ReGlassError.protocolFailure("short link-setup frame") }
            let payload = Array(sdu[info.headerLen..<sdu.count])
            switch info.messageType {
            case LinkSetupMessageType.requestEncryption:
                let request = try RequestEncryption.decode(payload)
                peerRequest = request
                peerLinkSetupChannel = info.channelId
                if myEnable == nil {
                    let parameters = request.supportedParameters & 31
                    guard request.ellipticCurve == 0, [27, 31].contains(parameters), [0, 1].contains(request.quirks) else {
                        throw ReGlassError.protocolFailure("unsupported peer encryption proposal")
                    }
                    let enable = EnableEncryption(publicKey: myPublic, seed: mySeed, iv: myIv, base: mySeq,
                                                  parameters: parameters, quirks: request.quirks)
                    myEnable = enable
                    try await sendLinkSetup(DataXMultiplexer.mirror(info.channelId), LinkSetupMessageType.enableEncryption, try enable.encode())
                }
            case LinkSetupMessageType.enableEncryption:
                peerEnable = try EnableEncryption.decode(payload)
            default:
                break
            }
            if peerRequest != nil && peerEnable != nil { break }
        }

        guard let request = peerRequest, let enable = peerEnable, let myEnable else {
            throw ReGlassError.protocolFailure("handshake: missing RequestEncryption/EnableEncryption from peer")
        }

        let rxSecret = try Ecdh.sharedSecret(keyPair.privateKey, peerPublic64: enable.publicKey)
        binding = HandshakeBinding(glChallenge: request.challenge, mySeed: mySeed,
                                   glReqPub: request.publicKey, myPub: myPublic)

        // RX takes the peer's EnableEncryption key and quirks and our challenge; TX takes the peer's
        // RequestEncryption key and our seed. Our early EnableEncryption selected TX's mode.
        let rxKeys = try Kdf.deriveDirectionKeys(
            ecdhSecret: rxSecret, nonce: myChallenge, seed: enable.seed, preambleIv: enable.iv,
            info: Kdf.info(forQuirks: enable.quirks), parameters: enable.parameters
        )
        let txSecret = try Ecdh.sharedSecret(keyPair.privateKey, peerPublic64: request.publicKey)
        let txQuirks = myEnable.quirks
        let txKeys = try Kdf.deriveDirectionKeys(
            ecdhSecret: txSecret, nonce: request.challenge, seed: mySeed, preambleIv: myIv,
            info: Kdf.info(forQuirks: txQuirks), parameters: myEnable.parameters
        )
        rxCrypto = try FrameCrypto(rxKeys, counterPrefix: AirShieldCipher.counterPrefix(forQuirks: enable.quirks),
                                   initRxSeq: Int32(truncatingIfNeeded: enable.base))
        txCrypto = try FrameCrypto(txKeys, counterPrefix: AirShieldCipher.counterPrefix(forQuirks: txQuirks),
                                   initTxSeq: Int32(truncatingIfNeeded: mySeq))
        kitLog("link", String(format: "encrypted link open: peer link-setup channel 0x%04lx, rx mode %ld quirks %ld, tx mode %ld quirks %ld",
                                peerLinkSetupChannel, enable.parameters, enable.quirks, myEnable.parameters, txQuirks))
    }

    /// Send EndLinkSetup as a sealed DATA frame on the link-setup channel.
    func finishLinkSetup(asMain: Int = 1) async throws {
        guard txCrypto != nil else { throw ReGlassError.linkLost }
        let body = try EndLinkSetup(asMain: asMain, scopeUuid: LinkUUID.random(), leaseUuid: LinkUUID.random()).encode()
        let sdu = try DataXHeader.build(
            channelId: DataXChannel.linkSetup, dataLen: body.count,
            messageType: LinkSetupMessageType.endLinkSetup
        ) + body
        try await sealAndSend(sdu)
    }

    /// Send one plaintext DataX message as a sealed DATA frame.
    func send(_ plaintext: [UInt8]) async throws {
        guard txCrypto != nil else { throw ReGlassError.linkLost }
        try await sealAndSend(plaintext)
    }

    /// The next DATA frame's plaintext. Skips COMMAND frames, recording the last command code.
    func receive() async throws -> [UInt8] {
        guard let crypto = rxCrypto else { throw ReGlassError.linkLost }
        while true {
            let sdu: [UInt8]
            if !pending.isEmpty { sdu = pending.removeFirst() } else { sdu = try await transport.receive() }
            let frame = try SubstreamFraming.unpack(sdu)
            if frame.type == FrameType.data {
                // verifyUnpad false: the plaintext is a DataX message, possibly block-aligned with no pad
                // byte, and the DataX layer trims by header length.
                return try crypto.unseal(frame.body, verifyUnpad: false)
            }
            lastStreamCommandBox.withLock { $0 = frame.body.first.map(Int.init) }
        }
    }

    /// A link-setup message: a DataX message sent directly as the SDU, with no AirShield frame byte. The
    /// service tag rides the first message of the exchange (RequestEncryption) only.
    private func sendLinkSetup(_ channelId: Int, _ messageType: Int, _ protobuf: [UInt8]) async throws {
        let serviceId = messageType == LinkSetupMessageType.requestEncryption ? DataXService.linkSetup : nil
        let sdu = try DataXHeader.build(channelId: channelId, dataLen: protobuf.count,
                                        serviceId: serviceId, messageType: messageType) + protobuf
        try await transmit(sdu)
    }

    /// Seal and send under the send gate. Sealing is synchronous and advances the cipher in submission order;
    /// the write is then queued behind the previous one.
    private func sealAndSend(_ plaintext: [UInt8]) async throws {
        guard let crypto = txCrypto else { throw ReGlassError.linkLost }
        let frame = try SubstreamFraming.pack(FrameType.data, 0, try crypto.seal(plaintext))
        try await transmit(frame)
    }

    /// Serialise byte writes in submission order and make each write non-cancellable. The inner task is
    /// deliberately detached: it must run to completion even if the submitting task is cancelled, or the cipher
    /// would advance without the frame reaching the wire.
    private func transmit(_ frame: [UInt8]) async throws {
        let previous = sendTail
        let transport = self.transport
        let task = Task.detached {
            _ = await previous?.result
            try await transport.send(frame)
        }
        sendTail = task
        try await task.value
    }

    /// How many frames `open` reads while waiting for the peer's two handshake messages.
    private static let handshakeReads = 8
}
