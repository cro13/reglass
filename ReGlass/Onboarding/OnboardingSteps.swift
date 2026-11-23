import SwiftUI
import UIKit
import ReGlassKit

// MARK: 1. Welcome

struct WelcomeStep: View {
    @EnvironmentObject private var model: OnboardingModel
    /// Not Now: the home opens without glasses, and stays the start from then on (`RootView`).
    @AppStorage(SetupChoice.skippedKey) private var setupSkipped = false

    var body: some View {
        StepLayout(title: "ReGlass", message: "Your glasses. Your assistant.") {
            GlowingArt(art: .brand, height: 200, glow: 0.55, glint: true)
                .padding(.top, 36)
        } content: {
            VStack(alignment: .leading, spacing: 16) {
                CheckLine(text: "Connects to your glasses directly over Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                    .entrance(3, distance: 8)
                CheckLine(text: "Battery, case and status at a glance", systemImage: "battery.75percent")
                    .entrance(4, distance: 8)
                CheckLine(text: "Your key stays on this iPhone", systemImage: "lock.fill")
                    .entrance(5, distance: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard()
            .padding(.top, 8)
        } actions: {
            Button("Connect Your Glasses") { model.go(.search) }
                .buttonStyle(PrimaryButtonStyle())
            // Setup can wait: Chats offers it again from the top.
            Button("Not Now") { setupSkipped = true }
                .buttonStyle(QuietButtonStyle())
            Text("Open source · tested with the Ray-Ban Meta Clubmaster (Audio)")
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 6)
        }
    }
}

// MARK: 2. Find them

struct SearchStep: View {
    @EnvironmentObject private var model: OnboardingModel

    /// The model owns the discovery; the content view observes it directly so new finds redraw the list.
    var body: some View {
        SearchStepContent(discovery: model.discovery)
    }
}

private struct SearchStepContent: View {
    @EnvironmentObject private var model: OnboardingModel
    @ObservedObject var discovery: GlassesDiscovery
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StepLayout(title: title, message: message) {
            ZStack {
                if discovery.state == .searching {
                    // As tall as the art's slot: taller rings were cut off by the scroll view's edge.
                    SearchPulse().frame(width: 280, height: discovery.found.isEmpty ? 240 : 170)
                }
                ArtImage(art: .front)
                    .frame(width: discovery.found.isEmpty ? 220 : 170)
                    .modifier(Drift(active: discovery.state == .searching, amplitude: 3))
            }
            .frame(height: discovery.found.isEmpty ? 240 : 170)
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.85),
                       value: discovery.found.isEmpty)
            // A tap when glasses turn up, and a light one when the owner picks a pair.
            .sensoryFeedback(.impact(weight: .medium), trigger: discovery.found.count) { old, new in new > old }
            .sensoryFeedback(.impact(weight: .light), trigger: model.selected?.id) { _, new in new != nil }
        } content: {
            VStack(spacing: 12) {
                ForEach(discovery.found) { found in
                    Button { model.choose(found) } label: { FoundRow(found: found) }
                        .buttonStyle(CardPressStyle())
                        .transition(reduceMotion ? .opacity
                                    : .asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity).combined(with: .offset(y: 16)),
                                                  removal: .opacity))
                }
                problemCard
                if discovery.found.isEmpty && discovery.searchedAWhile && discovery.state == .searching {
                    helpCard
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.85),
                       value: discovery.found)
        } actions: {
            if discovery.state != .searching {
                Button("Search Again") { discovery.start() }
                    .buttonStyle(PrimaryButtonStyle())
            } else if !discovery.found.isEmpty {
                Text("Tap your glasses to continue")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 8)
            }
        }
    }

    private var title: String {
        switch discovery.state {
        case .bluetoothOff: return "Turn on Bluetooth"
        case .bluetoothDenied: return "Allow Bluetooth"
        case .failed: return "Bluetooth isn't ready"
        default: return discovery.found.isEmpty ? "Looking for your glasses…" : "Choose your glasses"
        }
    }

    private var message: String? {
        switch discovery.state {
        case .bluetoothOff: return "ReGlass needs Bluetooth to find your glasses. Turn it on in Control Center."
        case .bluetoothDenied: return "ReGlass needs Bluetooth permission to find your glasses."
        case .failed(let why): return why
        default:
            // What the old "get ready" page said, where it's needed: while nothing has turned up yet.
            return discovery.found.isEmpty
                ? "Open the case or unfold your glasses, keep them next to your iPhone, and close the Meta AI app."
                : nil
        }
    }

    @ViewBuilder private var problemCard: some View {
        if discovery.state == .bluetoothDenied {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Not seeing them?")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            CheckLine(text: "Unfold your glasses or open the case so they wake up.", systemImage: "eyeglasses")
            CheckLine(text: "Close the Meta AI app.", systemImage: "xmark.app")
            CheckLine(text: "In iOS Settings → Bluetooth, check your glasses are connected.", systemImage: "gearshape")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }
}

