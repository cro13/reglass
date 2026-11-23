import SwiftUI

// Settings → Connectors: everything the assistant can reach, grouped by where it works, each with an on/off switch.
// A row opens `ConnectorDetailView`. Connectors register themselves in `ConnectorRegistry`, so new ones simply appear.

// MARK: - Settings entry

/// The "Connectors" row in Settings → Assistant, with how many are on.
struct ConnectorsSettingsRow: View {
    @ObservedObject private var registry = ConnectorRegistry.shared

    var body: some View {
        NavigationLink {
            ConnectorsView()
        } label: {
            InfoRow(title: "Connectors", value: summary, systemImage: ConnectorsView.symbol)
        }
    }

    private var summary: String {
        guard !registry.connectors.isEmpty else { return "None yet" }
        let on = registry.onCount
        if on == 0 { return "All off" }
        let setUp = registry.waitingForSetUp
        return setUp > 0 ? "\(on) on · \(setUp) to set up" : "\(on) on"
    }
}

// MARK: - List

struct ConnectorsView: View {
    static let symbol = "point.3.connected.trianglepath.dotted"

    @ObservedObject private var registry = ConnectorRegistry.shared
    @ObservedObject private var setup = ConnectorSetup.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened: String?

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            List {
                Group {
                    if registry.connectors.isEmpty {
                        EmptyConnectors()
                    } else {
                        header
                    }
                }
                .entrance(0)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                ForEach(sections) { section in
                    Section {
                        ForEach(section.entries) { entry in
                            ConnectorRow(connector: entry.connector,
                                         entranceIndex: entry.index < 9 ? entry.index : nil) {
                                opened = entry.connector.id
                            }
                        }
                    } header: {
                        Text(section.group.title)
                    }
                    .listRowBackground(Theme.card)
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("ReGlass uses a connector only when you ask, and only while it's on. Switch one off and ReGlass can't use it until you switch it back on. Your choices stay on this iPhone.")
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Connectors")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .navigationDestination(item: $opened) { id in
            if let connector = registry.connector(id: id) {
                ConnectorDetailView(connector: connector)
            }
        }
        .onAppear { registry.refresh() }
        // Here rather than on the rows, so a setup that finishes while its detail screen is open taps once.
        .sensoryFeedback(.success, trigger: setup.successes)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 4) {
            ReGlassEmblem(symbol: Self.symbol, working: !setup.running.isEmpty, size: 56)
                .padding(.bottom, -4)
            Text(countLine)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
            Text(rightNowLine)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .assistantAnimation(countLine, reduceMotion: reduceMotion)
        .assistantAnimation(rightNowLine, reduceMotion: reduceMotion)
        .accessibilityElement(children: .combine)
    }

    /// "4 of 6 on", "All on", "All off"; a lone connector just says "On" or "Off".
    private var countLine: String {
        let total = registry.connectors.count
        let on = registry.onCount
        if total == 1 { return on == 1 ? "On" : "Off" }
        if on == total { return "All on" }
        if on == 0 { return "All off" }
        return "\(on) of \(total) on"
    }

    /// One sentence on what ReGlass can use right now, then what needs the owner.
    private var rightNowLine: String {
        let ready = registry.connectors.filter { registry.isOn($0) && registry.status(of: $0) == .ready }.map { $0.name }
        var parts: [String] = []
        if ready.isEmpty {
            parts.append(registry.onCount == 0 ? "Everything is switched off." : "Nothing is ready yet.")
        } else {
            parts.append("ReGlass can use \(Self.names(ready)) when you ask.")
        }
        switch registry.waitingForSetUp {
        case 0: break
        case 1: parts.append("One needs setting up.")
        case let count: parts.append("\(count) need setting up.")
        }
        return parts.joined(separator: " ")
    }

    /// "Timers, Reminders and Weather"; past four names, "Timers, Reminders, Calendar and 3 more".
    private static func names(_ names: [String]) -> String {
        if names.count > 4 {
            return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        }
        return ListFormatter.localizedString(byJoining: names)
    }

    // MARK: Sections

    private struct GroupSection: Identifiable {
        let group: ConnectorGroup
        let entries: [Entry]
        var id: Int { group.rawValue }
    }

    private struct Entry: Identifiable {
        /// Copied from the connector, because `Identifiable` reads it off the main actor.
        let id: String
        let connector: any Connector
        /// Position on screen, for the entrance (the header is 0).
        let index: Int
    }

