import ReGlassAssistant
import SwiftUI

/// The assistant's API keys: pasted once, kept in this iPhone's Keychain, shown only by their last four characters.
/// Adding, testing and removing all happen inline in the key's own row.
struct KeysView: View {
    @ObservedObject private var assistant = AssistantController.shared

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            List {
                if assistant.keysLocked {
                    Section {
                        AssistantStatusLine(tone: .warning, text: "Unlock your iPhone once since it restarted, so ReGlass can read its keys.")
                            .padding(.vertical, 4)
                    }
                    .listRowBackground(Theme.card)
                }
                Section {
                    KeyRow(key: .anthropic)
                } header: {
                    Text("Anthropic")
                } footer: {
                    Text("For Claude, the assistant's brain. Without it, ReGlass can't answer.")
                }
                .listRowBackground(Theme.card)
                Section {
                    KeyRow(key: .elevenLabs)
                } header: {
                    Text("ElevenLabs")
                } footer: {
                    ElevenLabsKeyFooter()
                }
                .listRowBackground(Theme.card)
                Section {
                    EmptyView()
                } footer: {
                    Text("Keys stay in this iPhone's Keychain, readable once you've unlocked it after a restart. They're never synced, backed up, logged or shown in full. Test makes one small call: Anthropic's is free, and ElevenLabs' uses six characters of quota once a voice ID is set.")
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { assistant.refreshKeys() }
    }
}

/// One key: its name and what it's for, "•••• abcd" when saved, and inline add, test, replace and remove. Also on the
/// Voice and Speech screen, where a cloud provider is chosen without its key.
struct KeyRow: View {
    let key: AssistantKey
    @ObservedObject private var assistant = AssistantController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24

    private enum Mode: Equatable {
        case idle, editing, confirmingRemove
    }

    @State private var mode: Mode = .idle
    @State private var draft = ""
    @State private var problem: String?
    @State private var saved = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Group {
                switch mode {
                case .idle: idle
                case .editing: editor
                case .confirmingRemove: removal
                }
            }
            .padding(.leading, typeSize.isAccessibilitySize ? 0 : iconColumn + 12)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
        .padding(.vertical, 6)
        .assistantAnimation(mode, reduceMotion: reduceMotion)
        .assistantAnimation(assistant.keyTests[key], reduceMotion: reduceMotion)
        .sensoryFeedback(.success, trigger: saved)
        .keyRowFeedback(test: assistant.keyTests[key], mode: mode == .confirmingRemove)
    }

    private var hint: String? { assistant.keyHints[key] }

