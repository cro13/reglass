import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import WidgetKit

/// The Live Activity AlarmKit shows for a ReGlass alarm, in the ReGlass look (copper on warm paper): the snooze countdown,
/// a paused countdown, and the ringing alert, on the Lock Screen and in the Dynamic Island. Also a ReGlass reminder due
/// within the hour (`ReGlassAlarmMetadata.reminderTitle`): its title and the time left, with a bell and no Stop button
/// (the reminder stays in ReGlass; tick it off there). Where there's room it wears ReGlass's mark, as a notification
/// wears its app's icon; the compact Dynamic Island keeps the bare copper symbol, which reads on black at that size.
/// Where there's no room for the time (the minimal Island, or a compact one iOS keeps narrow), a copper ring
/// empties as the snooze or the reminder's time runs out, as the Timer app's does. The attributes type must match the
/// app's exactly (`ReGlassAlarmMetadata`, compiled into both targets), or the countdown shows blank.
struct ReGlassAlarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<ReGlassAlarmMetadata>.self) { context in
            AlarmLockScreenView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 10) {
                        ReGlassMark(badge: AlarmGlyph.symbol(mode: context.state.mode, reminder: context.attributes.isReminder),
                                  size: 34)
                        AlarmTitle(attributes: context.attributes, state: context.state)
                    }
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    AlarmTime(mode: context.state.mode)
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                        .foregroundStyle(ReGlassAlarmLook.accentText)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        AlarmProgress(mode: context.state.mode)
                        if context.state.mode.canStop, !context.attributes.isReminder {
                            StopButton(alarmID: context.state.alarmID)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                AlarmGlyph(mode: context.state.mode, reminder: context.attributes.isReminder)
            } compactTrailing: {
                AlarmCompactTrailing(mode: context.state.mode)
            } minimal: {
                AlarmRing(mode: context.state.mode,
                          symbol: AlarmGlyph.symbol(mode: context.state.mode, reminder: context.attributes.isReminder))
                    .frame(width: 24, height: 24)
            }
            .keylineTint(ReGlassAlarmLook.accentFill)
        }
    }
}

// MARK: Lock Screen

/// On the paper of the current appearance (light or dark, as the Lock Screen is), at 88 % so the wallpaper still
/// shows through a little, as before.
private struct AlarmLockScreenView: View {
    let attributes: AlarmAttributes<ReGlassAlarmMetadata>
    let state: AlarmPresentationState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
            .activityBackgroundTint(ReGlassAlarmLook.background(colorScheme).opacity(0.88))
            .activitySystemActionForegroundColor(ReGlassAlarmLook.actionText(colorScheme))
    }

    private var content: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                ReGlassMark(badge: AlarmGlyph.symbol(mode: state.mode, reminder: attributes.isReminder))
                AlarmTitle(attributes: attributes, state: state, titleLines: 2)
                Spacer(minLength: 8)
                AlarmTime(mode: state.mode)
                    .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    .foregroundStyle(ReGlassAlarmLook.accentText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            if attributes.isReminder {
                AlarmProgress(mode: state.mode)
            } else if state.mode.canStop {
                HStack(spacing: 12) {
                    AlarmProgress(mode: state.mode)
                    StopButton(alarmID: state.alarmID)
                }
            }
        }
        .padding(14)   // the Lock Screen's standard margin
    }
}

// MARK: Parts

/// The alarm symbol in copper, for the compact Dynamic Island (and, small, inside the minimal one's ring): ringing
/// waves while it alerts, "zzz" while snoozed. A reminder shows a bell.
private struct AlarmGlyph: View {
    let mode: AlarmPresentationState.Mode
    var reminder = false

    var body: some View {
        Image(systemName: Self.symbol(mode: mode, reminder: reminder))
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ReGlassAlarmLook.accentText)
            .padding(4)
            .accessibilityHidden(true)
    }

    static func symbol(mode: AlarmPresentationState.Mode, reminder: Bool) -> String {
        if reminder {
            switch mode {
            case .alert: return "bell.and.waves.left.and.right.fill"
            case .paused: return "pause.fill"
            default: return "bell.fill"
            }
        }
        switch mode {
        case .alert: return "alarm.waves.left.and.right.fill"
        case .countdown: return "zzz"
        case .paused: return "pause.fill"
        @unknown default: return "alarm.fill"
        }
    }
}

/// The alarm's title (its label, or "Alarm") over ReGlass's name and what it's doing now ("ReGlass · Snoozed"); a
/// reminder's title over "ReGlass · Reminder". The Lock Screen gives the title two lines, so a reminder's words aren't
/// cut short beside the big countdown; the Island keeps one.
private struct AlarmTitle: View {
    let attributes: AlarmAttributes<ReGlassAlarmMetadata>
    let state: AlarmPresentationState
    var titleLines = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let reminder = attributes.metadata?.reminderTitle {
                    Text(reminder)
                } else {
                    Text(attributes.presentation.alert.title)
                }
            }
            .font(.headline)
            .foregroundStyle(ReGlassAlarmLook.ink)
            .lineLimit(titleLines)
            .fixedSize(horizontal: false, vertical: true)
            Text("ReGlass \u{00B7} " + (attributes.isReminder ? state.mode.reminderWord : state.mode.word))
                .font(.subheadline)
                .foregroundStyle(ReGlassAlarmLook.secondary)
                .lineLimit(1)
        }
    }
}

