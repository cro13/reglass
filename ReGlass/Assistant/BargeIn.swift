@preconcurrency import AVFoundation
import Foundation
import Speech

/// Barge-in: "Hey Meta" said while ReGlass is thinking or talking stops the reply, and ReGlass listens for the new
/// request in the same chat.
///
/// The glasses send no wake while their assistant holds a turn: no StartSession arrives during a reply, so a second
/// "Hey Meta" never reaches ReGlass and a request said over the reply would be lost. Their microphone keeps
/// streaming through the turn, though (ReGlassKit's `micAudioWhileBusy`). `BargeInSpotter` listens to that audio with
/// Apple's on-device recognizer (free, nothing leaves the iPhone) for the wake phrase only, and `ReplyGate` cuts the
/// reply short when it's heard.
///
/// The reply's own voice is in that audio too (the stream has no usable echo cancellation), so a wake phrase in the
/// reply's own words doesn't count. Nothing here logs words; the caller logs whether it was heard and the levels.
final class BargeInSpotter: @unchecked Sendable {
    struct Summary {
        /// Audio received, in seconds.
        let seconds: Double
        /// The loudest 20 ms of it, in dBFS (nil without audio).
        let loudestDB: Double?
        let heard: Bool
        /// Recognition results seen (words in the audio, the reply's included): zero means the recognizer heard nothing.
        let updates: Int
    }

    /// "Hey Meta", "Hey, Meta", "OK Meta".
    private static let phrase = #"\b(ok|okay|hey)[\s,.!-]*meta\b"#
    private static let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!

    private let lock = NSLock()
    private var replySaid = ""
    private let onWake: @Sendable () -> Void
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var heard = false
    private var updates = 0
    private var samples = 0
    private var loudest: Double = 0

    /// `onWake` runs once, on the main queue.
    init(onWake: @escaping @Sendable () -> Void) {
        self.onWake = onWake
    }

    /// A sentence the reply is about to say: a wake phrase in it isn't the wearer's.
    func replySays(_ sentence: String) {
        lock.withLock { replySaid += " " + sentence.lowercased() }
    }

    /// Starts listening. False when Apple's on-device recognizer can't run (no permission, not supported): no
    /// barge-in for this reply.
    func start() -> Bool {
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.contextualStrings = ["Hey Meta", "OK Meta"]
        let task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            self.check(result.bestTranscription.formattedString)
        }
        lock.withLock {
            self.request = request
            self.task = task
        }
        return true
    }

    /// The glasses' microphone while the turn isn't listening: 16 kHz mono Int16.
    func append(_ chunk: [Int16]) {
        guard !chunk.isEmpty else { return }
        let request: SFSpeechAudioBufferRecognitionRequest? = lock.withLock {
            guard !heard else { return nil }
            samples += chunk.count
            // The loudest 20 ms frame, for the log's echo levels.
            var index = 0
            while index < chunk.count {
                let end = min(index + 320, chunk.count)
                var sum = 0.0
                for sample in chunk[index..<end] { sum += Double(sample) * Double(sample) }
                loudest = max(loudest, (sum / Double(end - index)).squareRoot())
                index = end
            }
            return self.request
        }
        guard let request, let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: AVAudioFrameCount(chunk.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(chunk.count)
        chunk.withUnsafeBufferPointer { source in
            buffer.int16ChannelData?[0].update(from: source.baseAddress!, count: chunk.count)
        }
        request.append(buffer)
    }

    /// Stops listening and says what it heard.
    func stop() -> Summary {
        let (task, request, summary): (SFSpeechRecognitionTask?, SFSpeechAudioBufferRecognitionRequest?, Summary) = lock.withLock {
            defer {
                self.task = nil
                self.request = nil
            }
            let db = samples > 0 && loudest > 0 ? 20 * log10(loudest / 32_768) : nil
            return (self.task, self.request, Summary(seconds: Double(samples) / 16_000, loudestDB: db, heard: heard, updates: updates))
        }
        request?.endAudio()
        task?.cancel()
        return summary
    }

    private func check(_ text: String) {
        lock.withLock { updates += 1 }
        guard text.lowercased().range(of: Self.phrase, options: .regularExpression) != nil else { return }
        let first: Bool = lock.withLock {
            // The reply saying it ("say Hey Meta, …") isn't the wearer.
            guard !heard, request != nil, replySaid.range(of: Self.phrase, options: .regularExpression) == nil else { return false }
            heard = true
            return true
        }
        guard first else { return }
        let onWake = self.onWake
        DispatchQueue.main.async { onWake() }
    }
}

/// The reply's audio on its way to the glasses, which a barge-in can cut short. After `cut`, the listening chime goes
/// instead and the stream ends normally, so the glasses finish within a moment and their follow-up listening opens.
/// The turn behind it still runs to its end, drained without being sent, so Claude's conversation stays whole for the
/// next request.
final class ReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var output: AsyncThrowingStream<[Int16], Error>.Continuation?
    private var isCut = false

    var wasCut: Bool { lock.withLock { isCut } }

    func wrap(_ source: AsyncThrowingStream<[Int16], Error>) -> AsyncThrowingStream<[Int16], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Int16], Error>.makeStream()
        lock.withLock { output = continuation }
        let task = Task { [weak self] in
            do {
                for try await chunk in source where self?.wasCut != true { continuation.yield(chunk) }
                if self?.wasCut != true { continuation.finish() }
            } catch {
                if self?.wasCut != true { continuation.finish(throwing: error) }
            }
        }
        continuation.onTermination = { termination in
            // The glasses' side went away (the turn stopped): stop the turn too. A cut finishes, which isn't this.
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }

    /// Ends the audio now with `tail` (the chime). False when it was cut already.
    @discardableResult
    func cut(then tail: [Int16]) -> Bool {
        let continuation: AsyncThrowingStream<[Int16], Error>.Continuation? = lock.withLock {
            guard !isCut else { return nil }
            isCut = true
            return output
        }
        guard let continuation else { return false }
        if !tail.isEmpty { continuation.yield(tail) }
        continuation.finish()
        return true
    }
}