    /// Connectors by group, in registry order, empty groups left out.
    private var sections: [GroupSection] {
        var index = 1
        return ConnectorGroup.allCases.compactMap { group in
            let members = registry.connectors.filter { $0.group == group }
            guard !members.isEmpty else { return nil }
            let entries = members.map { connector in
                defer { index += 1 }
                return Entry(id: connector.id, connector: connector, index: index)
            }
            return GroupSection(group: group, entries: entries)
        }
    }
}

// MARK: - Row

/// One connector: symbol, name, a status line and its switch. The name side opens the detail screen; the switch and
/// the setup pill are their own controls.
private struct ConnectorRow: View {
    let connector: any Connector
    /// Rows on screen when the list opens rise in one after another; rows scrolled to later just appear.
    let entranceIndex: Int?
    let open: () -> Void
    @ObservedObject private var registry = ConnectorRegistry.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24

    var body: some View {
        let on = registry.isOn(connector)
        let line = ConnectorLine(on: on, status: registry.status(of: connector), summary: connector.summary)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Button(action: open) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        RowSymbol(name: connector.symbol)
                            .saturation(on ? 1 : 0)
                            .opacity(on ? 1 : 0.5)
                            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : on)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(connector.name)
                                    .foregroundStyle(Theme.ink)
                                if connector.isExperimental { ExperimentalMark() }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            ConnectorLineView(line: line)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(CardPressStyle())
                .accessibilityLabel("\(connector.name)\(connector.isExperimental ? ", experimental" : ""). \(line.text)")
                .accessibilityHint("Shows what it can do")
                Toggle(isOn: ConnectorSwitch.binding(for: connector, reduceMotion: reduceMotion)) {
                    Text(connector.name)
                }
                .labelsHidden()
                .tint(Theme.accentFill)
            }
            if let action = line.setUpAction {
                ConnectorSetupButton(connector: connector, title: action)
                    .padding(.leading, iconColumn + 12)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 6)
        .assistantAnimation(line, reduceMotion: reduceMotion)
        .modifier(OptionalEntrance(index: entranceIndex))
    }
}

/// Before the first connector lands.
private struct EmptyConnectors: View {
    var body: some View {
        VStack(spacing: 8) {
            ReGlassEmblem(symbol: ConnectorsView.symbol, size: 56)
                .padding(.bottom, -2)
            Text("No connectors yet")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text("Connectors appear here as they're added. Each one is something ReGlass can do for you when you ask.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared pieces (list and detail)

/// What a connector's row says under its name: a point of light and a few words, plus the setup button's title
/// when the owner has something to do.
struct ConnectorLine: Equatable {
    enum Light: Equatable {
        /// ReGlass can use it now.
        case live
        /// It needs the owner first.
        case attention
        /// Off, or can't work right now.
        case dim
    }

    var light: Light
    var text: String
    var setUpAction: String?
    /// Words that matter less: shown fainter.
    var quiet = false

    init(on: Bool, status: ConnectorStatus, summary: String) {
        guard on else {
            self.init(light: .dim, text: "Off", quiet: true)
            return
        }
        switch status {
        case .ready:
            self.init(light: .live, text: Self.firstSentence(of: summary))
        case .needsSetup(let message, let action):
            self.init(light: .attention, text: message, setUpAction: action)
        case .unavailable(let reason):
            self.init(light: .dim, text: reason, quiet: true)
        }
    }

    private init(light: Light, text: String, setUpAction: String? = nil, quiet: Bool = false) {
        self.light = light
        self.text = text
        self.setUpAction = setUpAction
        self.quiet = quiet
    }

    /// "Timers that ring on your glasses. The voice tells you…" → "Timers that ring on your glasses."
    private static func firstSentence(of text: String) -> String {
        guard let end = text.range(of: ". ") else { return text }
        return String(text[..<end.lowerBound]) + "."
    }
}

/// A connector's status line in its row.
struct ConnectorLineView: View {
    let line: ConnectorLine
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ConnectorLight(light: line.light)
            Text(line.text)
                .font(.footnote)
                .foregroundStyle(line.quiet ? Theme.textTertiary : line.light == .attention ? Theme.ink : Theme.textSecondary)
                // Only the summary may be cut short: what to do, or why it can't work, is always read in full.
                .lineLimit(line.light == .live && !typeSize.isAccessibilitySize ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
    }
}

/// A small dot: copper when ReGlass can use the connector, amber when it needs the owner, dim otherwise. It always sits
/// beside words. When it lights up, a faint ring spreads from it once (not under Reduce Motion).
struct ConnectorLight: View {
    let light: ConnectorLine.Light
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var size: CGFloat = 7
    /// How far above the text's baseline the dot's centre sits.
    @ScaledMetric(relativeTo: .footnote) private var lift: CGFloat = 4
    @State private var flashes = 0

    private struct Ripple {
        var scale: CGFloat = 1
        var opacity: Double = 0
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .strokeBorder(Theme.accentFill, lineWidth: 1)
                    .keyframeAnimator(initialValue: Ripple(), trigger: flashes) { ring, ripple in
                        ring.scaleEffect(ripple.scale).opacity(ripple.opacity)
                    } keyframes: { _ in
                        KeyframeTrack(\.scale) {
                            MoveKeyframe(1)
                            CubicKeyframe(3, duration: 0.7)
                        }
                        KeyframeTrack(\.opacity) {
                            MoveKeyframe(0.8)
                            CubicKeyframe(0, duration: 0.7)
                        }
                    }
            }
            .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + lift }
            .onChange(of: light) { _, now in
                if now == .live, !reduceMotion { flashes += 1 }
            }
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch light {
        case .live: return Theme.accent
        case .attention: return Theme.warning
        case .dim: return Theme.control
        }
    }
}

/// A small copper "Experimental" mark beside an experimental feature's name: an outline, never a fill.
struct ExperimentalMark: View {
    var body: some View {
        Text("Experimental")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(Theme.accentFill, lineWidth: 1))
            .fixedSize()
    }
}

/// The on/off switch's binding: remembered by the registry, with the row's changes springing along.
enum ConnectorSwitch {
    @MainActor
    static func binding(for connector: any Connector, reduceMotion: Bool) -> Binding<Bool> {
        let registry = ConnectorRegistry.shared
        return Binding(
            get: { registry.isOn(connector) },
            set: { on in
                withAnimation(ConnectorSetup.animation(reduceMotion: reduceMotion)) {
                    registry.setOn(on, for: connector)
                }
            })
    }
}

/// The compact setup pill ("Allow Access"). While `setUp()` runs it shows a spinner and ignores further taps.
struct ConnectorSetupButton: View {
    let connector: any Connector
    let title: String
    var kind: CompactPillStyle.Kind = .glass
    @ObservedObject private var setup = ConnectorSetup.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let running = setup.isRunning(connector)
        Button {
            setup.start(connector, reduceMotion: reduceMotion)
        } label: {
            HStack(spacing: 8) {
                if running {
                    spinner
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                }
                Text(title)
            }
        }
        .buttonStyle(CompactPillStyle(kind: kind))
        .allowsHitTesting(!running)
        .accessibilityValue(running ? "Working" : "")
        .assistantAnimation(running, reduceMotion: reduceMotion)
    }

