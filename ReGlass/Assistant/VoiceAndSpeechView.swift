import ReGlassAssistant
import SwiftUI

/// Settings → Assistant → Voice and speech: the voice that speaks ReGlass's replies and the recognizer that writes
/// down what the wearer says. Both are the iPhone's own (on-device) unless the owner chooses a cloud provider
/// (`VoiceProvider.all`, `SpeechProvider.all`). A cloud choice shows in place what it still needs (its key, added right
/// there; ElevenLabs' voice ID), and the voice has a Test that plays a short line. Choices apply from the next request.
struct VoiceAndSpeechView: View {
    @ObservedObject private var settings = SpeechSettings.shared
    @ObservedObject private var assistant = AssistantController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                voiceSection
                speechSection
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Voice and Speech")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .assistantAnimation(settings.voice, reduceMotion: reduceMotion)
        .assistantAnimation(settings.choice, reduceMotion: reduceMotion)
        .assistantAnimation(settings.status, reduceMotion: reduceMotion)
        .assistantAnimation(settings.checking, reduceMotion: reduceMotion)
        .assistantAnimation(assistant.keyHints, reduceMotion: reduceMotion)
        .sensoryFeedback(.selection, trigger: settings.voice)
        .sensoryFeedback(.selection, trigger: settings.choice)
        .onAppear { assistant.refreshKeys() }
        .onDisappear { assistant.resetVoiceTest() }
        .task { await settings.checkIfNeeded() }
        // A key added or removed here: forget what was known about the old one, as the Keys screen does.
        .onChange(of: assistant.keyHints[.elevenLabs]) { _, _ in
            settings.keyChanged()
            assistant.resetVoiceTest()
        }
    }

    // MARK: Voice

    private var voiceSection: some View {
        Section {
            ForEach(VoiceProvider.all) { provider in
                ProviderChoiceRow(title: provider.title, subtitle: provider.subtitle, onDevice: provider.key == nil,
                                  selected: settings.voice == provider) {
                    settings.voice = provider
                }
            }
            if let key = settings.voice.key, assistant.keyHints[key] == nil, !assistant.keysLocked {
                KeyRow(key: key)
                    .transition(insertion)
            }
            VoiceTestRow()
        } header: {
            Text("Voice")
        } footer: {
            Text(settings.voice.privacy)
        }
        .listRowBackground(Theme.card)
    }

    // MARK: Speech recognition

    private var speechSection: some View {
        Section {
            ForEach(SpeechProvider.all) { provider in
                ProviderChoiceRow(title: provider.title, subtitle: provider.subtitle, onDevice: provider.key == nil,
                                  selected: settings.choice == provider) {
                    settings.choice = provider
                }
            }
            if let missing = settings.choice.missing, !assistant.keysLocked {
                // The voice's section already holds the same key's row: one place to paste it is enough.
                if let key = settings.choice.key, settings.voice.key != key {
                    KeyRow(key: key)
                        .transition(insertion)
                } else {
                    AssistantStatusLine(tone: .info, text: "\(missing) Add it under Voice above.")
                        .padding(.vertical, 4)
                        .transition(insertion)
                }
            } else if settings.choice == .elevenLabs, settings.checking || settings.status != .unknown {
                SpeechKeyNotice()
                    .padding(.vertical, 4)
                    .transition(insertion)
            }
        } header: {
            Text("Speech recognition")
        } footer: {
            Text(settings.choice.privacy)
        }
        .listRowBackground(Theme.card)
    }

    private var insertion: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

