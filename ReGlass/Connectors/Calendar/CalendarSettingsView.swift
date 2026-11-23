import Combine
import EventKit
import SwiftUI
import UIKit

/// Calendar's options, shown as rows inside the connector screen's Options section: which calendars ReGlass reads (all
/// by default) and where new events go. Each is one row that opens in place; only one is open at a time.
struct CalendarSettingsView: View {
    @StateObject private var model: CalendarSettingsModel
    @State private var open: Panel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    private enum Panel {
        case reading, newEvents
    }

    init(store: CalStore) {
        _model = StateObject(wrappedValue: CalendarSettingsModel(store: store))
    }

    var body: some View {
        if model.access != .fullAccess {
            accessRow
        } else if !model.loaded {
            AssistantStatusLine(tone: .working, text: "Finding your calendars…")
                .padding(.vertical, 4)
        } else if model.calendars.isEmpty {
            AssistantStatusLine(tone: .warning, text: "ReGlass can't see any calendars right now. If your iPhone just restarted, unlock it once.")
                .padding(.vertical, 4)
        } else {
            readingRow
            if open == .reading {
                ForEach(model.calendars) { calendar in
                    Toggle(isOn: model.readBinding(calendar.id)) {
                        CalendarRow(calendar: calendar, caption: model.showSources ? calendar.source : nil,
                                    on: model.isRead(calendar.id))
                    }
                    .tint(Theme.accentFill)
                    .transition(rowTransition)
                }
            }
            if model.allOff {
                AssistantStatusLine(tone: .warning, text: "With every calendar off, ReGlass can't tell you what's on.")
                    .padding(.vertical, 4)
                    .transition(rowTransition)
            }
            newEventsRow
            if open == .newEvents {
                ChoiceRow(title: "Same as the Calendar app", caption: model.systemDefaultTitle.map { "Now \($0)" },
                          color: nil, selected: model.chosenDefault == nil) { choose(nil) }
                    .transition(rowTransition)
                ForEach(model.writable) { calendar in
                    ChoiceRow(title: calendar.title, caption: model.needsSource(calendar) ? calendar.source : nil,
                              color: calendar.color, selected: model.chosenDefault?.id == calendar.id) {
                        choose(calendar.id)
                    }
                    .transition(rowTransition)
                }
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private var accessRow: some View {
        switch model.access {
        case .denied, .restricted:
            VStack(alignment: .leading, spacing: 12) {
                AssistantStatusLine(tone: .quiet, text: "Turn on Calendars for ReGlass in iPhone Settings, then come back.")
                PillRow {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label("Open iPhone Settings", systemImage: "gear")
                    }
                    .buttonStyle(CompactPillStyle())
                }
            }
            .padding(.vertical, 4)
        default:
            AssistantStatusLine(tone: .quiet, text: "Once ReGlass can see your calendar, you can choose which calendars it reads and where new events go.")
                .padding(.vertical, 4)
        }
    }

    private var readingRow: some View {
        PanelRow(symbol: "eye", title: "Calendars ReGlass reads", caption: "Switch off any ReGlass should leave out",
                 value: model.readingSummary, open: open == .reading) { toggle(.reading) }
    }

    private var newEventsRow: some View {
        PanelRow(symbol: "calendar.badge.plus", title: "New events go to", caption: "When you don't name a calendar",
                 value: model.chosenDefault?.title ?? model.systemDefaultTitle ?? "Calendar's default",
                 open: open == .newEvents) { toggle(.newEvents) }
            .sensoryFeedback(.selection, trigger: model.defaultID)
    }

    // MARK: State

    private var spring: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    private func toggle(_ panel: Panel) {
        withAnimation(spring) { open = open == panel ? nil : panel }
    }

    private func choose(_ id: String?) {
        guard id != model.chosenDefault?.id else {
            withAnimation(spring) { open = nil }
            return
        }
        withAnimation(spring) { model.setDefault(id) }
        // Let the tick land before the choices fold away.
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(spring) { open = nil }
        }
    }
}

/// A row that opens more rows below it: symbol, title with a caption, the current value, and a chevron that turns.
private struct PanelRow: View {
    let symbol: String
    let title: String
    let caption: String
    let value: String
    let open: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        Button(action: action) {
            HStack(alignment: stacked ? .firstTextBaseline : .center, spacing: 12) {
                RowSymbol(name: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Theme.ink)
                    Text(stacked ? value : caption)
                        .font(stacked ? .callout : .footnote)
                        .foregroundStyle(stacked ? Theme.textSecondary : Theme.textTertiary)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 12)
                if !stacked {
                    // Two lines before it cuts off ("Work, Family and 3 more"); stacked under the title at
                    // accessibility sizes, all of it.
                    Text(value)
                        .font(.callout)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .contentTransition(.opacity)
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(open ? "Hides the calendars." : "Shows your calendars.")
        .assistantAnimation(value, reduceMotion: reduceMotion)
        .assistantAnimation(open, reduceMotion: reduceMotion)
    }
}

/// A calendar's toggle label: its colour, name and, when there are several accounts, the account. Switching it off
/// shrinks and dims the dot with a spring.
private struct CalendarRow: View {
    let calendar: CalCalendar
    let caption: String?
    let on: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 12

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(calendar.color)
                .frame(width: dot, height: dot)
                .scaleEffect(on || reduceMotion ? 1 : 0.7)
                .opacity(on ? 1 : 0.4)
                .frame(width: iconColumn)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.title)
                    .foregroundStyle(Theme.ink.opacity(on ? 1 : 0.6))
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
        .assistantAnimation(on, reduceMotion: reduceMotion)
    }
}

