import SwiftUI

/// One connector, opened from Settings → Connectors: what it does, its switch and status (with the setup button when
/// it needs the owner), things to say, and the connector's own options if it has any.
struct ConnectorDetailView: View {
    let connector: any Connector
    @ObservedObject private var registry = ConnectorRegistry.shared
    @ObservedObject private var setup = ConnectorSetup.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Counts the times the owner starts scrolling, so an armed Delete in the options folds back (`optionsScrolled`).
    @State private var scrolls = 0

    var body: some View {
        let on = registry.isOn(connector)
        let status = registry.status(of: connector)
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            List {
                header(lit: on && status.isUsable)
                    .entrance(0)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                Section {
                    Toggle(isOn: ConnectorSwitch.binding(for: connector, reduceMotion: reduceMotion)) {
                        Label("Let ReGlass use \(connector.name)", systemImage: "power")
                    }
                    .tint(Theme.accentFill)
                    .entrance(1, distance: 10)
                    statusRow(on: on, status: status)
                        .entrance(2, distance: 10)
                } footer: {
                    Text("ReGlass uses \(connector.name) only when you ask, and only while it's on. Switch it off and ReGlass can't use it until you switch it back on.")
                }
                .listRowBackground(Theme.card)
                if !connector.examples.isEmpty {
                    Section {
                        ForEach(Array(connector.examples.enumerated()), id: \.offset) { index, example in
                            SpokenExample(text: example)
                                .entrance(3 + index, distance: 10)
                        }
                    } header: {
                        Text("Try saying")
                    }
                    .listRowBackground(Theme.card)
                }
                if let options = connector.settingsView() {
                    Section {
                        options
                    } header: {
                        Text("Options")
                    }
                    .listRowBackground(Theme.card)
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { scrolls += 1 }
            }
            .environment(\.optionsScrolled, scrolls)
        }
        // The header carries the name, so the bar shows only the way back. The title is still set: it names this
        // screen in the next one's back button and in the back button's history menu.
        .navigationTitle(connector.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear { registry.refresh() }
        .assistantAnimation(on, reduceMotion: reduceMotion)
        .assistantAnimation(status, reduceMotion: reduceMotion)
    }

    private var settingUp: Bool { setup.isRunning(connector) }

    // MARK: Parts

    /// The connector's symbol in light, its name and what it does. The light dims while ReGlass can't use it (off,
    /// or unavailable right now).
    private func header(lit: Bool) -> some View {
        VStack(spacing: 6) {
            ReGlassEmblem(symbol: connector.symbol, working: settingUp, size: 64)
                .saturation(lit ? 1 : 0)
                .opacity(lit ? 1 : 0.45)
                .padding(.bottom, -6)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(connector.name)
                    .displayFont(.title2)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                if connector.isExperimental { ExperimentalMark() }
            }
            Text(connector.summary)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
    }

    /// Where things stand, in words, with the setup button when the owner has something to do.
    @ViewBuilder private func statusRow(on: Bool, status: ConnectorStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if settingUp {
                    AssistantStatusLine(tone: .working, text: "Setting up…")
                } else if !on {
                    AssistantStatusLine(tone: .quiet, text: "Off. ReGlass leaves \(connector.name) alone.")
                } else {
                    switch status {
                    case .ready:
                        AssistantStatusLine(tone: .info, text: "Ready. ReGlass uses it when you ask.",
                                            symbol: "checkmark.circle.fill")
                    case .needsSetup(let message, _):
                        AssistantStatusLine(tone: .warning, text: message)
                    case .unavailable(let reason):
                        AssistantStatusLine(tone: .quiet, text: reason)
                    }
                }
            }
            .transition(.opacity)
            if on, case .needsSetup(_, let action) = status {
                ConnectorSetupButton(connector: connector, title: action, kind: .prominent)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }
}

/// Something to say to the glasses, set like your own words in Chats: ink, in quotes, beside a small marker with
/// you in it (a content surface, as it sits in a list row).
private struct SpokenExample: View {
    let text: String
    @ScaledMetric(relativeTo: .body) private var marker: CGFloat = 28

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "person.fill")
                .font(.system(size: marker * 0.4, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(width: marker, height: marker)
                .contentSurface(in: Circle())
                // Centre the marker on the first line of text.
                .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + marker * 0.16 }
                .accessibilityHidden(true)
            Text("\u{201C}\(text)\u{201D}")
                .font(.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Try saying: \(text)")
    }
}

// MARK: - Options scrolled

private struct OptionsScrolledKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    /// Goes up each time the owner starts scrolling a connector's screen. Options that ask once before deleting
    /// (alarms) fold their armed Delete back when it changes, as they do on another tap or when the
    /// screen goes.
    var optionsScrolled: Int {
        get { self[OptionsScrolledKey.self] }
        set { self[OptionsScrolledKey.self] = newValue }
    }
}