/// A provider (or a Claude model, `ModelView`) as a row: its name, a few words on it, and a check when it's the one
/// chosen.
struct ProviderChoiceRow: View {
    let title: String
    let subtitle: String
    let onDevice: Bool
    let selected: Bool
    let select: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: select) {
            HStack(alignment: typeSize.isAccessibilitySize ? .firstTextBaseline : .center, spacing: 12) {
                RowSymbol(name: onDevice ? "iphone" : "cloud")
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .symbolEffect(.bounce, value: reduceMotion ? false : selected)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Under the voices: what the chosen one still needs, ElevenLabs' voice ID, and the Test that plays a short line.
private struct VoiceTestRow: View {
    @ObservedObject private var settings = SpeechSettings.shared
    @ObservedObject private var assistant = AssistantController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24
    @State private var draft = VoiceSettings.elevenLabsVoiceID
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if settings.voice == .elevenLabs { voiceIDField }
            if let missingLine { AssistantStatusLine(tone: .info, text: missingLine) }
            if let result { result }
            PillRow {
                Button(action: test) { Label("Test", systemImage: "play.fill") }
                    .buttonStyle(CompactPillStyle())
                    .disabled(assistant.voiceTest == .testing || !ready)
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, typeSize.isAccessibilitySize ? 0 : iconColumn + 12)
        .assistantAnimation(assistant.voiceTest, reduceMotion: reduceMotion)
        .sensoryFeedback(trigger: assistant.voiceTest) { _, now in
            switch now {
            case .passed: return .success
            case .failed: return .error
            default: return nil
            }
        }
        .onChange(of: focused) { _, now in
            if !now { save() }
        }
        .onChange(of: settings.elevenLabsVoiceID) { _, saved in
            if !focused { draft = saved }
        }
    }

    /// The chosen voice's key is missing: its own row above says so and takes it.
    private var keyMissing: Bool {
        guard let key = settings.voice.key else { return false }
        return assistant.keyHints[key] == nil && !assistant.keysLocked
    }

    /// ElevenLabs' field is empty (what's typed counts before it's saved).
    private var voiceIDMissing: Bool {
        settings.voice == .elevenLabs && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the chosen voice still needs, unless the key's own row above already shows it.
    private var missingLine: String? {
        if keyMissing { return nil }
        if settings.voice == .elevenLabs { return voiceIDMissing ? "Needs a voice ID." : nil }
        return settings.voice.missing
    }

    private var ready: Bool {
        if keyMissing || voiceIDMissing { return false }
        return settings.voice == .elevenLabs || settings.voice.missing == nil
    }

    private var voiceIDField: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Paste a voice ID from ElevenLabs", text: $draft)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .fieldSurface(focused: focused)
                .accessibilityLabel("ElevenLabs voice ID")
            Text("In ElevenLabs, open the voice and copy its ID.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var result: AnyView? {
        switch assistant.voiceTest {
        case .idle: return nil
        case .testing: return AnyView(AssistantStatusLine(tone: .working, text: "Testing…"))
        case .passed(let message): return AnyView(AssistantStatusLine(tone: .good, text: message))
        case .failed(let message): return AnyView(AssistantStatusLine(tone: .warning, text: message))
        }
    }

    private func save() {
        settings.setElevenLabsVoiceID(draft)
        draft = settings.elevenLabsVoiceID
    }

    private func test() {
        if settings.voice == .elevenLabs { save() }
        focused = false
        guard ready else { return }
        assistant.testVoice()
    }
}

/// One line on whether ElevenLabs can transcribe with the key: checking, works, or what the owner has to do.
private struct SpeechKeyNotice: View {
    @ObservedObject private var speech = SpeechSettings.shared

    var body: some View {
        if speech.checking, speech.status != .works {
            AssistantStatusLine(tone: .working, text: "Checking your ElevenLabs key…")
        } else {
            switch speech.status {
            case .unknown:
                EmptyView()
            case .works:
                AssistantStatusLine(tone: .good, text: "Works. ReGlass uses ElevenLabs for what you say.")
            case .noKey:
                AssistantStatusLine(tone: .info, text: "Add your ElevenLabs key first. Until then, ReGlass listens on this iPhone.")
            case .keyCannotTranscribe, .termsNotAccepted:
                VStack(alignment: .leading, spacing: 12) {
                    AssistantStatusLine(tone: .warning, text: speech.keyProblem ?? "")
                    PillRow {
                        Button {
                            Task { await speech.check() }
                        } label: {
                            Label("Check Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(CompactPillStyle())
                    }
                }
            case .quotaUsed:
                AssistantStatusLine(tone: .warning, text: "Your ElevenLabs quota is used up, so ReGlass listens on this iPhone for now.")
            }
        }
    }
}

/// Settings → Assistant's row for the voice and speech recognition.
struct VoiceAndSpeechSettingsRow: View {
    @ObservedObject private var settings = SpeechSettings.shared
    @ObservedObject private var assistant = AssistantController.shared

    var body: some View {
        NavigationLink {
            VoiceAndSpeechView()
        } label: {
            InfoRow(title: "Voice and speech", value: settings.summary, systemImage: "waveform.badge.mic")
        }
    }
}