private struct FoundRow: View {
    let found: FoundGlasses

    var body: some View {
        HStack(spacing: 14) {
            ArtImage(art: .front)
                .frame(width: 64, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(found.name)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(found.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(found.connectedToPhone ? Theme.good : Theme.textSecondary)
            }
            Spacer(minLength: 8)
            SignalBars(bars: found.signalBars)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        }
        .contentShape(Rectangle())
        .contentCard(cornerRadius: 20, padding: 14)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Connects these glasses")
    }
}

// MARK: 3. Sign in with Meta

struct SignInStep: View {
    @EnvironmentObject private var model: OnboardingModel
    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startError: String?

    /// Replaces the intro with the sign-in form after the user taps Continue with Email.
    var body: some View {
        ZStack {
            if let flow = glasses.signIn {
                MetaSignInPanel(flow: flow, cancel: glasses.cancelSignIn)
                    .transition(.opacity)
            } else {
                intro
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: glasses.signIn != nil)
    }

    private var intro: some View {
        let signInDataNotice = MetaClient.signInDataError?.errorDescription
        return StepLayout(title: signedIn ? "You're signed in" : "Sign in with Meta",
                   message: "Use the Meta account that owns your glasses. Meta confirms you're the owner before ReGlass takes over.") {
            ReGlassEmblem(symbol: signedIn ? "person.crop.circle.badge.checkmark" : "person.crop.circle", size: 118)
                .frame(height: 190)
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                CheckLine(text: "Meta emails you a code. No password in ReGlass.", systemImage: "envelope.fill")
                    .entrance(3, distance: 8)
                CheckLine(text: "Your email and code go straight to Meta over HTTPS.", systemImage: "lock.fill")
                    .entrance(4, distance: 8)
                CheckLine(text: "Signing in doesn't change anything on your glasses.", systemImage: "eyeglasses")
                    .entrance(5, distance: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard()
            if let signInDataNotice {
                Notice(text: signInDataNotice, tint: Theme.warning)
            } else if !MetaClient.isConfigured {
                Notice(text: "This build has no Meta client credentials. Run the token script in tools/meta-tokens (see docs/META-CREDENTIALS.md), then rebuild ReGlass.",
                       tint: Theme.warning)
            }
            if case .failed(let reason) = glasses.accountStatus {
                Notice(text: reason, tint: Theme.warning)
            }
            if let startError {
                Notice(text: startError, tint: Theme.warning)
            }
        } actions: {
            if signedIn {
                Button("Continue") { model.go(.transfer) }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Use a Different Account") { glasses.signOut() }
                    .buttonStyle(QuietButtonStyle())
            } else {
                Button("Continue with Email") { startError = glasses.beginSignIn() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(signInDataNotice != nil || !MetaClient.isConfigured)
            }
        }
    }

    private var signedIn: Bool { glasses.accountStatus == .signedIn }
}

/// A tinted note inside a step.
struct Notice: View {
    let text: String
    var tint: Color = Theme.warning

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }
}

// MARK: 4. Transfer ownership

struct TransferStep: View {
    @EnvironmentObject private var model: OnboardingModel

    var body: some View {
        StepLayout(title: "Make ReGlass their app",
                   message: "ReGlass uses Meta's signed hand-over to register its own key for \(model.selected?.name ?? "your glasses").") {
            HandoverArt()
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                CheckLine(text: "Your glasses stay linked to your Meta account.")
                CheckLine(text: "ReGlass's key is sealed on this iPhone and never leaves it.")
                CheckLine(text: "Nothing changes until you tap Transfer.")
                Divider().overlay(Theme.hairline)
                CheckLine(text: "While ReGlass is the owner, the Meta AI app can't connect. To switch back, set the glasses up again in Meta AI.",
                          systemImage: "info.circle.fill")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard()
        } actions: {
            Button("Transfer to ReGlass") { model.transfer() }
                .buttonStyle(PrimaryButtonStyle())
            Button("Not Now") { model.back() }
                .buttonStyle(QuietButtonStyle())
        }
    }
}

/// This iPhone handing ReGlass's key to the glasses: a phone, a run of light with a key riding it, and the glasses
/// on their warm glow. Still under Reduce Motion.
private struct HandoverArt: View {
    var body: some View {
        ZStack {
            // Fades out inside its own frame, so the scroll view's clip leaves no hard edge.
            Circle()
                .fill(RadialGradient(colors: [Theme.glow.opacity(0.9), .clear], center: .center,
                                     startRadius: 0, endRadius: 95))
                .frame(width: 190, height: 190)
                .scaleEffect(x: 1.8, y: 1)
                .opacity(0.42)
            HStack(spacing: 4) {
                Image(systemName: "iphone")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(Theme.accent)
                HandoverFlow()
                    .frame(width: 70, height: 48)
                ArtImage(art: .hero)
                    .frame(width: 168)
                    .modifier(Drift(amplitude: 3))
            }
        }
        .frame(height: 190)
        .accessibilityHidden(true)
    }
}

// MARK: 5. Setting up

struct SetupStep: View {
    @EnvironmentObject private var model: OnboardingModel
    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        StepLayout(title: title, message: message) {
            ZStack {
                SetupRings(size: 250, running: isRunning)
                GlowingArt(art: .hero, height: 170, glow: isFailed ? 0.15 : 0.45)
                if succeeded {
                    BurstRings()
                        .frame(width: 260, height: 260)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(Theme.onStatus, Theme.good)
                        .offset(x: 90, y: 70)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .frame(height: 260)
            .animation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.58), value: succeeded)
            .sensoryFeedback(.success, trigger: succeeded) { _, now in now }
            .sensoryFeedback(.error, trigger: isFailed) { _, now in now }
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.stages) { stage in
                    StageRow(stage: stage, status: status(of: stage))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentCard()
        } actions: {
            actions
        }
    }

    private var isRunning: Bool { model.run == .running }
    private var succeeded: Bool { model.run == .succeeded }
    private var isFailed: Bool { if case .failed = model.run { return true } else { return false } }
    private var name: String { model.selected?.name ?? "your glasses" }

    private var title: String {
        switch model.run {
        case .failed(let problem): return problem.title
        case .succeeded: return "Connected"
        default: return model.mode == .enroll ? "Setting up \(name)" : "Reconnecting \(name)"
        }
    }

    private var message: String? {
        switch model.run {
        case .failed(let problem): return problem.message
        case .succeeded: return "ReGlass is now the owner of your glasses."
        default: return (model.stage ?? model.stages.first)?.activeDetail
        }
    }

    private func status(of stage: SetupStage) -> StageRow.Status {
        switch model.run {
        case .succeeded: return .done
        case .idle: return .pending
        case .running:
            guard let current = model.stage else { return stage == model.stages.first ? .active : .pending }
            return stage < current ? .done : stage == current ? .active : .pending
        case .failed:
            guard let current = model.stage else { return stage == model.stages.first ? .failed : .pending }
            return stage < current ? .done : stage == current ? .failed : .pending
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.run {
        case .running:
            if model.stage == .ownership {
                Text("Almost there. Keep your glasses close.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 10)
            } else {
                Button("Cancel") { model.cancelSetup() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        case .failed(let problem):
            if problem.offerRetry {
                Button("Try Again") { model.retry() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            if problem.offerTransfer {
                Button("Transfer to ReGlass") {
                    model.go(glasses.accountStatus == .signedIn ? .transfer : .signIn)
                }
                .buttonStyle(problem.offerRetry ? AnyButtonStyle(SecondaryButtonStyle()) : AnyButtonStyle(PrimaryButtonStyle()))
            }
            if problem.offerSignIn {
                Button("Sign In Again") { model.signInAgain() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        case .idle:
            Button("Try Again") { model.retry() }
                .buttonStyle(PrimaryButtonStyle())
        case .succeeded:
            ArcSpinner(size: 22).padding(.bottom, 18)
        }
    }
}

/// Lets a button pick its style at run time.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct StageRow: View {
    enum Status { case pending, active, done, failed }
    let stage: SetupStage
    let status: Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                switch status {
                case .pending:
                    Circle().strokeBorder(Theme.control, lineWidth: 1.5)
                case .active:
                    ArcSpinner(size: 20)
                        .transition(.opacity)
                case .done:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.onStatus, Theme.good)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.onStatus, Theme.critical)
                }
            }
            .frame(width: 24, height: 24)
            Text(stage.title)
                .font(.body.weight(status == .active ? .semibold : .regular))
                .foregroundStyle(status == .pending ? Theme.textTertiary : Theme.ink)
            Spacer(minLength: 0)
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.62), value: status)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.spoken)
    }
}

private extension StageRow.Status {
    /// What VoiceOver says for a stage, in words rather than the case's name.
    var spoken: String {
        switch self {
        case .pending: return "Waiting"
        case .active: return "In progress"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}

/// The setup ring: a copper arc turning around the glasses with a point of light at its head, and a fainter dotted
/// ring turning the other way. It fades out when setup isn't running, and holds still under Reduce Motion.
private struct SetupRings: View {
    let size: CGFloat
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || !running)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let turn = Angle.degrees(t.truncatingRemainder(dividingBy: 2.8) / 2.8 * 360)
            ZStack {
                Circle()
                    .stroke(AngularGradient(colors: [Theme.accent, Theme.accentFill, Theme.accentFill.opacity(0)],
                                            center: .center),
                            lineWidth: 2)
                    .rotationEffect(turn)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 6, height: 6)
                    .offset(x: size / 2)
                    .rotationEffect(turn)
                Circle()
                    .strokeBorder(Theme.accentFill.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                    .padding(18)
                    .rotationEffect(.degrees(-t.truncatingRemainder(dividingBy: 9) / 9 * 360))
            }
            .frame(width: size, height: size)
        }
        .opacity(running ? 0.9 : 0)
        .animation(.easeInOut(duration: 0.5), value: running)
        .accessibilityHidden(true)
    }
}

// MARK: 6. Done

struct DoneStep: View {
    @EnvironmentObject private var model: OnboardingModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sealed = false

