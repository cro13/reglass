import ReGlassAssistant
import SwiftUI

/// Type what you'd say to your glasses and hear the voice answer through the iPhone's audio (the glasses, when they're
/// connected as headphones). The request, any web searches and the spoken reply show here as they happen, and the
/// whole exchange is saved in Chats.
struct TalkToReGlassView: View {
    @ObservedObject private var assistant = AssistantController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @FocusState private var composing: Bool

    var body: some View {
        ZStack {
            ReGlassBackdrop()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 22) {
                        header
                            .entrance(0)
                        if !assistant.hasAnthropicKey {
                            missingKey
                                .entrance(1)
                        }
                        composer
                            .entrance(2)
                        if let turn = assistant.typed {
                            TypedTurnCard(turn: turn) { assistant.clearTyped() }
                                .id(turn.id)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .assistantAnimation(assistant.typed?.id, reduceMotion: reduceMotion)
                    .assistantAnimation(assistant.typed?.reply.count, reduceMotion: reduceMotion)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: assistant.typed?.reply.count) { _, _ in
                    guard let id = assistant.typed?.id else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle("Talk to ReGlass")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { assistant.refreshKeys() }
    }

    private var running: Bool { assistant.typed?.isRunning == true }

    // MARK: Parts

    private var header: some View {
        VStack(spacing: 6) {
            ReGlassEmblem(symbol: emblemSymbol, working: running, size: 64)
            Text("Type what you'd say to your glasses. ReGlass answers out loud through your iPhone's audio, or your glasses when they're connected as headphones.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var emblemSymbol: String {
        switch assistant.typed?.status {
        case .thinking?: return "ellipsis.bubble"
        case .speaking?: return "waveform"
        default: return "text.bubble"
        }
    }

    private var missingKey: some View {
        VStack(alignment: .leading, spacing: 12) {
            AssistantStatusLine(tone: .warning, text: assistant.keysLocked
                                ? "Unlock your iPhone once since it restarted, so ReGlass can read its keys."
                                : "Add your Claude key first. ReGlass needs it to answer.")
            if !assistant.keysLocked {
                NavigationLink {
                    KeysView()
                } label: {
                    Label("Open Keys", systemImage: "key.fill")
                }
                .buttonStyle(CompactPillStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 22, padding: 16)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your request")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
            TextField("What's the weather in Paris today?", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                // The placeholder is only an example; VoiceOver names the field by what it's for.
                .accessibilityLabel("Your request")
                .focused($composing)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 16)
                .padding(.vertical, 15)
                .fieldSurface(focused: composing)
            HStack {
                Text("Saved in Chats.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 12)
                if running {
                    Button { assistant.stopTyped() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(CompactPillStyle())
                        .transition(.opacity)
                } else {
                    Button(action: send) { Label("Ask", systemImage: "arrow.up") }
                        .buttonStyle(CompactPillStyle(kind: .prominent))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !assistant.hasAnthropicKey)
                        .transition(.opacity)
                }
            }
            .assistantAnimation(running, reduceMotion: reduceMotion)
        }
        .contentCard()
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, assistant.hasAnthropicKey, !running else { return }
        composing = false
        assistant.ask(text)
        draft = ""
    }
}

/// The request on a quiet rail, as in a conversation: you, what ReGlass did, what it said, and how it went.
private struct TypedTurnCard: View {
    let turn: AssistantController.TypedTurn
    let onClear: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var marker: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            step(symbol: "person.fill", user: true) {
                VStack(alignment: .leading, spacing: 4) {
                    caption("You")
                    Text(turn.request)
                        .font(.title3)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            ForEach(turn.actions) { action in
                step(symbol: "magnifyingglass", user: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(action.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = action.detail {
                            Text(detail)
                                .font(.footnote)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        ActionState(status: action.status)
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            if !turn.reply.isEmpty {
                step(symbol: "eyeglasses", user: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        caption("ReGlass")
                        // Each new sentence fades in; the ones already there hold still.
                        StreamingText(sentences: turn.reply)
                            .font(.body)
                            .foregroundStyle(Theme.ink.opacity(0.9))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
        .assistantAnimation(turn.actions, reduceMotion: reduceMotion)
        .assistantAnimation(turn.status, reduceMotion: reduceMotion)
        .sensoryFeedback(trigger: turn.status) { _, status in
            switch status {
            case .done: return .success
            case .failed: return .warning
            default: return nil
            }
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch turn.status {
            case .thinking:
                AssistantStatusLine(tone: .working, text: turn.actions.contains { $0.status == .running } ? "Searching…" : "Thinking…")
            case .speaking:
                AssistantStatusLine(tone: .info, text: "Speaking in \(voiceName)…", symbol: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            case .done(let summary):
                AssistantStatusLine(tone: .good, text: "\(summary) · \(voiceName)")
            case .failed(let reason):
                AssistantStatusLine(tone: .warning, text: reason)
            case .stopped:
                AssistantStatusLine(tone: .quiet, text: "Stopped")
            }
            if case .apple(let reason?) = turn.voice {
                Text("Apple's voice stood in: \(reason)")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let route = turn.route {
                Text(route)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            if !turn.isRunning {
                Button("Clear", action: onClear)
                    .buttonStyle(QuietButtonStyle())
                    .padding(.leading, -12)
            }
        }
        .padding(.top, 2)
    }

    private var voiceName: String { turn.voice?.label ?? "ReGlass" }

    private func step<Content: View>(symbol: String, user: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: marker * 0.4, weight: .semibold))
                .foregroundStyle(user ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.accent))
                .frame(width: marker, height: marker)
                .contentSurface(in: Circle())
                .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + marker * 0.14 }
                .accessibilityHidden(true)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.textTertiary)
    }
}

/// An action's state in words, the signal colour only on the symbol.
private struct ActionState: View {
    let status: ChatActionStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if status == .running {
                    ArcSpinner(size: 13, lineWidth: 1.5)
                        .transition(.opacity)
                } else {
                    // The spinner gives way to the outcome, which pops in once.
                    Image(systemName: status == .done ? "checkmark.circle.fill" : status == .failed ? "xmark.circle.fill" : "minus.circle.fill")
                        .foregroundStyle(status == .done ? Theme.good : status == .failed ? Theme.critical : Theme.textTertiary)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                }
            }
            Text(status.label)
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.opacity)
        }
        .font(.footnote.weight(.semibold))
        .animation(reduceMotion ? Theme.Motion.fade : .spring(response: 0.35, dampingFraction: 0.6), value: status)
    }
}
