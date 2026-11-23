import CoreBluetooth
import Foundation

/// Runs an open L2CAP channel's streams: incoming bytes are cut into SDUs and queued on `frames`; outgoing frames are
/// written whole and in order. Foundation streams report through a run loop, so they live on a thread of their own.
///
/// `@unchecked Sendable`: `reassembler` and `writes` (and the streams) are touched only on the pipe's thread; the
/// state other threads share is behind `shared`.
final class L2CAPPipe: NSObject, StreamDelegate, @unchecked Sendable {
    /// Whole frames from the glasses, then the error that ended the pipe.
    let frames = AsyncQueue<[UInt8]>()

    /// iOS closes the streams when the channel object goes, so the pipe keeps it.
    private let channel: CBL2CAPChannel
    private let input: InputStream
    private let output: OutputStream
    private let shared = Locked(Shared())

    // Pipe thread only.
    private var reassembler = SduReassembler()
    private var writes: [PendingWrite] = []

    private struct Shared {
        var runLoop: CFRunLoop?
        var stopped = false
        var failure: ReGlassError?
        /// Senders waiting for their frame to be written, by write id.
        var senders: [UInt64: CheckedContinuation<Void, Error>] = [:]
        var nextWrite: UInt64 = 0
    }

    private struct PendingWrite {
        let id: UInt64
        let bytes: [UInt8]
        var offset = 0
    }

    init(channel: CBL2CAPChannel) {
        self.channel = channel
        input = channel.inputStream
        output = channel.outputStream
        super.init()
    }

    /// Starts the pipe's thread and opens both streams; returns once the thread takes writes.
    func start() async {
        await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
            let thread = Thread { [self] in run(ready) }
            thread.name = "reglass.l2cap"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Writes `frame` and returns once the stream has taken all of it: one stream write when it fits, the rest in
    /// more writes (which iOS may send as another SDU). Cancelling ends the wait, not the frame: once queued, a frame
    /// goes out whole, so the stream stays framed.
    func send(_ frame: [UInt8]) async throws {
        guard !frame.isEmpty else { return }
        let id = shared.withLock { state -> UInt64 in
            state.nextWrite &+= 1
            return state.nextWrite
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, Error>) in
                let refusal: Error? = shared.withLock { state in
                    if let failure = state.failure { return failure }
                    if Task.isCancelled { return CancellationError() }
                    state.senders[id] = sent
                    return nil
                }
                if let refusal {
                    sent.resume(throwing: refusal)
                    return
                }
                let posted = onPipeThread { [self] in
                    writes.append(PendingWrite(id: id, bytes: frame))
                    drainOutput()
                }
                if !posted { finishWrite(id, throwing: shared.withLock { $0.failure } ?? .linkLost) }
            }
        } onCancel: {
            let sender = shared.withLock { $0.senders.removeValue(forKey: id) }
            sender?.resume(throwing: CancellationError())
        }
    }

    /// Ends the pipe: `frames` delivers what it holds, then `error`; waiting senders get `error`; both streams close
    /// and the thread ends. Idempotent; the first error is the one reported.
    func close(throwing error: ReGlassError) {
        let senders = shared.withLock { state -> [CheckedContinuation<Void, Error>] in
            if state.failure == nil { state.failure = error }
            defer { state.senders = [:] }
            return Array(state.senders.values)
        }
        frames.finish(throwing: error)
        for sender in senders { sender.resume(throwing: error) }
        let posted = onPipeThread { [self] in
            writes.removeAll()
            input.close()
            output.close()
            shared.withLock { $0.stopped = true }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        if !posted { shared.withLock { $0.stopped = true } }
    }

    // MARK: Pipe thread

    private func run(_ ready: CheckedContinuation<Void, Never>) {
        let loop = RunLoop.current
        // A port keeps the loop waiting even while the streams have nothing scheduled.
        loop.add(Port(), forMode: .default)
        let closedEarly = shared.withLock { state -> Bool in
            if !state.stopped { state.runLoop = CFRunLoopGetCurrent() }
            return state.stopped
        }
        guard !closedEarly else { return ready.resume() }
        input.delegate = self
        output.delegate = self
        input.schedule(in: loop, forMode: .default)
        output.schedule(in: loop, forMode: .default)
        input.open()
        output.open()
        ready.resume()
        while !shared.withLock({ $0.stopped }) {
            _ = loop.run(mode: .default, before: .distantFuture)
        }
        input.remove(from: loop, forMode: .default)
        output.remove(from: loop, forMode: .default)
        input.delegate = nil
        output.delegate = nil
        shared.withLock { $0.runLoop = nil }
        // Blocks posted just before the stop still run, so no sender is left behind.
        CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 0, true)
    }

    /// Runs `block` on the pipe's thread; false once the pipe has stopped.
    private func onPipeThread(_ block: @escaping () -> Void) -> Bool {
        guard let loop = shared.withLock({ $0.stopped ? nil : $0.runLoop }) else { return false }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(loop)
        return true
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            drainInput()
        case .hasSpaceAvailable:
            drainOutput()
        case .errorOccurred:
            kitLog("bluetooth", "L2CAP stream failed" + (stream.streamError.map { ": \(logDescription($0))" } ?? ""))
            close(throwing: .linkLost)
        case .endEncountered:
            kitLog("bluetooth", "the glasses closed the L2CAP channel")
            close(throwing: .linkLost)
        default:
            break
        }
    }

    private func drainInput() {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while input.hasBytesAvailable {
            let count = input.read(&chunk, maxLength: chunk.count)
            if count < 0 {
                kitLog("bluetooth", "L2CAP read failed" + (input.streamError.map { ": \(logDescription($0))" } ?? ""))
                return close(throwing: .linkLost)
            }
            if count == 0 { return }
            do {
                try reassembler.append(chunk[0..<count]) { frames.push($0) }
            } catch {
                kitLog("bluetooth", "L2CAP stream can't be framed: \(logDescription(error))")
                return close(throwing: error as? ReGlassError ?? .linkLost)
            }
        }
    }

    private func drainOutput() {
        while let write = writes.first, output.hasSpaceAvailable {
            guard shared.withLock({ $0.failure == nil }) else { return writes.removeAll() }
            let written = write.bytes.withUnsafeBufferPointer { buffer in
                output.write(buffer.baseAddress! + write.offset, maxLength: buffer.count - write.offset)
            }
            if written < 0 {
                kitLog("bluetooth", "L2CAP write failed" + (output.streamError.map { ": \(logDescription($0))" } ?? ""))
                return close(throwing: .linkLost)
            }
            if written == 0 { return }
            if written < write.bytes.count - write.offset {
                kitLog("bluetooth", "L2CAP stream took \(written) of \(write.bytes.count - write.offset) bytes; writing the rest")
            }
            writes[0].offset += written
            if writes[0].offset == write.bytes.count {
                writes.removeFirst()
                finishWrite(write.id)
            }
        }
    }

    private func finishWrite(_ id: UInt64, throwing error: ReGlassError? = nil) {
        guard let sender = shared.withLock({ $0.senders.removeValue(forKey: id) }) else { return }
        if let error { sender.resume(throwing: error) } else { sender.resume() }
    }
}
