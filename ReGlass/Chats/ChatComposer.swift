import SwiftUI

/// Typing to ReGlass, for when talking to the glasses isn't an option: one field and one round button on a glass bar.
/// At the bottom of Chats it starts a new chat and opens it; at the bottom of a conversation it goes on with that one,
/// and the arrow becomes Stop while ReGlass answers there. Without a Claude key the field says so instead of sending.
struct ChatComposer: View {
    enum Purpose {
        /// A new chat, from the Chats screen.
        case newChat
        /// A reply in conversation `chat`.
        case reply(UUID)
    }

    let purpose: Purpose
    var composing: FocusState<Bool>.Binding
    /// A new chat began: its id, to open it.
    var started: (UUID) -> Void = { _ in }
    @ObservedObject private var assistant = AssistantController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @State private var sent = 0
    @State private var stopped = 0

    /// ReGlass is answering in this conversation (a new chat's answer shows in the chat it opened).
    private var answering: Bool {
        guard case .reply(let chat) = purpose else { return false }
        return assistant.chatReply?.chat == chat
    }

    private var canSend: Bool {
        assistant.hasAnthropicKey && !answering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused(composing)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(!assistant.hasAnthropicKey)
                .padding(.leading, 16)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
            button
        }
        .padding(4)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: sent)
        .onAppear { assistant.refreshKeys() }
    }

    private var placeholder: String {
        let isNew: Bool
        if case .reply = purpose { isNew = false } else { isNew = true }
        if assistant.keysLocked { return isNew ? "Unlock your iPhone to ask ReGlass" : "Unlock your iPhone to reply" }
        guard assistant.hasAnthropicKey else { return isNew ? "Add your Claude key to ask ReGlass" : "Add your Claude key to reply" }
        return isNew ? "Ask ReGlass" : "Reply to ReGlass"
    }

    private var button: some View {
        Button {
            if answering {
                assistant.stopChatReply()
                stopped += 1
            } else {
                send()
            }
        } label: {
            Image(systemName: answering ? "stop.fill" : "arrow.up")
                .font(.system(size: answering ? 13 : 16, weight: .bold))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                .foregroundStyle(answering ? Theme.ink : canSend ? Theme.onAccent : Theme.textTertiary)
                .frame(width: 36, height: 36)
                .background {
                    Circle().fill(answering ? AnyShapeStyle(Theme.track)
                                  : canSend ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(Theme.track))
                }
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.86))
        .disabled(!answering && !canSend)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7), value: canSend)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7), value: answering)
        // Stop is a press with an effect of its own: a firm tap as ReGlass stops talking.
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.8), trigger: stopped)
        .accessibilityLabel(answering ? "Stop" : "Send")
    }

    private func send() {
        guard canSend else { return }
        switch purpose {
        case .newChat:
            guard let chat = assistant.startChat(draft) else { return }
            started(chat)
        case .reply(let chat):
            assistant.reply(draft, in: chat)
        }
        draft = ""
        sent += 1
    }
}
