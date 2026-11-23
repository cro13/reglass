import Foundation

/// One install's svc29/svc20 transaction, run while the glasses' OTA application is started: the install request,
/// each file the glasses ask for over one Airship channel, the completion, ENABLE, and closing the channel.
///
/// An actor: the session's pump delivers replies (`receiveOta`, `receiveAirship`, `receiveStatus`) between the
/// sends of `run`. Replies only record state; `run` acts on it. Waits poll that state, so each one notices a
/// failure, a changed link or cancellation within 50 ms.
actor WakeWordTransfer {
    private let mux: DataXMultiplexer
    private let loaded: WakeWordSet.Loaded
    private let version: String
    private let requireWakeTransfer: Bool
    private let isCurrent: @Sendable () -> Bool
    private let progress: @Sendable (WakeWordProgress) -> Void
    private let key = ResourceOta.Key()

    private var wanted = Set<Int>()
    private var finished = Set<Int>()
    private var completion = false
    private var activationReply = false
    private var failure: WakeWordFault?
    private var sender: AirshipSender?
    private var channel: Int?
    private var activeIndex: Int?
    /// The file being sent, kept after a failure for the log.
    private var transferFilename: String?
    private var transferred = 0
    private var wakeFileTransferred = false
    private var sentBytes = 0
    private var reportedPercent = -1

    /// The install request went out: from here the glasses' files may change.
    private(set) var requested = false

    init(mux: DataXMultiplexer, loaded: WakeWordSet.Loaded, version: String, requireWakeTransfer: Bool,
         isCurrent: @escaping @Sendable () -> Bool, progress: @escaping @Sendable (WakeWordProgress) -> Void) {
        self.mux = mux
        self.loaded = loaded
        self.version = version
        self.requireWakeTransfer = requireWakeTransfer
        self.isCurrent = isCurrent
        self.progress = progress
    }

    // MARK: Replies (from the session's pump)

    /// svc29: file statuses, the completion, the feature answer.
    func receiveOta(type: Int, payload: [UInt8], from source: DataXMultiplexer) {
        guard source === mux, isCurrent(), failure == nil else { return }
        do {
            guard let reply = try ResourceOta.reply(type: type, payload: payload, key: key) else { return }
            switch reply {
            case let .fileStatus(uuid, status):
                guard let index = loaded.files.firstIndex(where: { $0.uuid == uuid }) else { return }
                let name = loaded.files[index].name
                switch status {
                case 1:
                    finished.insert(index)
                    note("file status 1 (complete): \(name)")
                case 2, 3:
                    if !finished.contains(index) { wanted.insert(index) }
                    note("file status \(status) (send it): \(name)")
                default:
                    throw WakeWordFault.refused("file status \(status) for \(name)")
                }
            case let .rejected(error, stage, code):
                throw WakeWordFault.refused("install rejected: error \(error), stage \(stage), code \(code)")
            case .progress:
                break
            case .completion:
                // The completion carries no correlation: accept it only at the end of this install.
                let finalInFlight = activeIndex == loaded.files.count - 1 && sender?.sent == sender?.size
                guard finished.count == loaded.files.count
                        || (finished.count == loaded.files.count - 1 && finalInFlight) else {
                    throw WakeWordFault.refused("an early install completion")
                }
                completion = true
                note("install completion received")
            case let .featureResult(status, result):
                activationReply = true
                note("feature answer: status \(status), result \(result)")
            }
        } catch let fault as WakeWordFault {
            failure = fault
        } catch {
            failure = .malformed("install reply")
        }
    }

    /// svc20 on our channel's mirror: the receiver's cursors and drop.
    func receiveAirship(_ message: DataXMessage, from source: DataXMultiplexer) {
        guard source === mux, isCurrent(), let channel, sender != nil,
              message.info.channelId == DataXMultiplexer.mirror(channel) else { return }
        do {
            try sender?.receive(type: message.info.messageType, payload: message.payload)
        } catch let fault as WakeWordFault {
            failure = fault
        } catch {
            failure = .malformed("transfer reply")
        }
    }

    /// A refusal status frame. svc29's on any channel stops the install (0xd010 also covers a request the glasses
    /// could not decode or dispatch); svc20's only when it is about our Airship channel.
    func receiveStatus(service: Int, channel statusChannel: Int, status: Int) {
        guard isCurrent(), failure == nil else { return }
        if service == DataXService.airship {
            guard let channel, statusChannel == DataXMultiplexer.mirror(channel) else { return }
            failure = .refused(String(format: "svc20 status 0x%04x on the transfer channel", status))
        } else if service == DataXService.resourceOta {
            failure = .refused(String(format: "svc29 status 0x%04x", status))
        }
    }

    // MARK: Run

    func run() async throws {
        try checkCurrent()
        let request = try ResourceOta.install(key: key, artifact: loaded.set.artifact, version: version,
                                              files: loaded.files)
        note("install request: \(loaded.files.count) files, version \(version), \(request.count) bytes")
        do {
            requested = true
            try await mux.sendOnService(DataXService.resourceOta, ResourceOtaMessageType.install, request)
            let overall = ContinuousClock.now + Self.overallLimit
            // The MCU can spend up to 60 s on its own state change before it asks for the first file.
            var idle = ContinuousClock.now + Self.firstRequestLimit
            while !completion || finished.count < loaded.files.count {
                try checkCurrent()
                let now = ContinuousClock.now
                guard now < overall, now < idle else { throw WakeWordFault.timedOut("the glasses to ask for files") }
                if let index = wanted.sorted().first(where: { !finished.contains($0) }) {
                    wanted.remove(index)
                    try await sendFile(index)
                    finished.insert(index)
                    idle = ContinuousClock.now + Self.nextRequestLimit
                } else {
                    try await Task.sleep(for: Self.poll)
                }
            }
            note("all \(loaded.files.count) files complete; \(transferred) sent")
            if requireWakeTransfer, !wakeFileTransferred { throw WakeWordFault.wakeFileSkipped }
            try checkCurrent()
            progress(.finishing)
            try await mux.sendOnService(DataXService.resourceOta, ResourceOtaMessageType.featureStatus,
                                        try ResourceOta.enable(key: key))
            let deadline = ContinuousClock.now + Self.enableLimit
            while !activationReply, ContinuousClock.now < deadline {
                try checkCurrent()
                try await Task.sleep(for: Self.poll)
            }
            guard activationReply else { throw WakeWordFault.timedOut("the feature answer") }
            try await closeAirshipChannel(withdraw: false)
        } catch {
            note("interrupted: file \(transferFilename ?? "none"), sent \(sender?.sent ?? 0), "
                 + "\(finished.count)/\(loaded.files.count) complete: \(Self.describe(error))")
            if isCurrent() {
                // Bounded, and in its own task so a cancelled caller still withdraws the file and closes the channel.
                let cleanup = Task { try await withTimeout(Self.cleanupLimit, "the transfer cleanup") {
                    try await self.closeAirshipChannel(withdraw: true)
                } }
                do { try await cleanup.value } catch { note("transfer cleanup not confirmed") }
            }
            throw error
        }
    }

    /// Offers one file on the operation's single Airship channel (opened with the first file) and streams it until
    /// the receiver's drop has been answered with REMOVED.
    private func sendFile(_ index: Int) async throws {
        activeIndex = index
        defer { activeIndex = nil }
        let file = loaded.files[index]
        transferFilename = file.name
        sender = try AirshipSender(data: loaded.contents[index], uuid: file.uuid, filename: file.name)
        let opening = channel == nil
        let airshipChannel: Int
        if let channel { airshipChannel = channel } else { airshipChannel = await mux.openChannel(DataXService.airship) }
        channel = airshipChannel
        guard let offer = try sender?.offer() else { return }
        note("sending \(file.name): \(loaded.contents[index].count) bytes")
        try await mux.send(airshipChannel, offer.payload, messageType: offer.type,
                           serviceId: opening ? DataXService.airship : nil)
        var deadline = ContinuousClock.now + Self.replyLimit
        while sender?.state != .delivered {
            try checkCurrent()
            guard ContinuousClock.now < deadline else {
                let offset = sender?.sent ?? 0
                throw WakeWordFault.timedOut(offset == 0 ? "the first cursor for \(file.name)"
                                             : "a reply after \(offset) bytes of \(file.name)")
            }
            if let frame = try sender?.next() {
                try await mux.send(airshipChannel, frame.payload, messageType: frame.type)
                deadline = ContinuousClock.now + Self.replyLimit
                if frame.type == AirshipMessageType.complete { note("\(file.name): complete sent") }
                reportProgress()
            } else {
                try await Task.sleep(for: Self.filePoll)
            }
        }
        transferred += 1
        if file.name == ResourceOta.wakeModelFilename { wakeFileTransferred = true }
        sentBytes += loaded.contents[index].count
        sender = nil
        transferFilename = nil
        note("\(file.name): delivered (the receiver dropped it; installation is confirmed separately)")
    }

    /// Closes the Airship channel; with `withdraw`, first sends REMOVED for an unfinished file.
    func closeAirshipChannel(withdraw: Bool) async throws {
        guard let channel, isCurrent() else { return }
        if withdraw, let frame = sender?.cancel() {
            do {
                try await mux.send(channel, frame.payload, messageType: frame.type)
                note("withdrew the unfinished file")
            } catch {
                note("could not withdraw the unfinished file; closing its channel")
            }
        }
        try await mux.closeLocalChannel(channel)
        self.channel = nil
        note("transfer channel closed")
    }

    // MARK: Helpers

    private func checkCurrent() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw WakeWordFault.connectionChanged }
        if let failure { throw failure }
    }

    /// Whole percent of the set's bytes handed to the link, reported when it moves.
    private func reportProgress() {
        let total = loaded.set.totalBytes
        guard total > 0 else { return }
        let done = sentBytes + (sender?.sent ?? 0)
        let percent = min(100, done * 100 / total)
        guard percent > reportedPercent else { return }
        reportedPercent = percent
        progress(.sending(Double(percent) / 100))
        if percent > 0, percent % 25 == 0 { note("\(percent)% sent") }
    }

    private func note(_ line: String) {
        kitLog("wakeword", line)
    }

    private static func describe(_ error: Error) -> String {
        if let fault = error as? WakeWordFault { return fault.description }
        if error is CancellationError { return "cancelled" }
        return String(describing: ReGlassError.from(error))
    }

    /// The whole install request, 900 s.
    private static let overallLimit: Duration = .seconds(900)
    /// Until the first file request: the MCU's OTA entry may wait 60 s for its own state change, so 90 s.
    private static let firstRequestLimit: Duration = .seconds(90)
    /// After each file, until the next request or the completion.
    private static let nextRequestLimit: Duration = .seconds(20)
    /// For each Airship reply (and after each frame sent).
    private static let replyLimit: Duration = .seconds(12)
    /// For the feature answer after ENABLE.
    private static let enableLimit: Duration = .seconds(10)
    /// For withdrawing and closing after a failure.
    private static let cleanupLimit: Duration = .seconds(5)
    private static let poll: Duration = .milliseconds(50)
    private static let filePoll: Duration = .milliseconds(20)
}
