import ReGlassKit
import SwiftUI

/// The firmware update, full screen, from the moment it starts until its outcome is dismissed. An update takes about
/// 20 minutes, so this is a place to leave the phone: ReGlass keeps the screen on by itself and shows where the
/// update is, how much has reached the glasses and how long is left. Stop is offered only until the glasses start
/// installing; from then on they finish on their own.
struct FirmwareUpdateCover: View {
    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmingStop = false

    private var state: FirmwareUpdateState { glasses.firmwareUpdate }

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: 1)
            if let run = state.run {
                running(run)
                    .transition(.opacity)
            } else if let outcome = state.outcome {
                finished(outcome)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(Theme.Motion.arrive(reduceMotion: reduceMotion), value: state.run == nil)
        .sensoryFeedback(.success, trigger: state.outcome) { _, now in
            switch now {
            case .updated?, .rehearsed?: return true
            default: return false
            }
        }
        .sensoryFeedback(.warning, trigger: state.outcome) { _, now in
            if case .failed? = now { return true }
            return false
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: state.run?.stage) { old, new in
            old != nil && new != nil && old != new
        }
        .onChange(of: state.run?.stage) { _, stage in
            if let stage, stage >= .installing { confirmingStop = false }
        }
    }

    // MARK: Running

    private func running(_ run: FirmwareUpdateState.Run) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 6) {
                    Text(run.rehearsal ? "Rehearsing the update" : "Updating your glasses")
                        .displayFont(.title2)
                        .foregroundStyle(Theme.ink)
                    Text("Version \(run.target)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
                .multilineTextAlignment(.center)
                .entrance(0)

                FirmwareRing(run: run)
                    .entrance(1)

                VStack(spacing: 6) {
                    Text(headline(run))
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .contentTransition(.opacity)
                    TimelineView(.periodic(from: .now, by: 5)) { context in
                        Text(detail(run, now: context.date))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .contentTransition(reduceMotion ? .opacity : .numericText())
                    }
                }
                .multilineTextAlignment(.center)
                .animation(Theme.Motion.inline(reduceMotion: reduceMotion), value: run.stage)
                .entrance(2)

                stages(run)
                    .entrance(3)

                keepOpenNote(run)
                    .entrance(4)

                if run.stage < .installing {
                    stopControl
                        .entrance(5)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 36)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityElement(children: .contain)
    }

    private func headline(_ run: FirmwareUpdateState.Run) -> String {
        switch run.stage {
        case .preparing: return "Getting the update ready…"
        case .sending: return "Sending the update to your glasses"
        case .installing: return run.rehearsal ? "Stopping before the install…"
                                               : "Your glasses are installing it"
        case .confirming: return "Waiting for your glasses to restart…"
        }
    }

    private func detail(_ run: FirmwareUpdateState.Run, now: Date) -> String {
        switch run.stage {
        case .preparing:
            return "Downloading it from Meta and connecting to your glasses"
        case .sending:
            let progress = "\(FirmwareUpdateState.size(run.sent)) of \(FirmwareUpdateState.size(run.bytes))"
            guard let seconds = run.secondsLeft(now: now) else { return progress }
            let minutes = Int((seconds / 60).rounded(.up))
            return progress + (minutes <= 1 ? " · about a minute left" : " · about \(minutes) min left")
        case .installing:
            return "They restart on their own when it's done. Don't turn them off."
        case .confirming:
            return "Then ReGlass reads the new version"
        }
    }

    private func stages(_ run: FirmwareUpdateState.Run) -> some View {
        let steps: [(FirmwareUpdateState.Stage, String)] = run.rehearsal
            ? [(.preparing, "Get the update from Meta"), (.sending, "Send it to your glasses"),
               (.installing, "Stop before your glasses install it")]
            : [(.preparing, "Get the update from Meta"), (.sending, "Send it to your glasses"),
               (.installing, "Your glasses install it and restart"), (.confirming, "Check the new version")]
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(steps.indices, id: \.self) { index in
                let (stage, title) = steps[index]
                FirmwareStep(title: title, status: stage < run.stage ? .done : (stage == run.stage ? .now : .later))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func keepOpenNote(_ run: FirmwareUpdateState.Run) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: run.stage < .installing ? "iphone" : "eyeglasses")
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
            Text(run.stage < .installing
                 ? "ReGlass keeps the screen on. Leave it open with your glasses nearby. You don't need to touch anything."
                 : "You can put your phone down. Keep your glasses nearby while they restart.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var stopControl: some View {
        if confirmingStop {
            VStack(spacing: 10) {
                Text("Stop the update? Nothing is installed, and you can start again later.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        confirmingStop = false
                        glasses.stopFirmwareUpdate()
                    } label: {
                        Text("Stop Update")
                    }
                    .buttonStyle(CompactPillStyle(kind: .destructive))
                    Button("Keep Going") {
                        withAnimation(Theme.Motion.inline(reduceMotion: reduceMotion)) { confirmingStop = false }
                    }
                    .buttonStyle(QuietButtonStyle())
                }
            }
            .transition(.opacity)
        } else {
            Button("Stop Update") {
                withAnimation(Theme.Motion.inline(reduceMotion: reduceMotion)) { confirmingStop = true }
            }
            .buttonStyle(QuietButtonStyle())
            .transition(.opacity)
        }
    }

    // MARK: Finished

    private func finished(_ outcome: FirmwareUpdateState.Outcome) -> some View {
        let look = Self.look(outcome)
        return VStack(spacing: 22) {
            Spacer(minLength: 40)
            Image(systemName: look.symbol)
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(look.tint)
                .symbolEffect(.bounce, value: outcome)
                .entrance(0)
            VStack(spacing: 10) {
                Text(look.title)
                    .displayFont(.title2)
                    .foregroundStyle(Theme.ink)
                Text(look.message)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .entrance(1)
            Spacer(minLength: 40)
            Button("Done") { glasses.dismissFirmwareOutcome() }
                .buttonStyle(PrimaryButtonStyle())
                .entrance(2)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 36)
        .frame(maxWidth: 520)
    }

    private static func look(_ outcome: FirmwareUpdateState.Outcome)
        -> (symbol: String, tint: Color, title: String, message: String) {
        switch outcome {
        case .updated(let version):
            return ("checkmark.circle.fill", Theme.good, "Your glasses are up to date", "They run version \(version) now.")
        case .rehearsed:
            return ("checkmark.circle.fill", Theme.good, "Rehearsal done",
                    "ReGlass sent the whole update and stopped before your glasses installed it. Nothing changed on your glasses.")
        case .stopped(let why):
            return ("stop.circle.fill", Theme.textSecondary, "Update stopped", why)
        case .unconfirmed(let why):
            return ("clock.fill", Theme.warning, "Your glasses are finishing the update", why)
        case .failed(let why):
            return ("exclamationmark.triangle.fill", Theme.warning, "The update didn't finish", why)
        }
    }
}

/// The hero ring: a copper sweep while ReGlass gets ready or waits for the restart, the share sent while sending
/// (with the percent), and a full, softly breathing ring while the glasses install.
private struct FirmwareRing: View {
    let run: FirmwareUpdateState.Run
    var size: CGFloat = 196
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var determinate: Bool { run.stage == .sending || run.stage == .installing }
    private var shown: Double { run.stage == .installing ? 1 : run.fraction }
    private var percent: Int { Int((run.fraction * 100).rounded(.down)) }

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.halo)
                .blur(radius: 40)
                .opacity(run.stage == .installing ? 0.9 : 0.45)
                .phaseAnimator([0.85, 1.0]) { view, phase in
                    view.scaleEffect(reduceMotion || run.stage != .installing ? 1 : phase)
                } animation: { _ in .easeInOut(duration: 2.2) }
            Circle().stroke(Theme.track, lineWidth: 12)
            if determinate {
                Circle()
                    .trim(from: 0, to: max(0.004, shown))
                    .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.reading, value: shown)
            } else {
                sweep
            }
            VStack(spacing: 2) {
                if run.stage == .sending {
                    Text("\(percent)%")
                        .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(percent)))
                        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.reading, value: percent)
                    Text("sent")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Image(systemName: run.stage == .preparing ? "arrow.down.circle" : "eyeglasses")
                        .font(.system(size: size * 0.2, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(run.stage == .sending ? "\(percent) percent sent" : "Working")
    }

    @ViewBuilder
    private var sweep: some View {
        if reduceMotion {
            Circle()
                .stroke(Theme.accentFill.opacity(0.5), lineWidth: 12)
        } else {
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(AngularGradient(colors: [Theme.accentFill.opacity(0), Theme.accentFill, Theme.accent],
                                            center: .center, startAngle: .degrees(0), endAngle: .degrees(101)),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360))
            }
        }
    }
}

/// One step of the update: done (a copper check), happening now (a turning arc), or still to come.
private struct FirmwareStep: View {
    enum Status { case done, now, later }
    let title: String
    let status: Status
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch status {
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .transition(.scale.combined(with: .opacity))
                case .now:
                    ArcSpinner(size: 20, lineWidth: 2.5)
                case .later:
                    Image(systemName: "circle")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(.body)
            .frame(width: iconColumn)
            Text(title)
                .font(.subheadline.weight(status == .now ? .semibold : .regular))
                .foregroundStyle(status == .later ? Theme.textTertiary : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .animation(Theme.Motion.inline, value: status)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status == .done ? "done" : (status == .now ? "in progress" : "to come"))
    }
}