    @ViewBuilder private var spinner: some View {
        if kind == .prominent {
            // The copper arc disappears on a copper pill.
            ProgressView().controlSize(.small).tint(Theme.onAccent)
        } else {
            ArcSpinner(size: 14, lineWidth: 1.5)
        }
    }
}

/// Which connectors are being set up right now, shared by the list and the detail screen so both show the same
/// progress.
@MainActor
final class ConnectorSetup: ObservableObject {
    static let shared = ConnectorSetup()

    @Published private(set) var running: Set<String> = []
    /// Goes up each time a setup leaves its connector ready (for the success haptic).
    @Published private(set) var successes = 0

    private init() {}

    func isRunning(_ connector: any Connector) -> Bool { running.contains(connector.id) }

    func start(_ connector: any Connector, reduceMotion: Bool) {
        let id = connector.id
        guard !running.contains(id) else { return }
        running.insert(id)
        Task { @MainActor in
            await connector.setUp()
            let registry = ConnectorRegistry.shared
            withAnimation(Self.animation(reduceMotion: reduceMotion)) {
                registry.refresh()
                running.remove(id)
            }
            let ready = registry.status(of: connector) == .ready
            GlassesController.shared.log.add("Connectors: \(id) setup \(ready ? "done" : "not finished")")
            if ready { successes += 1 }
        }
    }

    /// The same spring as `assistantAnimation`, for changes made in code.
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)
    }
}

extension ConnectorRegistry {
    /// How many connectors are switched on.
    var onCount: Int { connectors.filter { isOn($0) }.count }

    /// How many switched-on connectors are waiting for the owner to set them up.
    var waitingForSetUp: Int {
        connectors.filter { connector in
            guard isOn(connector), case .needsSetup = status(of: connector) else { return false }
            return true
        }.count
    }
}

private struct OptionalEntrance: ViewModifier {
    let index: Int?

    func body(content: Content) -> some View {
        if let index { content.entrance(index, distance: 10) } else { content }
    }
}
