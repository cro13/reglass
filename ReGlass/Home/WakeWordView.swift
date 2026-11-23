import ReGlassKit
import SwiftUI
import UniformTypeIdentifiers

/// The wake word: what the glasses report having installed, how to start ReGlass, and the wake word sets kept on
/// this iPhone. The glasses wake on Meta's "Hey Meta", or with a touch and hold on the touchpad; both open a turn
/// that ReGlass answers. Only an install from the sets section changes anything on the glasses, and only after a
/// confirmation.
struct WakeWordView: View {
    @EnvironmentObject private var glasses: GlassesController
    @ObservedObject private var sets = WakeWordSets.shared
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24
    @State private var pickingSet = false
    @State private var signingIn = false

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            List {
                Section {
                    if let notice {
                        WakeWordNotice(notice: notice) { glasses.readWakeWord(force: true) }
                    }
                    InfoRow(title: "On your glasses", value: state.summary, systemImage: "waveform")
                    Toggle(isOn: $glasses.heyMetaEnabled) {
                        Label("Listen for \u{201C}Hey Meta\u{201D}", systemImage: "ear")
                            .foregroundStyle(Theme.ink)
                    }
                    .tint(Theme.accentFill)
                    .disabled(glasses.paired == nil || glasses.wakeWord.isInstalling)
                } footer: {
                    Text("Your glasses wake when they hear \u{201C}Hey Meta\u{201D}. You can also touch and hold the touchpad on the side of your glasses. Either way, ReGlass answers.")
                }
                .listRowBackground(Theme.card)
                Section {
                    WakeWordWay(symbol: "quote.bubble", title: "Say \u{201C}Hey Meta\u{201D}",
                                text: "Then tell ReGlass what you need.", iconColumn: iconColumn)
                    WakeWordWay(symbol: "hand.tap", title: "Touch and hold the touchpad",
                                text: "Speak once the glasses chime.", iconColumn: iconColumn)
                } header: {
                    Text("Talk to ReGlass")
                }
                .listRowBackground(Theme.card)
                WakeWordSetsSection(picking: $pickingSet, signingIn: $signingIn)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Wake Word")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(isPresented: $signingIn) { FactoryDownloadSignInView() }
        .fileImporter(isPresented: $pickingSet, allowedContentTypes: [.folder, .zip]) { sets.importSet($0) }
        .sensoryFeedback(.success, trigger: glasses.wakeWord.activity) { _, now in
            if case .installed = now { return true }
            return false
        }
        .sensoryFeedback(.warning, trigger: glasses.wakeWord.activity) { _, now in
            if case .failed = now { return true }
            return false
        }
        .sensoryFeedback(.success, trigger: sets.outcome) { _, now in
            if case .imported? = now { return true }
            return false
        }
        .onAppear { sets.reload() }
        .task(id: glasses.live.connection.isConnected) {
            if glasses.live.connection.isConnected { glasses.readWakeWord() }
        }
    }

    private var state: WakeWordState { glasses.wakeWord }

    private var notice: WakeWordNotice.Kind? {
        switch glasses.live.connection {
        case .connected: break
        case .connecting: return .working("Connecting to your glasses…")
        default: return .info("Connect your glasses to see their wake word.", "antenna.radiowaves.left.and.right.slash")
        }
        if state.isReading { return .working("Checking your glasses…") }
        if state.unavailable {
            return .info("ReGlass can't read the wake word on this firmware. Hey Meta still works.", "info.circle")
        }
        if let problem = state.readProblem { return .retry("ReGlass couldn't check your glasses. " + problem) }
        switch state.installed {
        case .incomplete?:
            return .attention("An earlier change to the wake word didn't finish, so it may not work.")
        case .unknown?:
            return .attention("ReGlass doesn't recognise the wake word files on your glasses, so it leaves them as they are.")
        case .empty?:
            return .attention("Your glasses have no wake word files, so \u{201C}Hey Meta\u{201D} can't wake them. Download the factory set below, then restore Hey Meta.")
        default:
            return nil
        }
    }
}

/// One way to start talking: a symbol, what to do, and a line on it.
private struct WakeWordWay: View {
    let symbol: String
    let title: String
    let text: String
    let iconColumn: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: iconColumn)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(Theme.ink)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One line about the state of things. Words always, an icon beside them, never colour alone.
private struct WakeWordNotice: View {
    enum Kind: Equatable {
        case working(String)
        case info(String, String)
        case attention(String)
        case retry(String)
    }

    let notice: Kind
    let retry: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            icon.frame(width: iconColumn)
            VStack(alignment: .leading, spacing: 6) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if case .retry = notice {
                    Button("Check Again", action: retry)
                        .buttonStyle(QuietButtonStyle())
                        .padding(.leading, -12)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch notice {
        case .working(let text), .info(let text, _), .attention(let text), .retry(let text): return text
        }
    }

    @ViewBuilder private var icon: some View {
        switch notice {
        case .working:
            ArcSpinner()
        case .info(_, let symbol):
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        case .attention, .retry:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        }
    }
}