    var body: some View {
        StepLayout(title: "You're all set",
                   message: "\(model.selected?.name ?? "Your glasses") \(model.mode == .enroll ? "now belong to ReGlass" : "reconnected to ReGlass").") {
            ZStack(alignment: .bottomTrailing) {
                GlowingArt(art: .hero, height: 200, glow: 0.6, glint: true)
                ZStack {
                    if sealed {
                        BurstRings()
                            .frame(width: 130, height: 130)
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Theme.onStatus, Theme.good)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                .frame(width: 44, height: 44)
                .offset(x: -24, y: -8)
            }
            .padding(.top, 20)
            .onAppear {
                // The seal lands once the page has settled.
                withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.55).delay(0.45)) {
                    sealed = true
                }
            }
            .sensoryFeedback(.success, trigger: sealed) { _, now in now }
        } content: {
            HStack(spacing: 20) {
                BatteryRing(percent: model.outcome?.batteryPercent, charging: false, title: "Battery", size: 78)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selected?.name ?? "Your glasses")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(PairedGlasses.productLine(model.outcome?.model))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                    Label("Owner: ReGlass", systemImage: "checkmark.shield.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.good)
                }
                Spacer(minLength: 0)
            }
            .contentCard()
        } actions: {
            Button("Open ReGlass") { model.complete() }
                .buttonStyle(PrimaryButtonStyle())
        }
    }
}