    /// The system Paste button's fill: iOS draws its label white, so a warm grey that holds white in both appearances
    /// (6.8:1 in light, 6.4:1 in dark) and stays quieter than the copper Save beside it.
    private static let pasteTint = Theme.dynamic(0x5E5B54, 0x625F58)

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            RowSymbol(name: key.rowSymbol)
            Text(key.rowTitle)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 12)
            if let hint {
                Text(hint)
                    .font(.callout.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.opacity)
                    .accessibilityLabel("Saved, ending in \(String(hint.suffix(4)).map(String.init).joined(separator: " "))")
            } else {
                Text("Not added")
                    .font(.callout)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let test = testLine { test }
            PillRow {
                if hint == nil {
                    Button { begin(.editing) } label: { Label("Add Key", systemImage: "plus") }
                        .buttonStyle(CompactPillStyle(kind: .prominent))
                } else {
                    Button { assistant.testKey(key) } label: { Label("Test", systemImage: "checkmark.seal") }
                        .buttonStyle(CompactPillStyle())
                        .disabled(assistant.keyTests[key] == .testing)
                    Button { begin(.editing) } label: { Text("Replace") }
                        .buttonStyle(CompactPillStyle())
                    Button { begin(.confirmingRemove) } label: { Text("Remove") }
                        .buttonStyle(CompactPillStyle(kind: .destructive))
                }
            }
        }
    }

    private var testLine: AnyView? {
        switch assistant.keyTests[key] ?? .idle {
        case .idle: return nil
        case .testing: return AnyView(AssistantStatusLine(tone: .working, text: "Testing…"))
        case .passed(let message): return AnyView(AssistantStatusLine(tone: .good, text: message))
        case .failed(let message): return AnyView(AssistantStatusLine(tone: .warning, text: message))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            SecureField(key.pastePrompt, text: $draft)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .fieldSurface(focused: fieldFocused)
            Group {
                if let problem {
                    AssistantStatusLine(tone: .warning, text: problem)
                } else if !cleanedDraft.isEmpty {
                    Text("Ends in \(String(cleanedDraft.suffix(4)))")
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text("Shown here only by its last four characters.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            PillRow {
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        draft = strings.first ?? draft
                        problem = nil
                    }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .tint(Self.pasteTint)
                Button("Save", action: save)
                    .buttonStyle(CompactPillStyle(kind: .prominent))
                    .disabled(cleanedDraft.isEmpty)
                Button("Cancel") { end() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .onChange(of: draft) { _, _ in problem = nil }
    }

    private var removal: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(key.removalQuestion)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            PillRow {
                Button("Remove Key") {
                    assistant.removeKey(key)
                    end()
                }
                .buttonStyle(CompactPillStyle(kind: .destructive))
                Button("Cancel") { end() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
    }

    // MARK: Actions

    private var cleanedDraft: String { KeyStore.clean(draft) }

    private func begin(_ next: Mode) {
        draft = ""
        problem = nil
        mode = next
        if next == .editing { fieldFocused = true }
    }

    private func end() {
        fieldFocused = false
        draft = ""
        problem = nil
        mode = .idle
    }

    private func save() {
        guard !cleanedDraft.isEmpty else { return }
        if let reason = assistant.saveKey(draft, for: key) {
            problem = reason
            return
        }
        saved += 1
        end()
        assistant.testKey(key)
    }
}

/// The ElevenLabs key's footer: what the key is for, and a key problem only the owner can fix. A new or removed key
/// resets what ReGlass knew about the old one.
struct ElevenLabsKeyFooter: View {
    @ObservedObject private var speech = SpeechSettings.shared
    @ObservedObject private var assistant = AssistantController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Optional: for an ElevenLabs voice and ElevenLabs speech recognition, chosen in Voice and Speech. Without them, ReGlass speaks and listens on this iPhone.")
            if speech.choice == .elevenLabs, let problem = speech.keyProblem {
                Label {
                    Text(problem)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .onChange(of: assistant.keyHints[.elevenLabs]) { _, _ in
            speech.keyChanged()
            assistant.resetVoiceTest()
        }
    }
}

/// Each key's words on its row.
private extension AssistantKey {
    var rowSymbol: String {
        switch self {
        case .anthropic: return "text.bubble"
        case .elevenLabs: return "waveform"
        }
    }

    var rowTitle: String {
        switch self {
        case .anthropic: return "Claude key"
        case .elevenLabs: return "ElevenLabs key"
        }
    }

    var pastePrompt: String {
        switch self {
        case .anthropic: return "Paste your Anthropic key"
        case .elevenLabs: return "Paste your ElevenLabs key"
        }
    }

    var removalQuestion: String {
        switch self {
        case .anthropic: return "Remove the Claude key from this iPhone? ReGlass stops answering until you add one again."
        case .elevenLabs: return "Remove the ElevenLabs key from this iPhone? ReGlass speaks and listens on this iPhone until you add one again."
        }
    }
}

private extension View {
    /// A key row's haptics: a tick of success when a test passes, a buzz when it fails, and a warning tap as Remove
    /// asks to be confirmed. A save has its own success tap; a test that follows it only adds the outcome.
    func keyRowFeedback(test: AssistantController.KeyTest?, mode confirmingRemove: Bool) -> some View {
        sensoryFeedback(trigger: test) { _, now in
            switch now {
            case .passed?: return .success
            case .failed?: return .error
            default: return nil
            }
        }
        .sensoryFeedback(.warning, trigger: confirmingRemove) { _, now in now }
    }
}
