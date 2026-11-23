import ReGlassKit
import SwiftUI

/// The wake word sets on this iPhone, as one section of the Wake Word screen: put Hey Meta back from a factory set,
/// install a custom set or send it again, remove either, and import a set from Files. Everything happens in the set's
/// own row: a confirmation, then the progress, then the outcome. A factory download only saves files on this iPhone.
/// The screen holds the Files importer (`picking`) and the haptics, so they exist once, not once per row.
struct WakeWordSetsSection: View {
    @Binding var picking: Bool
    @Binding var signingIn: Bool
    @EnvironmentObject private var glasses: GlassesController
    @ObservedObject private var sets = WakeWordSets.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24
    @State private var confirming: Confirmation?

    private enum Confirmation: Equatable {
        case install(WakeWord)
        case download
    }

    var body: some View {
        Section {
            row(.heyMeta)
            row(.custom)
            importRow
        } header: {
            Text("Wake word sets")
        } footer: {
            Text("If an install is interrupted, the wake word may not work until you install a set again. Whether a custom set still works after your glasses restart hasn't been tested. \u{201C}Installed\u{201D} means your glasses list the set, not that it's the one listening.")
        }
        .listRowBackground(Theme.card)
        .animation(Theme.Motion.inline(reduceMotion: reduceMotion), value: motionKey)
        .onChange(of: glasses.wakeWord.isInstalling) { _, installing in if installing { confirming = nil } }
    }

    // MARK: One set