/// One calendar to choose for new events: a copper tick in the symbol column when it's the one, then its colour.
private struct ChoiceRow: View {
    let title: String
    let caption: String?
    let color: Color?
    let selected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var dot: CGFloat = 10

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: iconColumn)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected || reduceMotion ? 1 : 0.4)
                    .accessibilityHidden(true)
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: dot, height: dot)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Theme.ink)
                    if let caption {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .assistantAnimation(selected, reduceMotion: reduceMotion)
    }
}

private extension CalCalendar {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

/// The calendar list and the two choices, kept fresh: it reloads when Calendar's status changes (access allowed
/// on the connector screen or in the Settings app) and when the calendars change.
@MainActor
final class CalendarSettingsModel: ObservableObject {
    @Published private(set) var calendars: [CalCalendar] = []
    @Published private(set) var hidden: Set<String> = CalPreferences.hiddenIDs
    @Published private(set) var defaultID: String? = CalPreferences.defaultCalendarID
    @Published private(set) var systemDefaultID: String?
    @Published private(set) var loaded = false
    @Published private(set) var access = CalStore.access

    private let store: CalStore
    private var subscriptions: Set<AnyCancellable> = []

    init(store: CalStore) {
        self.store = store
        // The status publisher sends its current value first, which does the first load.
        ConnectorRegistry.shared.$statuses
            .map { $0[CalendarConnector.connectorID] }
            .removeDuplicates()
            .map { _ in () }
            .merge(with: NotificationCenter.default.publisher(for: .EKEventStoreChanged).map { _ in () })
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.reload() }
            }
            .store(in: &subscriptions)
    }

    var writable: [CalCalendar] { calendars.filter(\.writable) }
    var showSources: Bool { Set(calendars.map(\.source)).count > 1 }
    var allOff: Bool { !calendars.isEmpty && calendars.allSatisfy { hidden.contains($0.id) } }

    func isRead(_ id: String) -> Bool { !hidden.contains(id) }

    func reload() async {
        access = CalStore.access
        guard access == .fullAccess else {
            calendars = []
            loaded = false
            return
        }
        let snapshot = await store.calendarSnapshot()
        if snapshot.calendars != calendars { calendars = snapshot.calendars }
        systemDefaultID = snapshot.systemDefaultID
        loaded = true
    }

    // MARK: Which calendars ReGlass reads

    /// "All", "3 of 5", "None".
    var readingSummary: String {
        let reading = calendars.filter { !hidden.contains($0.id) }.count
        if reading == calendars.count { return "All" }
        if reading == 0 { return "None" }
        return "\(reading) of \(calendars.count)"
    }

    func readBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { [weak self] in self?.isRead(id) ?? true },
                set: { [weak self] on in self?.setRead(on, id: id) })
    }

    private func setRead(_ on: Bool, id: String) {
        if on { hidden.remove(id) } else { hidden.insert(id) }
        CalPreferences.hiddenIDs = hidden
        let reading = calendars.filter { !hidden.contains($0.id) }.count
        CalLog.add("reads \(reading) of \(calendars.count) calendars")
    }

    // MARK: Where new events go

    /// The calendar picked in ReGlass, if it still exists and takes new events. Nil: the Calendar app's default.
    var chosenDefault: CalCalendar? {
        guard let defaultID else { return nil }
        return writable.first { $0.id == defaultID }
    }

    var systemDefaultTitle: String? {
        guard let systemDefaultID else { return nil }
        return calendars.first { $0.id == systemDefaultID }?.title
    }

    /// Two writable calendars share the name: show the account too.
    func needsSource(_ calendar: CalCalendar) -> Bool {
        !calendar.source.isEmpty && writable.filter { $0.title == calendar.title }.count > 1
    }

    func setDefault(_ id: String?) {
        defaultID = id
        CalPreferences.defaultCalendarID = id
        CalLog.add(id == nil ? "new events follow the Calendar app's default" : "new events calendar chosen in ReGlass")
    }
}