/// The live number: time left while snoozed (counting down by itself), the frozen time left while paused, and the
/// alarm's time while it rings. Rounded, tabular digits.
private struct AlarmTime: View {
    let mode: AlarmPresentationState.Mode

    var body: some View {
        Group {
            switch mode {
            case .countdown(let countdown):
                Text(timerInterval: countdown.startDate...max(countdown.startDate, countdown.fireDate), countsDown: true)
            case .paused(let paused):
                let left = max(0, paused.totalCountdownDuration - paused.previouslyElapsedDuration)
                Text(Duration.seconds(left).formatted(.time(pattern: left >= 3600 ? .hourMinuteSecond : .minuteSecond)))
            case .alert(let alert):
                Text(Self.clock(alert.time))
            @unknown default:
                Text("")
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }

    private static func clock(_ time: Alarm.Schedule.Relative.Time) -> String {
        var components = DateComponents()
        components.hour = time.hour
        components.minute = time.minute
        guard let date = Calendar.current.date(from: components) else {
            return String(format: "%02d:%02d", time.hour, time.minute)
        }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// The compact Island's right side: the time, or the ring where iOS keeps the Island narrow (landscape, or two
/// activities at once) and a time wouldn't fit its 28 pt.
private struct AlarmCompactTrailing: View {
    let mode: AlarmPresentationState.Mode
    @Environment(\.isDynamicIslandLimitedInWidth) private var limited

    var body: some View {
        if limited {
            AlarmRing(mode: mode)
                .frame(width: 20, height: 20)
                .padding(2)
        } else {
            AlarmTime(mode: mode)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .foregroundStyle(ReGlassAlarmLook.accentText)
                .frame(maxWidth: 52)
        }
    }
}

/// Live time left at a glance where words don't fit: a copper ring that empties by itself as the snooze or the
/// reminder's countdown runs out, a dimmer still ring while paused, and a full ring while it rings. `symbol` sits in
/// the middle when there's room for it (the minimal Island).
private struct AlarmRing: View {
    let mode: AlarmPresentationState.Mode
    var symbol: String?

    var body: some View {
        ZStack {
            switch mode {
            case .countdown(let countdown):
                // iOS runs a timer-driven ring itself, so it keeps emptying while ReGlass is asleep.
                ProgressView(timerInterval: countdown.startDate...max(countdown.startDate, countdown.fireDate), countsDown: true) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .tint(ReGlassAlarmLook.fill)
            case .paused(let paused):
                let total = max(paused.totalCountdownDuration, 1)
                ring(max(0, total - paused.previouslyElapsedDuration) / total, opacity: 0.75)
            default:
                ring(1, opacity: 1)
            }
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(ReGlassAlarmLook.accentText)
                    .accessibilityHidden(true)
            }
        }
        // The timer ring brings its own live value; the label says what it is.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    /// A narrow Island's ring: a faint track and a copper arc from the top.
    private func ring(_ fraction: Double, opacity: Double) -> some View {
        ZStack {
            Circle()
                .stroke(ReGlassAlarmLook.track, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(ReGlassAlarmLook.fill.opacity(opacity), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.25)
    }

    private var label: String {
        switch mode {
        case .countdown: return "Time left"
        case .paused: return "Paused"
        case .alert: return "Ringing"
        @unknown default: return ""
        }
    }
}

/// A thin copper bar that empties as the snooze runs out (a still bar while paused).
private struct AlarmProgress: View {
    let mode: AlarmPresentationState.Mode

    var body: some View {
        switch mode {
        case .countdown(let countdown):
            ProgressView(timerInterval: countdown.startDate...max(countdown.startDate, countdown.fireDate), countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(ReGlassAlarmLook.fill)
        case .paused(let paused):
            let total = max(paused.totalCountdownDuration, 1)
            ProgressView(value: max(0, total - paused.previouslyElapsedDuration), total: total)
                .progressViewStyle(.linear)
                .tint(ReGlassAlarmLook.fill.opacity(0.75))
        default:
            EmptyView()
        }
    }
}

/// Stops a snoozed (or paused) alarm: an ink capsule on a faint fill that hugs its label, at least 44 pt tall so it's an
/// easy tap on the Lock Screen.
private struct StopButton: View {
    let alarmID: UUID

    var body: some View {
        Button(intent: StopReGlassAlarmIntent(alarmID: alarmID)) {
            Label("Stop", systemImage: "xmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ReGlassAlarmLook.ink)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(Capsule().fill(ReGlassAlarmLook.track))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private extension AlarmPresentationState.Mode {
    var word: String {
        switch self {
        case .alert: return "Ringing"
        case .countdown: return "Snoozed"
        case .paused: return "Paused"
        @unknown default: return "Alarm"
        }
    }

    var reminderWord: String {
        switch self {
        case .alert: return "Reminder, now"
        case .paused: return "Reminder, paused"
        default: return "Reminder"
        }
    }

    var canStop: Bool {
        switch self {
        case .countdown, .paused: return true
        default: return false
        }
    }
}

private extension AlarmAttributes where Metadata == ReGlassAlarmMetadata {
    /// A ReGlass reminder's countdown rather than an alarm.
    var isReminder: Bool { metadata?.isReminder ?? false }
}
