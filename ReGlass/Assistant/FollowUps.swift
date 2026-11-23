import CallKit
import Foundation
import ReGlassAssistant

/// The follow-up window's rules: after every reply the glasses listen 5 s for more
/// without the wake word, marked by a soft chime at the end of the reply. A follow-up continues the same chat and the
/// same Claude conversation; a new wake word starts a fresh one.
enum FollowUps {
    /// How long the window waits for the wearer to start speaking, from confirmed playback.
    static let window: TimeInterval = 5
    /// No-wake follow-ups in a row before the wake word is needed again (a radio left on can't run up a bill).
    static let maxInARow = 10

    /// Whole-utterance closers. "Thanks, and what about Sunday?" is not one.
    enum Closing: Equatable {
        /// The assistant says "You're welcome." and the window closes.
        case thanks
        /// The window closes without a word.
        case done
    }

    static func closing(_ request: String) -> Closing? {
        let text = normalized(request)
        if thanks.contains(text) { return .thanks }
        if done.contains(text) { return .done }
        return nil
    }

    /// Lowercased letters, apostrophes and single spaces only.
    private static func normalized(_ request: String) -> String {
        request.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "' ")).inverted)
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static let thanks: Set<String> = [
        "thanks", "thank you", "thank you very much", "thanks a lot", "okay thanks", "ok thanks", "okay thank you",
        "ok thank you", "thanks that's all", "thank you that's all", "great thanks", "perfect thanks", "cheers",
    ]

    private static let done: Set<String> = [
        "that's all", "that's it", "stop", "cancel", "goodbye", "bye", "bye bye", "never mind", "nevermind",
        "i'm good", "im good", "no thanks", "no thank you", "no", "nope", "nothing", "all good", "okay", "ok",
        // Tap to stop's voice fallback ("Hey Meta, stop" over a reply, or in a follow-up window).
        "stop it", "stop stop", "stop talking", "ok stop", "okay stop", "please stop", "stop please", "be quiet",
        "quiet", "shut up", "enough", "that's enough", "hush", "silence", "cancel that", "forget it",
    ]

    /// Words that start a media command: no window after those, so music isn't interrupted (as Meta's glasses do).
    private static let mediaVerbs: Set<String> = [
        "play", "pause", "resume", "stop", "skip", "next", "previous", "shuffle", "repeat", "louder", "quieter",
        "volume", "mute", "unmute",
    ]

    /// Tools whose use means the request was a media command.
    static let mediaTools: Set<String> = ["play_music", "music_control"]

    static func isMediaCommand(_ request: String, route: EffortRouter.Decision?) -> Bool {
        guard route?.route == .quick, route?.reason == "command" else { return false }
        let words = request.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty && !["ok", "okay", "hey", "meta", "reglass", "please", "can", "you", "just"].contains($0) }
        return mediaVerbs.contains(words.first ?? "")
    }

    private static let calls = CXCallObserver()

    /// A phone call is ringing or going on: no window (the glasses would hear the call).
    static var onACall: Bool {
        calls.calls.contains { !$0.hasEnded }
    }
}

/// What one exchange did, as far as the follow-up decision needs to know. Updated from the turn's events.
@MainActor
final class ExchangeState {
    var route: EffortRouter.Decision?
    var usedMediaTool = false
}

/// The listening cue: a soft two-note chime appended to a reply that opens a follow-up window, so it plays exactly as
/// the window opens. 24 kHz mono, about 0.4 s including a short pause after the reply.
enum ListeningChime {
    static let samples: [Int16] = make()

    private static func make() -> [Int16] {
        let rate = 24_000.0
        var out = [Int16](repeating: 0, count: Int(0.15 * rate))
        func note(_ frequency: Double, seconds: Double, level: Double) {
            let count = Int(seconds * rate)
            for index in 0..<count {
                let t = Double(index) / rate
                let attack = min(1, t / 0.008)
                let envelope = attack * exp(-t * 14)
                let value = level * envelope * (sin(2 * .pi * frequency * t) + 0.25 * sin(4 * .pi * frequency * t))
                out.append(Int16(clamping: Int((value * 32767).rounded())))
            }
        }
        note(880, seconds: 0.11, level: 0.16)
        note(1318.5, seconds: 0.17, level: 0.14)
        out.append(contentsOf: [Int16](repeating: 0, count: Int(0.06 * rate)))
        return out
    }

    /// `audio`, then the chime if `wanted()` says so once the reply has finished. Cancelling the result cancels
    /// `audio` (and so the turn behind it).
    static func appended(to audio: AsyncThrowingStream<[Int16], Error>,
                         when wanted: @escaping @Sendable () async -> Bool) -> AsyncThrowingStream<[Int16], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Int16], Error>.makeStream()
        let task = Task {
            do {
                for try await chunk in audio { continuation.yield(chunk) }
                if Task.isCancelled { throw CancellationError() }
                if await wanted() { continuation.yield(samples) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return stream
    }
}
