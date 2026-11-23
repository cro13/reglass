@preconcurrency import AVFoundation
import Foundation

/// Plays a reply (24 kHz mono Int16 PCM) through the iPhone's current audio route: its speaker, the glasses when
/// they're connected as headphones, or the car. The app owns the audio session (category, ducking); this only plays.
public final class PCMPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: PCM.replyRate, channels: 1)!
    private let lock = NSLock()

    public init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    /// Plays `audio` to the end and returns the seconds played. `beforeFirstAudio` is awaited when the first samples
    /// arrive, before the engine starts (the moment to set up the session and dip other audio). Throws if the stream
    /// fails; cancelling stops playback at once.
    @discardableResult
    public func play(_ audio: AsyncThrowingStream<[Int16], Error>,
                     beforeFirstAudio: @escaping @Sendable () async -> Void = {}) async throws -> TimeInterval {
        let tracker = PlaybackTracker()
        var samples = 0
        var longest = 0
        do {
            try await withTaskCancellationHandler {
                for try await chunk in audio {
                    try Task.checkCancellation()
                    guard !chunk.isEmpty, let buffer = floatBuffer(chunk) else { continue }
                    if samples == 0 {
                        await beforeFirstAudio()
                        try startIfNeeded()
                    } else if !engine.isRunning {
                        try startIfNeeded()   // a route change stopped the engine
                    }
                    samples += chunk.count
                    longest = max(longest, chunk.count)
                    tracker.scheduled()
                    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in tracker.played() }
                }
                // A route change (the car switched off) can stop the engine with buffers still scheduled. If they
                // never report played, the wait ends once nothing has played for longer than the longest buffer.
                let limit = PCM.replySeconds(longest) + 2
                let watchdog = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(500))
                        if tracker.idle(for: limit) { return tracker.cancel() }
                    }
                }
                await tracker.drained()
                watchdog.cancel()
            } onCancel: { [weak self] in
                self?.halt()
                tracker.cancel()
            }
        } catch {
            halt()
            throw error
        }
        try Task.checkCancellation()
        halt()
        return PCM.replySeconds(samples)
    }

    /// Stops playback now.
    public func stop() {
        halt()
    }

    private func startIfNeeded() throws {
        try lock.withLock {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            if !node.isPlaying { node.play() }
        }
    }

    private func halt() {
        lock.withLock {
            node.stop()
            engine.stop()
        }
    }

    private func floatBuffer(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        for i in 0..<samples.count { channel[i] = Float(samples[i]) / 32768 }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

/// Counts scheduled and played buffers; `drained` returns once everything scheduled has been heard.
private final class PlaybackTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var cancelled = false
    /// The last buffer scheduled or played.
    private var progress = Date()

    func scheduled() {
        lock.withLock {
            pending += 1
            progress = Date()
        }
    }

    /// Buffers are waiting and none has been scheduled or played for `seconds`.
    func idle(for seconds: TimeInterval) -> Bool {
        lock.withLock { pending > 0 && Date().timeIntervalSince(progress) > seconds }
    }

    func played() {
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            pending = max(0, pending - 1)
            progress = Date()
            guard pending == 0, let waiter else { return nil }
            self.waiter = nil
            return waiter
        }
        resume?.resume()
    }

    func cancel() {
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            cancelled = true
            defer { waiter = nil }
            return waiter
        }
        resume?.resume()
    }

    func drained() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if pending == 0 || cancelled { return true }
                waiter = continuation
                return false
            }
            if now { continuation.resume() }
        }
    }
}