    @ViewBuilder private func row(_ wakeWord: WakeWord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(wakeWord)
            Group {
                if wakeWord == .heyMeta, let progress = sets.downloadProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        working(progress)
                        Button("Cancel Download") { sets.cancelDownload() }
                            .buttonStyle(QuietButtonStyle())
                    }
                } else if wakeWord == .heyMeta, confirming == .download {
                    confirmDownload
                } else if case .installing(wakeWord, let progress) = glasses.wakeWord.activity {
                    installing(progress)
                } else if sets.checking == wakeWord {
                    working("Checking the files\u{2026}")
                } else if case .installed(wakeWord) = glasses.wakeWord.activity {
                    installedOutcome(wakeWord)
                } else if case .failed(wakeWord, let message) = glasses.wakeWord.activity {
                    failedOutcome(message)
                } else if let set = sets.stored(wakeWord) {
                    switch confirming {
                    case .install(wakeWord)?: confirmInstall(set)
                    default: actions(set)
                    }
                } else if wakeWord == .heyMeta {
                    downloadAction
                }
            }
            .transition(blockTransition)
        }
        .padding(.vertical, 6)
    }

    private func heading(_ wakeWord: WakeWord) -> some View {
        let set = sets.stored(wakeWord)
        let title: String
        let detail: String
        let note: String?
        switch (wakeWord, set) {
        case (.heyMeta, let set?):
            title = set.name
            detail = "Factory set \u{00B7} on this iPhone"
            note = nil
        case (.heyMeta, nil):
            title = "Factory set"
            detail = "Not on this iPhone"
            note = "Your glasses come with Hey Meta. If it's missing, for example after a factory reset, download the factory set from Meta for your glasses' firmware, or import one you already have, and restore it."
        case (.custom, let set?):
            title = set.name
            detail = "Custom set \u{00B7} on this iPhone \u{00B7} " + Self.size(set.byteCount)
            note = nil
        case (.custom, nil):
            title = "Custom set"
            detail = "None on this iPhone"
            note = "Training your own wake word isn't in ReGlass yet. If you already have a set, import it."
        }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: wakeWord == .heyMeta ? "arrow.uturn.backward" : "waveform")
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: iconColumn)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(Theme.ink)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Steps

    private var downloadAction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { confirm(.download) } label: {
                Label("Download Factory Set", systemImage: "arrow.down.circle")
            }
            .buttonStyle(CompactPillStyle(kind: .glass))
            .disabled(sets.isBusy || glasses.wakeWord.isBusy || downloadBlocker != nil)
            // Only when it's needed: signed out, or Meta just refused the sign-in during a download.
            if glasses.accountStatus != .signedIn || sets.downloadNeedsSignIn {
                Button(glasses.accountStatus == .signedIn ? "Sign In Again" : "Sign In with Meta") {
                    signingIn = true
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(sets.isBusy || glasses.wakeWord.isBusy || glasses.paired == nil)
            }
            if let downloadBlocker {
                Text(downloadBlocker)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.leading, iconColumn + 12)
    }

    private var confirmDownload: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Download the factory set from Meta? ReGlass uses your Meta sign-in and sends your glasses' serial number and firmware details to Meta. It downloads about 13 MB and checks all eight files before saving them on this iPhone. Your glasses aren't changed.")
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            pills {
                Button("Download") {
                    confirming = nil
                    sets.downloadFactorySet()
                }
                .buttonStyle(CompactPillStyle(kind: .prominent))
                .disabled(sets.isBusy || glasses.wakeWord.isBusy || downloadBlocker != nil)
                Button("Cancel") { confirm(nil) }.buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.leading, iconColumn + 12)
    }

    private var downloadBlocker: String? {
        guard glasses.paired != nil else { return "Set up your glasses before downloading the factory set." }
        guard glasses.accountStatus == .signedIn else { return "Sign in with Meta to download the factory set." }
        // The download follows the firmware the glasses report, so it needs that version first.
        guard glasses.currentFirmwareVersion != nil else {
            return "Connect your glasses once so ReGlass knows their firmware version."
        }
        return nil
    }

    @ViewBuilder private func actions(_ set: WakeWordLibrary.StoredSet) -> some View {
        let onGlasses = isOnGlasses(set)
        VStack(alignment: .leading, spacing: 8) {
            if onGlasses {
                status("On your glasses", systemImage: "checkmark.circle.fill", tint: Theme.good)
            }
            pills {
                if set.wakeWord == .custom || !onGlasses {
                    Button {
                        confirm(.install(set.wakeWord))
                    } label: {
                        Label(installTitle(set, onGlasses: onGlasses), systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(CompactPillStyle(kind: onGlasses ? .glass : .prominent))
                    .disabled(installBlocker(for: set) != nil || sets.isBusy || glasses.wakeWord.isBusy)
                }
            }
            if let blocker = installBlocker(for: set), set.wakeWord == .custom || !onGlasses {
                Text(blocker)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, iconColumn + 12)
    }

    private func confirmInstall(_ set: WakeWordLibrary.StoredSet) -> some View {
        let again = isOnGlasses(set)
        let question: String
        if set.wakeWord == .heyMeta {
            question = "Restore Hey Meta? ReGlass sends the factory set to your glasses."
        } else {
            question = (again ? "Send \u{201C}\(set.name)\u{201D} again?" : "Install \u{201C}\(set.name)\u{201D}?")
                + " ReGlass sends its eight files (\(Self.size(set.byteCount))) to your glasses."
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text(question + " It takes about a minute. Keep your glasses close and ReGlass open.")
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("If it's interrupted, the wake word may not work until you install a set again.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            pills {
                Button(set.wakeWord == .heyMeta ? "Restore" : (again ? "Send Again" : "Install")) {
                    confirming = nil
                    sets.install(set.wakeWord)
                }
                .buttonStyle(CompactPillStyle(kind: .prominent))
                .disabled(installBlocker(for: set) != nil || sets.isBusy || glasses.wakeWord.isBusy)
                Button("Cancel") { confirm(nil) }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.leading, iconColumn + 12)
    }

    private func installing(_ progress: WakeWordProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ArcSpinner()
                Text(progress.label)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
            }
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint(Theme.accentFill)
                    .animation(reduceMotion ? nil : Theme.Motion.reading, value: fraction)
            }
            Text("Keep your glasses close and ReGlass open.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, iconColumn + 12)
        .accessibilityElement(children: .combine)
    }

    private func installedOutcome(_ wakeWord: WakeWord) -> some View {
        let name = sets.stored(wakeWord)?.name ?? wakeWord.title
        return VStack(alignment: .leading, spacing: 6) {
            status(wakeWord == .heyMeta ? "Hey Meta is back. Your glasses list the factory set."
                                        : "Installed. Your glasses list \u{201C}\(name)\u{201D}.",
                   systemImage: "checkmark.circle.fill", tint: Theme.good)
            Text(wakeWord == .heyMeta ? "Say \u{201C}Hey Meta\u{201D} to check it."
                                      : "That shows the set is stored, not that it's the one listening. Say your wake word to check it.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Done") { glasses.dismissWakeWordOutcome() }
                .buttonStyle(QuietButtonStyle())
                .padding(.leading, -12)
        }
        .padding(.leading, iconColumn + 12)
    }

    private func failedOutcome(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            status(message, systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
            Button("Done") { glasses.dismissWakeWordOutcome() }
                .buttonStyle(QuietButtonStyle())
                .padding(.leading, -12)
        }
        .padding(.leading, iconColumn + 12)
    }

    // MARK: Import

    private var importRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sets.importing {
                working("Checking the set\u{2026}")
                    .transition(blockTransition)
            } else {
                Button {
                    confirm(nil)
                    sets.outcome = nil
                    picking = true
                } label: {
                    Label("Import a Set", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(CompactPillStyle(kind: sets.factory == nil && sets.custom == nil ? .prominent : .glass))
                .disabled(sets.isBusy || glasses.wakeWord.isInstalling)
                .transition(blockTransition)
                Text("Pick a folder, or a .zip, with manifest.json and the eight files. ReGlass checks every file, then keeps a copy on this iPhone. Importing doesn't change your glasses.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outcome = sets.outcome {
                Group {
                    switch outcome {
                    case .imported(let name):
                        status("\u{201C}\(name)\u{201D} is on this iPhone.", systemImage: "checkmark.circle.fill",
                               tint: Theme.good)
                    case .removed(let name):
                        status("\u{201C}\(name)\u{201D} was removed from this iPhone.", systemImage: "trash",
                               tint: Theme.textSecondary)
                    case .problem(let text):
                        status(text, systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                    }
                }
                .transition(blockTransition)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Pieces

    /// A line of words with a symbol beside it: never colour alone.
    private func status(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func working(_ text: String) -> some View {
        HStack(spacing: 10) {
            ArcSpinner()
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
        }
        .padding(.leading, iconColumn + 12)
        .accessibilityElement(children: .combine)
    }

    /// Pills side by side, stacked when the text is too large for one line.
    private func pills<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content() }
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }

    private func confirm(_ next: Confirmation?) {
        withAnimation(Theme.Motion.inline(reduceMotion: reduceMotion)) { confirming = next }
    }

    private func installTitle(_ set: WakeWordLibrary.StoredSet, onGlasses: Bool) -> String {
        if set.wakeWord == .heyMeta { return "Restore Hey Meta" }
        return onGlasses ? "Send Again" : "Install"
    }

    /// Whether the glasses list this very set (by its artifact id; the factory set by Meta's).
    private func isOnGlasses(_ set: WakeWordLibrary.StoredSet) -> Bool {
        switch glasses.wakeWord.installed {
        case .heyMeta?: return set.wakeWord == .heyMeta
        case .custom(let artifact)?: return set.wakeWord == .custom && artifact == set.artifactId
        default: return false
        }
    }

    /// Why an install can't start right now, in plain words; nil when it can.
    /// Why `set` can't be installed now: the general reasons, then a set made for another firmware build.
    private func installBlocker(for set: WakeWordLibrary.StoredSet) -> String? {
        if let installBlocker { return installBlocker }
        guard let current = glasses.currentFirmwareVersion, current != set.firmware else { return nil }
        return set.wakeWord == .heyMeta
            ? "This factory set is for firmware \(set.firmware), and your glasses run \(current). Download it again for their firmware."
            : "This set is made for firmware \(set.firmware), and your glasses run \(current). Use a set made for \(current)."
    }

    private var installBlocker: String? {
        guard glasses.live.connection.isConnected else { return "Connect your glasses to install a set." }
        if glasses.wakeWord.unavailable { return "Installing a set isn't available on this firmware." }
        if glasses.wakeWord.installed == nil {
            return "ReGlass hasn't read the wake word on your glasses yet. Try again in a moment, or reconnect."
        }
        if glasses.wakeWord.installed == .unknown {
            return "ReGlass doesn't recognise the wake word files on your glasses, so it won't replace them."
        }
        return glasses.canChangeWakeWord || glasses.wakeWord.isBusy ? nil : "Your glasses are busy. Try again in a moment."
    }

    private var blockTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    private struct MotionKey: Equatable {
        let confirming: Confirmation?
        let activity: WakeWordState.Activity
        let outcome: WakeWordSets.Outcome?
        let importing: Bool
        let checking: WakeWord?
        let factory: Bool
        let custom: Bool
    }

    private var motionKey: MotionKey {
        MotionKey(confirming: confirming, activity: glasses.wakeWord.activity, outcome: sets.outcome,
                  importing: sets.importing, checking: sets.checking, factory: sets.factory != nil,
                  custom: sets.custom != nil)
    }

    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// Reuses the native email-code flow without touching ownership or the saved owner key.
struct FactoryDownloadSignInView: View {
    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.dismiss) private var dismiss
    @State private var startError: String?

    var body: some View {
        let signInDataNotice = MetaClient.signInDataError?.errorDescription
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            if let flow = glasses.signIn {
                MetaSignInPanel(flow: flow) {
                    glasses.cancelSignIn()
                    dismiss()
                }
            } else {
                VStack(spacing: 16) {
                    Text("Sign in with Meta")
                        .font(.title2)
                        .foregroundStyle(Theme.ink)
                    Text("Use the account that owns your glasses. Signing in doesn't change your glasses.")
                        .foregroundStyle(Theme.textSecondary)
                    if let signInDataNotice {
                        Text(signInDataNotice).foregroundStyle(Theme.warning)
                    } else if !MetaClient.isConfigured {
                        Text("This build has no Meta client credentials. Run the token script in tools/meta-tokens (see docs/META-CREDENTIALS.md), then rebuild ReGlass.")
                            .foregroundStyle(Theme.warning)
                    } else if let startError {
                        Text(startError).foregroundStyle(Theme.warning)
                    }
                    if case .failed(let reason) = glasses.accountStatus {
                        Text(reason).foregroundStyle(Theme.warning)
                    }
                    Button("Continue with Email") { startError = glasses.beginSignIn() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(signInDataNotice != nil || !MetaClient.isConfigured)
                }
                .multilineTextAlignment(.center)
                .padding(24)
            }
        }
        .navigationTitle("Meta account")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: glasses.accountStatus) { _, status in
            if status == .signedIn { dismiss() }
        }
        .onDisappear {
            if glasses.signIn != nil { glasses.cancelSignIn() }
        }
    }
}
