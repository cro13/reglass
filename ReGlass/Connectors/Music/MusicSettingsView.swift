import SwiftUI

/// Apple Music's options in its connector screen: whether ReGlass can search all of Apple Music or only the owner's
/// library, with a plain hint when something needs doing once.
struct MusicSettingsView: View {
    @ObservedObject var service: MusicService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            catalogLine
                .id(service.catalog)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .leading)))
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
            if service.cloudLibraryOff {
                AssistantStatusLine(tone: .info, text: "Sync Library is off, so playlists from your other devices aren't here.",
                                    symbol: "icloud.slash")
                    .transition(.opacity)
            }
            PillRow {
                Button {
                    Task { await service.checkCatalog(force: true) }
                } label: {
                    // The arrow turns while ReGlass checks: the pill is greyed then, and this says why.
                    Label {
                        Text("Check Again")
                    } icon: {
                        Image(systemName: "arrow.clockwise")
                            .symbolEffect(.rotate, options: .repeat(.continuous),
                                          isActive: service.catalog == .checking && !reduceMotion)
                    }
                }
                .buttonStyle(CompactPillStyle())
                .disabled(service.catalog == .checking)
                if service.catalog == .needsMusicApp || service.catalog == .notSignedIn {
                    Button {
                        if let url = URL(string: "music://") { openURL(url) }
                    } label: {
                        Label("Open Music", systemImage: "music.note")
                    }
                    .buttonStyle(CompactPillStyle())
                    .transition(.opacity)
                }
            }
            Text("Music plays in the Music app, so your glasses' touchpad keeps working: tap to pause, double-tap to skip, swipe for volume.")
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .assistantAnimation(service.catalog, reduceMotion: reduceMotion)
        .assistantAnimation(service.cloudLibraryOff, reduceMotion: reduceMotion)
        .task { await service.checkCatalog(force: false) }
        .onChange(of: scenePhase) { _, phase in
            // Back from the Music app or iPhone Settings: look again.
            if phase == .active { Task { await service.checkCatalog(force: true) } }
        }
    }

    @ViewBuilder private var catalogLine: some View {
        switch service.catalog {
        case .unknown, .checking:
            AssistantStatusLine(tone: .working, text: "Checking Apple Music…")
        case .reachable:
            AssistantStatusLine(tone: .good, text: "ReGlass can play anything on Apple Music.")
        case .needsDeveloperSetup:
            AssistantStatusLine(tone: .warning, text: "ReGlass plays from your library for now.")
        case .needsMusicApp:
            AssistantStatusLine(tone: .warning, text: "Open the Music app once, then check again.")
        case .notSignedIn:
            AssistantStatusLine(tone: .warning, text: "Sign in to Apple Music in the Music app.")
        case .noSubscription:
            AssistantStatusLine(tone: .warning, text: "No Apple Music subscription here, so ReGlass plays from your library.")
        case .offline:
            AssistantStatusLine(tone: .info, text: "Couldn't reach Apple Music. Your library still works.",
                                symbol: "wifi.slash")
        case .unreachable:
            AssistantStatusLine(tone: .warning, text: "Apple Music didn't answer. Your library still works.")
        }
    }

    private var hint: String? {
        switch service.catalog {
        case .needsDeveloperSetup:
            return "To search all of Apple Music, turn on MusicKit for ReGlass in your Apple developer account (Identifiers → ReGlass → App Services). It's a one-time step; then tap Check Again."
        case .needsMusicApp:
            return "Apple Music shows a short welcome the first time. ReGlass can search again once you've seen it."
        default:
            return nil
        }
    }
}
