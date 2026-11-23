import SwiftUI

/// The "Connect your Meta glasses" flow: shown on first launch, and from Settings to reconnect or set up again.
/// One continuous surface rather than a numbered wizard: no step counter, and pages dissolve into each other in
/// place, never sliding sideways like a wizard's pages.
struct OnboardingView: View {
    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: OnboardingModel
    /// Setup was put off once (Not Now): opened again from the home, it can be closed back to it.
    @AppStorage(SetupChoice.skippedKey) private var setupSkipped = false

    init(glasses: GlassesController, startAt: OnboardingModel.Step) {
        _model = StateObject(wrappedValue: OnboardingModel(glasses: glasses, startAt: startAt))
    }

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: model.step == .welcome || model.step == .done ? 1.35 : 1)
            VStack(spacing: 0) {
                topBar
                ZStack {
                    page
                        .id(model.step)
                        .transition(pageTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .environmentObject(model)
        // Every step change, the auto-advances after sign-in and after setup included, is a new screen to VoiceOver.
        .announcesScreenChange(on: model.step)
    }

    @ViewBuilder private var page: some View {
        switch model.step {
        case .welcome: WelcomeStep()
        case .search: SearchStep()
        case .signIn: SignInStep()
        case .transfer: TransferStep()
        case .setup: SetupStep()
        case .done: DoneStep()
        }
    }

    /// A blur crossfade in place: the new page comes into focus while the old one blurs away and settles back a
    /// touch. No sideways drift, so the flow never reads as a wizard's slides. A plain fade under Reduce Motion.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(insertion: AnyTransition(.blurReplace),
                           removal: AnyTransition(.blurReplace).combined(with: .scale(scale: 0.97)))
    }

    /// Closing is for a re-setup from Settings or a setup opened from the home, and never mid-run: a run must end
    /// before the live link returns.
    private var canClose: Bool { (glasses.paired != nil || setupSkipped) && model.step != .done && model.run != .running }

    private var topBar: some View {
        HStack {
            Button { model.back() } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .glassSurface(in: Circle(), interactive: true)
            }
            .opacity(model.canGoBack ? 1 : 0)
            .disabled(!model.canGoBack)
            .accessibilityLabel("Back")
            // Hidden means gone for VoiceOver too, not "Back, dimmed".
            .accessibilityHidden(!model.canGoBack)
            Spacer()
            Button { model.close() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .glassSurface(in: Circle(), interactive: true)
            }
            .opacity(canClose ? 1 : 0)
            .disabled(!canClose)
            .accessibilityLabel("Close")
            .accessibilityHidden(!canClose)
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 16)
        .frame(height: 56)
    }
}

/// Art on top, a title and message, the step's own content, and the actions pinned to the bottom. The pieces arrive
/// one after another, and a changing title or message morphs in place.
struct StepLayout<Art: View, Content: View, Actions: View>: View {
    let title: String
    var message: String?
    @ViewBuilder var art: () -> Art
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    art()
                        .frame(maxWidth: .infinity)
                        .entrance(0, distance: 10)
                    VStack(spacing: 10) {
                        Text(title)
                            .displayFont(.title)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Theme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(reduceMotion ? ContentTransition.opacity : ContentTransition.interpolate)
                            .accessibilityAddTraits(.isHeader)
                        if let message {
                            Text(message)
                                .font(.body)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .contentTransition(.opacity)
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 8)
                    .animation(.easeInOut(duration: 0.35), value: title)
                    .animation(.easeInOut(duration: 0.35), value: message)
                    .entrance(1)
                    content()
                        .entrance(2)
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 6) {
                actions()
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .entrance(3, distance: 8)
        }
    }
}

/// A big piece of art floating on a soft warm glow, with an optional glint of light passing across the
/// glasses now and then. With Reduce Motion it stays still and never glints.
struct GlowingArt: View {
    let art: GlassesArt
    var height: CGFloat = 220
    var glow: Double = 0.45
    var glint = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var float = false

    var body: some View {
        ZStack {
            // Fades out inside its own frame: StepLayout's scroll view clips, so a blurred glow showed a hard edge.
            Circle()
                .fill(RadialGradient(colors: [Theme.glow.opacity(0.9), .clear], center: .center,
                                     startRadius: 0, endRadius: (height + 20) / 2))
                .frame(width: height + 20, height: height + 20)
                .scaleEffect(x: 1.7, y: 1)
                .opacity(glow)
                .animation(.easeInOut(duration: 0.8), value: glow)
            ArtImage(art: art)
                .frame(height: height)
                .overlay {
                    if glint && !reduceMotion {
                        GlintBand().mask(ArtImage(art: art))
                    }
                }
                .offset(y: reduceMotion ? 0 : (float ? -4 : 4))
        }
        .frame(height: height + 20)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) { float = true }
        }
    }
}

/// Tells VoiceOver the screen changed whenever `value` does, so focus moves to the new page instead of staying on a
/// button that has gone. It waits a moment for the new page to draw in (its pieces fade in, and VoiceOver skips what
/// it can't see yet), and a newer change replaces a waiting one.
private struct ScreenChangeNotice<Value: Equatable>: ViewModifier {
    let value: Value
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content.onChange(of: value) { _, _ in
            pending?.cancel()
            pending = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                AccessibilityNotification.ScreenChanged().post()
            }
        }
    }
}

extension View {
    /// See `ScreenChangeNotice`. For the setup flow and Meta's sign-in screens, which change pages in place.
    func announcesScreenChange<Value: Equatable>(on value: Value) -> some View {
        modifier(ScreenChangeNotice(value: value))
    }
}
