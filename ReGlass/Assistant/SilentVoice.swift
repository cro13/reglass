import Foundation
import ReGlassAssistant

/// No voice at all: the sentences are taken and nothing is spoken, so nothing is sent to ElevenLabs either. For
/// replies typed in Chats while the iPhone's audio would come out of its own speaker; the answer shows as text.
struct SilentVoice: Voice {
    let name = "None (text only)"

    func speak(_ sentences: AsyncStream<String>,
               onRoute: @escaping @Sendable (VoiceRoute) -> Void) -> AsyncThrowingStream<[Int16], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for await _ in sentences {}
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
