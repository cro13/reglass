import SwiftUI
import UIKit

/// The live interpreter (experimental). Pick their language and start (or say "Hey Meta, interpreter, French" with the
/// Interpreter connector on), then follow along here: their words and the English translation, large and readable.
struct InterpreterView: View {
    @ObservedObject private var session = InterpreterSession.shared
    @ObservedObject private var glasses = GlassesController.shared
    @ObservedObject private var assistant = AssistantController.shared
    @ObservedObject private var registry = ConnectorRegistry.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAllLanguages = false
    /// Lines VoiceOver has already been told about, so each finished translation is announced once.
    @State private var announced: Set<UUID> = []

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            ScreenHeader(symbol: "character.bubble", title: "Live interpreter",
                                         text: "Someone speaks their language, and ReGlass tells you in English through "
                                            + "your glasses. Your own English isn't translated.")
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                ExperimentalMark()
                                Text("Needs your Claude and ElevenLabs keys.")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                        }
                        .entrance(0)
                        controls
                            .contentCard()
                            .entrance(1)
                        ForEach(session.lines) { line in
                            LineCard(line: line, language: session.language ?? session.chosen)
                                .id(line.id)
                                .transition(reduceMotion ? .opacity
                                            : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                          removal: .opacity))
                        }
                        if session.isRealTimeSession, session.isRunning, session.status != .ending {
                            HearingCard(text: session.partial)
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
                        }
                        if !session.isRunning, !session.lines.isEmpty {
                            Text("This conversation is saved in Chats.")
                                .font(.footnote)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 4)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                    .assistantAnimation(session.lines, reduceMotion: reduceMotion)
                    .assistantAnimation(session.status, reduceMotion: reduceMotion)
                    .assistantAnimation(showAllLanguages, reduceMotion: reduceMotion)
                    .assistantAnimation(session.partial.isEmpty, reduceMotion: reduceMotion)
                }
                .onChange(of: session.lines) { old, new in
                    announceFinished(new)
                    // Follow the conversation: a new line, or the newest one growing.
                    guard new.count != old.count || new.last?.translation != old.last?.translation else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        proxy.scrollTo(Self.bottom, anchor: .bottom)
                    }
                }
                .onChange(of: session.partial) { old, new in
                    // Real time: the words being heard grow at the bottom.
                    guard old.isEmpty != new.isEmpty || new.count / 40 != old.count / 40 else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                        proxy.scrollTo(Self.bottom, anchor: .bottom)
                    }
                }
            }
        }
        .navigationTitle("Interpreter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: session.lines.count)
        .sensoryFeedback(.selection, trigger: session.chosen)
        // Lines already on screen when it opens aren't news.
        .onAppear { announced.formUnion(session.lines.map(\.id)) }
    }

    private static let bottom = "bottom"

    /// Reads each translation to VoiceOver once it's finished (not while it streams in), in English, so someone who
    /// can't see the screen follows the conversation too.
    private func announceFinished(_ lines: [InterpreterSession.Line]) {
        for line in lines where line.done && !announced.contains(line.id) {
            announced.insert(line.id)
            if line.failed || line.translation.isEmpty {
                AccessibilityNotification.Announcement("This one didn't translate.").post()
                continue
            }
            let english = InterpreterLanguage.english
            let spoken = NSMutableAttributedString(string: "\(english.name): ")
            spoken.append(NSAttributedString(string: line.translation, attributes: [.accessibilitySpeechLanguage: english.code]))
            AccessibilityNotification.Announcement(spoken).post()
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        switch session.status {
        case .off:
            offControls
        case .waitingForWake:
            waitingControls
        default:
            VStack(alignment: .leading, spacing: 14) {
                LiveStatus(status: session.status, language: session.language ?? session.chosen,
                           realTime: session.isRealTimeSession)
                PillRow {
                    Button("Stop", systemImage: "stop.fill") { session.stop() }
                        .buttonStyle(CompactPillStyle(kind: .destructive))
                }
                Text("Or say \u{201C}stop interpreting\u{201D}. It also stops after five quiet minutes.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var offControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Their language")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            FlowLayout(spacing: 8) {
                ForEach(shownLanguages) { language in
                    let selected = language == session.chosen
                    Button(language.name) { session.chosen = language }
                        .buttonStyle(CompactPillStyle(kind: selected ? .prominent : .glass))
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Button(showAllLanguages ? "Fewer Languages" : "More Languages",
                       systemImage: showAllLanguages ? "chevron.up" : "ellipsis") {
                    showAllLanguages.toggle()
                }
                .buttonStyle(CompactPillStyle(kind: .glass))
            }
            InterpreterRealTimeSwitch(session: session)
            if let blocker {
                AssistantStatusLine(tone: .warning, text: blocker)
                if opensKeys(blocker) {
                    // The same way to the keys as Talk to ReGlass offers.
                    PillRow {
                        NavigationLink {
                            KeysView()
                        } label: {
                            Label("Open Keys", systemImage: "key.fill")
                        }
                        .buttonStyle(CompactPillStyle())
                    }
                }
            } else if let note = session.endNote {
                AssistantStatusLine(tone: .info, text: note)
            }
            PillRow {
                Button("Start", systemImage: "play.fill") {
                    Task {
                        await session.askForMicrophoneIfNeeded()
                        session.startFromScreen(session.chosen)
                    }
                }
                    .buttonStyle(CompactPillStyle(kind: .prominent))
                    .disabled(blocker != nil)
                if !session.lines.isEmpty {
                    Button("Clear", systemImage: "xmark") { session.clear() }
                        .buttonStyle(CompactPillStyle(kind: .glass))
                }
            }
            Text(startHint)
                .contentTransition(.opacity)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var waitingControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "waveform")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Now say \u{201C}Hey Meta\u{201D}")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("ReGlass says the interpreter is on, then listens for \(session.language?.name ?? session.chosen.name) and tells you in English.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            PillRow {
                Button("Cancel", systemImage: "xmark") { session.stop() }
                    .buttonStyle(CompactPillStyle(kind: .glass))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The common languages, plus the chosen one if it's further down the list; or all of them.
    private var shownLanguages: [InterpreterLanguage] {
        if showAllLanguages { return InterpreterLanguage.all }
        let common = InterpreterLanguage.common
        return common.contains(session.chosen) ? common : common + [session.chosen]
    }

    private static let noClaudeKey = "Add your Claude key first. ReGlass needs it to interpret."

    /// A key is missing (and the Keychain is readable, so adding one would help): Keys is one tap away.
    private func opensKeys(_ blocker: String) -> Bool {
        blocker == Self.noClaudeKey || blocker == InterpreterSession.noElevenLabsKey
    }

    /// Why Start can't work now, in one sentence. The key's words match Keys and Talk to ReGlass.
    private var blocker: String? {
        if !glasses.live.connection.isConnected { return "Connect your glasses to ReGlass first." }
        if !assistant.hasAnthropicKey {
            return assistant.keysLocked
                ? "Unlock your iPhone once since it restarted, so ReGlass can read its keys."
                : Self.noClaudeKey
        }
        if session.realTime, !assistant.available { return "ReGlass is still getting your glasses ready. Try again in a moment." }
        return InterpreterSession.blocker()
    }

    /// The Interpreter connector is on, so "Hey Meta, interpreter, French" starts it too.
    private var startsByVoice: Bool {
        guard let connector = registry.connector(id: InterpreterConnector.connectorID) else { return false }
        return registry.isOn(connector)
    }

    /// Under Start: how else it starts.
    private var startHint: String {
        let start = session.realTime ? "Start listens right away. " : ""
        guard startsByVoice else {
            return start + "To start it by voice too, turn on Interpreter in Connectors."
        }
        return start + "Or say \u{201C}Hey Meta, interpreter, \(session.chosen.name)\u{201D} any time."
    }
}

/// What the interpreter is doing, large, with a little motion: listening, translating, speaking.
private struct LiveStatus: View {
    let status: InterpreterSession.Status
    let language: InterpreterLanguage
    var realTime = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                if case .translating = status {
                    ArcSpinner(size: 30, lineWidth: 2.5)
                } else {
                    Image(systemName: symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.pulse, isActive: !reduceMotion && status == .listening)
                        .symbolEffect(.variableColor.iterative, isActive: !reduceMotion && isSpeaking)
                        .contentTransition(reduceMotion ? ContentTransition.opacity : ContentTransition.symbolEffect(.replace))
                }
            }
            .frame(width: 44, height: 44)
            .contentSurface(in: Circle())
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
                Text(realTime ? "\(language.name) to English · real time" : "\(language.name) to English")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var isSpeaking: Bool {
        if case .speaking = status { return true }
        return false
    }

    private var symbol: String {
        switch status {
        case .listening: return "ear"
        case .speaking: return "waveform"
        case .ending: return "stop.circle"
        default: return "character.bubble"
        }
    }

    private var title: String {
        switch status {
        case .starting: return "Starting"
        case .listening: return "Listening for \(language.name)"
        case .translating: return "Putting it into English"
        case .speaking: return realTime ? "Telling you in English, still listening" : "ReGlass is telling you in English"
        case .ending: return "Turning off"
        case .off, .waitingForWake: return ""
        }
    }
}

/// One thing the other person said: their words, and the voice's English translation, large and readable.
private struct LineCard: View {
    let line: InterpreterSession.Line
    let language: InterpreterLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "person.wave.2.fill")
                    .foregroundStyle(Theme.accent)
                Text("Them · \(language.name)")
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                if line.playing {
                    // Real time: the voice is saying this one now.
                    Image(systemName: "waveform")
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                        .accessibilityLabel("ReGlass is saying this")
                }
            }
            .font(.footnote.weight(.semibold))
            .assistantAnimation(line.playing, reduceMotion: reduceMotion)
            Text(line.original)
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if line.translation.isEmpty, !line.done {
                    ArcSpinner(size: 18, lineWidth: 1.8)
                        .alignmentGuide(.firstTextBaseline) { d in d.height * 0.8 }
                    Text("Translating…")
                        .font(.title3)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(line.translation)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(line.failed ? Theme.textSecondary : Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .contentTransition(.opacity)
                }
            }
            if line.failed, line.done {
                AssistantStatusLine(tone: .warning, text: "This one didn't translate.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 22, padding: 18)
        .accessibilityElement(children: .combine)
    }
}

/// Real time: the words being heard right now, before they become a line.
private struct HearingCard: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: text.isEmpty ? "ear" : "waveform")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse, isActive: !reduceMotion && text.isEmpty)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion && !text.isEmpty)
                .contentTransition(reduceMotion ? ContentTransition.opacity : ContentTransition.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(text.isEmpty ? "Listening\u{2026}" : text)
                .font(text.isEmpty ? .callout : .title3)
                .foregroundStyle(text.isEmpty ? Theme.textTertiary : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .contentCard(cornerRadius: 22, padding: 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text.isEmpty ? "Listening" : "Hearing: \(text)")
    }
}

/// Lays its children out in rows, wrapping to the next row when one is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            widest = max(widest, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            size.width = min(size.width, bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
