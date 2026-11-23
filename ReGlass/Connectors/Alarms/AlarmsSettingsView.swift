import AlarmKit
import SwiftUI
import UIKit

/// Alarms' options, shown as rows inside the connector screen's Options section: where things stand with iOS's
/// permission, then every alarm ReGlass set, soonest first, each with a delete that asks once (the bin turns into a
/// red "Delete" until it's used or let go). Alarms appear and leave with a spring as they're set, ring or get cancelled.
struct AlarmsSettingsView: View {
    @ObservedObject var service: AlarmService

    @State private var shown: [AlarmService.Entry] = []
    @State private var arming: UUID?
    @State private var deletions = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.optionsScrolled) private var scrolled
    @Environment(\.openURL) private var openURL

    var body: some View {
        permissionRow
            .onAppear {
                shown = service.entries
                _ = service.currentEntries()
            }
            .onReceive(service.$entries) { fresh in
                guard fresh != shown else { return }
                withAnimation(spring) { shown = fresh }
            }
            .sensoryFeedback(.impact(weight: .medium, intensity: 0.7), trigger: deletions)
            .onChange(of: scrolled) { _, _ in disarm() }
        if service.authorization == .authorized {
            ForEach(shown) { entry in
                AlarmRow(entry: entry, armed: arming == entry.id, onBin: { arm(entry.id) }, onDisarm: disarm,
                         onDelete: { delete(entry.id) })
                    .transition(rowTransition)
            }
            AssistantStatusLine(tone: .quiet,
                                text: "They ring on this iPhone even when ReGlass is closed. If ReGlass is ever locked or hidden with Face ID, iOS keeps its alarms silent.",
                                symbol: "info.circle")
                .padding(.vertical, 4)
        }
    }

    // MARK: Rows

    @ViewBuilder private var permissionRow: some View {
        switch service.authorization {
        case .authorized:
            HStack(spacing: 12) {
                RowSymbol(name: "alarm")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alarms ReGlass set")
                        .foregroundStyle(Theme.ink)
                    Text(shown.isEmpty ? "Say \u{201C}Hey Meta, wake me at seven\u{201D}" : "Only these: Clock app alarms stay in Clock")
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: 12)
                Text(shown.isEmpty ? "None" : "\(shown.count)")
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .assistantAnimation(shown.count, reduceMotion: reduceMotion)
        case .denied:
            VStack(alignment: .leading, spacing: 12) {
                AssistantStatusLine(tone: .quiet, text: "Turn on Alarms for ReGlass in iPhone Settings, then come back.")
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
            AssistantStatusLine(tone: .quiet, text: "Once ReGlass may set alarms, the ones you ask for show up here.")
                .padding(.vertical, 4)
        }
    }

    // MARK: State

    private var spring: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.86)
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    /// The bin turns into a red Delete, which stays until it's used, another row's bin or the row itself is tapped,
    /// the screen scrolls, or the screen goes: never on a timer, which could fold it away under a slow finger or
    /// while VoiceOver reads it.
    private func arm(_ id: UUID) {
        withAnimation(spring) { arming = id }
    }

    private func disarm() {
        guard arming != nil else { return }
        withAnimation(spring) { arming = nil }
    }

    private func delete(_ id: UUID) {
        arming = nil
        let done = service.cancel([id])
        if !done.isEmpty { deletions += 1 }
        withAnimation(spring) { shown = service.entries }
    }
}

/// The bin under the finger: it dims and gives a little, so the tap is seen before Delete appears. Only the dim
/// without the give under Reduce Motion.
private struct BinPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .animation(configuration.isPressed ? .spring(response: 0.18, dampingFraction: 0.8)
                                               : .spring(response: 0.4, dampingFraction: 0.52),
                       value: configuration.isPressed)
    }
}

/// One alarm: its time in the rounded face, when it rings (and what for), and a bin that asks once.
private struct AlarmRow: View {
    let entry: AlarmService.Entry
    let armed: Bool
    let onBin: () -> Void
    let onDisarm: () -> Void
    let onDelete: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var binSize: CGFloat = 44

    var body: some View {
        let clock = AlarmClock()
        let time = AlarmTools.chatTime(entry, clock: clock)
        let when = AlarmTools.chatWhen(entry, clock: clock)
        let caption = [when, entry.label.map(AlarmTools.displayLabel)].compactMap { $0 }.joined(separator: " · ")
        HStack(spacing: 12) {
            RowSymbol(name: symbol)
                .symbolEffect(.bounce, options: .repeating, isActive: entry.state == .ringing && !reduceMotion)
            VStack(alignment: .leading, spacing: 2) {
                Text(time)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(entry.state == .set ? Theme.textTertiary : Theme.accent)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if armed { onDisarm() } }
            Spacer(minLength: 8)
            if armed {
                Button(role: .destructive, action: onDelete) {
                    Text("Delete")
                }
                .buttonStyle(CompactPillStyle(kind: .destructive))
                .transition(reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity))
            } else {
                Button(action: onBin) {
                    Image(systemName: "trash")
                        .font(.body)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: binSize, height: binSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BinPressStyle())
                .accessibilityLabel("Delete Alarm")
                .transition(.opacity)
            }
        }
        .padding(.vertical, 2)
        .assistantAnimation(armed, reduceMotion: reduceMotion)
        .assistantAnimation(entry, reduceMotion: reduceMotion)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .tint(Theme.Swipe.delete)
        }
        .accessibilityAction(named: "Delete Alarm", onDelete)
    }

    private var symbol: String {
        switch entry.state {
        case .ringing: return "alarm.waves.left.and.right"
        case .snoozed: return "zzz"
        case .paused: return "pause.circle"
        case .set: return entry.repeats ? "repeat" : "alarm"
        }
    }
}
