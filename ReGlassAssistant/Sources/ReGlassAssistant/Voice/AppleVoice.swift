@preconcurrency import AVFoundation
import Foundation

/// Apple's built-in voice, on the iPhone: the default voice (`VoiceProvider.iPhone`), and every other voice's fallback
/// when it can't speak. Renders with `AVSpeechSynthesizer.write` (no audio session, no playback, no network) and
/// converts to 24 kHz mono Int16.
public final class AppleVoice: Voice, @unchecked Sendable {
    public let name = "Apple"
    private let language: String

    public init(language: String = "en-US") {
        self.language = language
    }

    public func speak(_ sentences: AsyncStream<String>,
                      onRoute: @escaping @Sendable (VoiceRoute) -> Void) -> AsyncThrowingStream<[Int16], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                onRoute(.apple(reason: nil))
                let renderer = AppleRenderer(voice: Self.bestVoice(language: self.language))
                do {
                    for await sentence in sentences {
                        try Task.checkCancellation()
                        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        try await renderer.render(text) { continuation.yield($0) }
                    }
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) { AssistantLog.add("Apple voice failed (\(type(of: error)))") }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The best installed English voice: premium, then enhanced, then the default, never a novelty or personal voice.
    static func bestVoice(language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix(prefix)
                && !voice.voiceTraits.contains(.isNoveltyVoice)
                && !voice.voiceTraits.contains(.isPersonalVoice)
        }
        func rank(_ voice: AVSpeechSynthesisVoice) -> Int {
            var score = voice.quality.rawValue * 10
            if voice.language == language { score += 5 }
            return score
        }
        return candidates.max { rank($0) < rank($1) } ?? AVSpeechSynthesisVoice(language: language)
    }
}

/// One synthesizer for one reply; renders sentence by sentence.
private final class AppleRenderer: @unchecked Sendable {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    init(voice: AVSpeechSynthesisVoice?) {
        self.voice = voice
    }

    func render(_ text: String, emit: @escaping ([Int16]) -> Void) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        let converter = StreamingConverter(outputRate: PCM.replyRate)
        let once = Once()
        // A write that never ends (it happens) must not hang the reply.
        let limit = 3 + Double(text.count) * 0.12
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                once.set(continuation)
                DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                    once.resume(throwing: VoiceError.timedOut)
                }
                synthesizer.write(utterance) { buffer in
                    guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                    if pcm.frameLength == 0 {
                        if let tail = converter.flush() { emit(PCM.samples(tail)) }
                        once.resume()
                        return
                    }
                    if let converted = converter.convert(pcm) { emit(PCM.samples(converted)) }
                }
            }
        } onCancel: {
            synthesizer.stopSpeaking(at: .immediate)
            once.resume(throwing: CancellationError())
        }
    }
}

/// Resumes a continuation at most once, whichever of finish, timeout or cancel comes first.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var done = false

    func set(_ continuation: CheckedContinuation<Void, Error>) {
        let resumeNow: Bool = lock.withLock {
            if done { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume(throwing: CancellationError()) }
    }

    func resume(throwing error: Error? = nil) {
        let pending: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !done else { return nil }
            done = true
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        if let error { pending.resume(throwing: error) } else { pending.resume() }
    }
}
