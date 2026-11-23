import SwiftUI

/// Onboarding on first launch and while setting glasses up (again), otherwise the home (Chats · Notes · Reminders),
/// with the glasses one tap away. Setup can wait: Not Now on Welcome opens the home, which shows a Connect your
/// glasses card at the top of Chats until there are glasses. Meta's sign-in has no sheet of its own: it appears inline
/// on the onboarding's sign-in page.
struct RootView: View {
    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(SetupChoice.skippedKey) private var setupSkipped = false

    /// Setup is only forced on a first launch: never once it has been put off or glasses have been set up.
    private var setupForced: Bool { glasses.paired == nil && !setupSkipped }
    private var onboarding: Bool { setupForced || glasses.showingSetup }

    var body: some View {
        ZStack {
            if onboarding {
                OnboardingView(glasses: glasses, startAt: setupForced ? .welcome : .search)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.02)))
            } else {
                LibraryHome()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        // A smooth hand-over between setup and the home; a plain cross-fade under Reduce Motion.
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.5), value: onboarding)
        // Light or Dark follows the system: every colour is a dynamic Theme token.
        .tint(Theme.accent)
        // A firmware update runs full screen wherever it was started, until its outcome is dismissed.
        .fullScreenCover(isPresented: Binding(get: { glasses.firmwareUpdate.showsCover }, set: { _ in })) {
            FirmwareUpdateCover()
                .environmentObject(glasses)
        }
        // Glasses set up once: from then on, Forget glasses lands on the home with its Connect card, not in setup.
        .onChange(of: glasses.paired == nil, initial: true) { _, none in
            if !none { setupSkipped = true }
        }
    }
}

/// Whether setup is still forced on launch, kept across launches.
enum SetupChoice {
    /// True once Not Now has been tapped on Welcome, or glasses have been set up: the home opens even without glasses.
    static let skippedKey = "reglass.setupSkipped"
}

/// The screens pushed from the home. Each tab has its own stack of them, so the tab bar stays below.
enum AppRoute: Hashable {
    /// The glasses at a glance (`HomeView`).
    case glasses
    case settings
    /// The glasses' firmware and its update (`FirmwareView`), from Settings or the home's update banner.
    case firmware
    case conversation(UUID)
    /// A conversation Search found: it opens at `entry` (the step that matched; nil: the top), with the search's
    /// words lit.
    case chatMatch(UUID, entry: UUID?, query: String)
    /// One note, open to read and edit (`NoteScreen`).
    case note(UUID)
    /// A list's Recently Deleted (`RecentlyDeletedPage`), from the row at the end of Chats, Notes or Reminders.
    case recentlyDeleted(DeletedKind)
}

/// The screen for `route`, pushed onto a tab's navigation stack.
struct AppDestination: View {
    let route: AppRoute

    var body: some View {
        switch route {
        case .glasses: HomeView()
        case .settings: GlassesSettingsView()
        case .firmware: FirmwareView()
        case .conversation(let id): ConversationView(id: id)
        case .chatMatch(let id, let entry, let query): ConversationView(id: id, reveal: entry, query: query)
        case .note(let id): NoteScreen(id: id)
        case .recentlyDeleted(let kind): RecentlyDeletedPage(kind: kind)
        }
    }
}
