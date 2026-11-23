import SwiftUI

/// Settings for the glasses ReGlass owns: status, connection, wake word, the assistant, device details, Meta account
/// and troubleshooting. What only a developer needs (the model code and serial number) sits behind one Developer row,
/// so the everyday list stays short. Forgetting the glasses has its own red section at the very bottom.
struct GlassesSettingsView: View {
    @EnvironmentObject private var glasses: GlassesController
    @ObservedObject private var assistant = AssistantController.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmForget = false
    /// Counted taps on Refresh Status and Reconnect: each one turns its arrow once and taps lightly.
    @State private var refreshes = 0
    @State private var reconnects = 0

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            List {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                statusSection
                connectionSection
                soundSection
                wakeWordSection
                firmwareSection
                assistantSection
                aboutSection
                accountSection
                troubleshootingSection
                developerSection
                forgetSection
                footer
                    .listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: live.connection.isConnected) {
            if live.connection.isConnected { glasses.readWakeWord() }
        }
        .alert("Rename glasses", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { glasses.rename(newName) }
        }
        .sensoryFeedback(.warning, trigger: confirmForget) { _, asking in asking }
        .sensoryFeedback(.impact(weight: .light), trigger: refreshes)
        .sensoryFeedback(.impact(weight: .light), trigger: reconnects)
        .confirmationDialog("Forget these glasses?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget Glasses", role: .destructive) {
                glasses.forget()
                dismiss()
            }
        } message: {
            Text("ReGlass stops connecting to them, and the home offers to set them up again. Its key stays sealed on this iPhone so a later setup can reuse it. Nothing changes on the glasses.")
        }
    }

    private var paired: PairedGlasses? { glasses.paired }
    /// An install holds the glasses; nothing else may take them until it ends.
    private var installingWakeWord: Bool { glasses.wakeWord.isInstalling }
    private var live: GlassesLive { glasses.live }

    // MARK: Sections

    /// A compact header, leading-aligned: the picture, small, on a little warm glow, with the name and the
    /// status pill beside it. The Glasses screen has the big hero; here the rows come first. At accessibility text
    /// sizes the picture and the words stack.
    private var header: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                                  : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
        return layout {
            ZStack {
                // A gradient that fades out inside the header: the list clips its rows, so a blurred glow showed a hard edge.
                Circle()
                    .fill(RadialGradient(colors: [Theme.glow.opacity(0.6), .clear], center: .center,
                                         startRadius: 0, endRadius: 48))
                    .frame(width: 96, height: 96)
                    .scaleEffect(x: 1.4, y: 1)
                ArtImage(art: .front)
                    .frame(width: 88)
            }
            .frame(width: 96, height: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(paired?.name ?? "Glasses")
                    .displayFont(.title2)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                StatusPill(connection: live.connection)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var statusSection: some View {
        Section("Status") {
            InfoRow(title: "Connection", value: live.connection.label, systemImage: "dot.radiowaves.left.and.right")
            InfoRow(title: "Battery", value: batteryText(live.battery, charging: connected && live.charging),
                    systemImage: "battery.75percent")
            InfoRow(title: "Charging case", value: caseText,
                    systemImage: "case.fill")
            InfoRow(title: "Wearing", value: wearingText, systemImage: "eyeglasses")
            InfoRow(title: "Last update", value: live.updatedAt?.relativeDescription ?? "—", systemImage: "clock")
        }
        .listRowBackground(Theme.card)
    }

    private var connectionSection: some View {
        Section {
            Toggle(isOn: $glasses.stayConnected) {
                Label("Stay connected", systemImage: "link")
            }
            .tint(Theme.accentFill)
            .disabled(installingWakeWord)
            Button {
                refreshes += 1
                glasses.refresh()
            } label: {
                Label {
                    Text("Refresh Status")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, value: reduceMotion ? 0 : refreshes)
                }
            }
            .disabled(!live.connection.isConnected)
            Button {
                reconnects += 1
                glasses.disconnect()
                glasses.connectIfReady()
            } label: {
                Label {
                    Text("Reconnect")
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .symbolEffect(.rotate, value: reduceMotion ? 0 : reconnects)
                }
            }
            .disabled(!glasses.stayConnected || installingWakeWord)
        } header: {
            Text("Connection")
        } footer: {
            Text("ReGlass keeps a Bluetooth link to your glasses for live battery and status, also while it's in the background. Your glasses talk to one app at a time.")
        }
        .listRowBackground(Theme.card)
    }

    private var soundSection: some View {
        Section {
            Toggle(isOn: $glasses.adaptiveVolume) {
                Label("Adaptive volume", systemImage: "speaker.wave.3.fill")
                    .foregroundStyle(Theme.ink)
            }
            .tint(Theme.accentFill)
            .disabled(paired == nil || installingWakeWord)
            Toggle(isOn: $glasses.spatialAudio) {
                Label("Spatial audio", systemImage: "person.spatialaudio.stereo.fill")
                    .foregroundStyle(Theme.ink)
            }
            .tint(Theme.accentFill)
            .disabled(paired == nil || installingWakeWord)
        } header: {
            Text("Sound")
        } footer: {
            Text("Adaptive volume raises and lowers the glasses with the noise around you. Spatial audio tracks your head for stereo sound.")
        }
        .listRowBackground(Theme.card)
    }

    private var wakeWordSection: some View {
        Section {
            NavigationLink {
                WakeWordView()
            } label: {
                InfoRow(title: "Wake word", value: glasses.wakeWord.summary, systemImage: "waveform")
            }
        } header: {
            Text("Wake word")
        } footer: {
            Text("Say Hey Meta, or touch and hold the touchpad, to talk to ReGlass.")
        }
        .listRowBackground(Theme.card)
    }

    private var firmwareSection: some View {
        Section {
            NavigationLink {
                FirmwareView()
            } label: {
                InfoRow(title: "Firmware", value: firmwareSummary, systemImage: "arrow.down.circle")
            }
        } header: {
            Text("Software")
        }
        .listRowBackground(Theme.card)
    }

    private var firmwareSummary: String {
        if glasses.firmwareUpdate.isRunning { return "Updating…" }
        if case .available = glasses.firmwareUpdate.check { return "Update available" }
        return glasses.currentFirmwareVersion ?? "—"
    }

    private var assistantSection: some View {
        Section {
            ConnectorsSettingsRow()
            NavigationLink {
                KeysView()
            } label: {
                InfoRow(title: "Keys", value: keysSummary, systemImage: "key.fill")
            }
            ModelSettingsRow()
            VoiceAndSpeechSettingsRow()
            NavigationLink {
                TalkToReGlassView()
            } label: {
                Label("Talk to ReGlass", systemImage: "text.bubble")
            }
            NavigationLink {
                InterpreterView()
            } label: {
                Label {
                    HStack(spacing: 8) {
                        Text("Live interpreter")
                        ExperimentalMark()
                    }
                } icon: {
                    Image(systemName: "character.bubble")
                }
            }
        } header: {
            Text("Assistant")
        } footer: {
            Text("ReGlass answers with Claude, on your glasses after Hey Meta or a touch and hold on the touchpad. \(assistantStatus)")
        }
        .listRowBackground(Theme.card)
        .task { assistant.refreshKeys() }
    }

    private var keysSummary: String {
        if assistant.keysLocked { return "Unlock iPhone" }
        return assistant.keyHints[.anthropic] != nil ? "Added" : "Not added"
    }

    /// One sentence on whether the assistant can work right now.
    private var assistantStatus: String {
        if !assistant.hasAnthropicKey { return "Add your Claude key to start." }
        switch assistant.speechModel {
        case .notInstalled?, .downloading?: return "Speech recognition is still downloading on this iPhone."
        case .unsupported?: return "Speech recognition isn't available on this iPhone yet."
        default: break
        }
        if !assistant.linked || !assistant.available { return "It's ready once your glasses are connected." }
        return "Ready on your glasses."
    }

    private var aboutSection: some View {
        Section("About these glasses") {
            // The system row highlight under the finger, as a tappable Settings row has.
            Button {
                newName = paired?.name ?? ""
                renaming = true
            } label: {
                InfoRow(title: "Name", value: paired?.name ?? "—", systemImage: "pencil")
            }
            .accessibilityHint("Renames your glasses")
            InfoRow(title: "Model", value: paired?.productLine ?? "—", systemImage: "eyeglasses")
            InfoRow(title: "Firmware", value: live.firmware ?? paired?.firmware ?? "—", systemImage: "cpu", monospaced: true)
            if let setUp = paired?.setUpAt {
                InfoRow(title: "Set up", value: setUp.formatted(date: .abbreviated, time: .omitted), systemImage: "calendar")
            }
            InfoRow(title: "Owner app", value: live.connection == .refused ? "Not ReGlass any more" : "ReGlass",
                    systemImage: "checkmark.shield")
        }
        .listRowBackground(Theme.card)
    }

    private var accountSection: some View {
        Section {
            InfoRow(title: "Meta account", value: loginText, systemImage: "person.crop.circle")
            if glasses.accountStatus == .signedIn {
                Button(role: .destructive) { glasses.signOut() } label: {
                    Label("Sign Out of Meta", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .tint(Theme.actionRed)
            }
        } header: {
            Text("Meta account")
        } footer: {
            Text("Needed to transfer glasses to ReGlass or download a factory wake word set. Signing out doesn't change your glasses or ReGlass's key.")
        }
        .listRowBackground(Theme.card)
    }

    private var troubleshootingSection: some View {
        Section("Troubleshooting") {
            Button {
                glasses.showingSetup = true
            } label: {
                Label("Reconnect or Set Up Again", systemImage: "arrow.clockwise")
            }
            .disabled(installingWakeWord)
        }
        .listRowBackground(Theme.card)
    }

    /// Forget, alone and last, in red, so it never sits within a thumb of an everyday button.
    private var forgetSection: some View {
        Section {
            Button(role: .destructive) {
                confirmForget = true
            } label: {
                Label("Forget These Glasses", systemImage: "trash")
            }
            .tint(Theme.actionRed)
            .disabled(installingWakeWord)
        } footer: {
            Text("ReGlass stops connecting to them. You can set them up again at any time; nothing changes on the glasses.")
        }
        .listRowBackground(Theme.card)
    }

    /// One row into the Developer screen. In every build, Release included: the owner runs release builds.
    private var developerSection: some View {
        Section {
            NavigationLink {
                DeveloperView()
            } label: {
                Label("Developer", systemImage: "hammer")
            }
        }
        .listRowBackground(Theme.card)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("ReGlass \(Bundle.main.shortVersion)")
            Text("ReGlassKit · AGPL-3.0")
        }
        .font(.caption)
        .foregroundStyle(Theme.textTertiary)
        .frame(maxWidth: .infinity)
    }

    // MARK: Text

    private func batteryText(_ percent: Int?, charging: Bool) -> String {
        guard let percent else { return "—" }
        return "\(percent)%" + (charging ? " · charging" : "")
    }

    /// The case reports only through the glasses sitting in it; out of the case its level is an older reading.
    private var caseText: String {
        guard let percent = live.caseBattery else { return "—" }
        if live.caseIsLive { return batteryText(percent, charging: live.caseCharging) }
        return "\(percent)%, seen " + (live.caseSeenAt?.relativeDescription ?? "earlier")
    }

    /// Wearing and charging are only known while connected; Last update says how old the battery readings are.
    private var connected: Bool { live.connection.isConnected }

    private var wearingText: String {
        guard connected else { return "—" }
        if live.inCase == true { return "In the case" }
        guard let worn = live.worn else { return "—" }
        return worn ? "On your face" : "Not worn"
    }

    private var loginText: String {
        switch glasses.accountStatus {
        case .signedIn: return "Signed in"
        case .signedOut: return "Not signed in"
        case .signingIn: return "Signing in…"
        case .failed: return "Sign-in failed"
        }
    }
}

/// Settings → Developer: what helps while building and testing ReGlass, kept out of the everyday Settings list: the
/// glasses' model code and serial number, and ReGlass's version. What ReGlass does goes to the unified log and to
/// events.log (`ActivityLog`). Five taps on Version show that log (`LogsView`), as five taps on the build number do on
/// a phone; from then on it stays shown.
struct DeveloperView: View {
    static let unlockKey = "reglass.developer.logsUnlocked"

    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Set by the fifth tap on Version; kept across launches.
    @AppStorage(DeveloperView.unlockKey) private var logsUnlocked = false
    /// Taps on Version so far while the log is still hidden. Starts again each time the screen opens.
    @State private var versionTaps = 0
    private static let tapsToUnlock = 5

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            List {
                Section {
                    InfoRow(title: "Model code", value: modelCode, systemImage: "number", monospaced: true)
                    InfoRow(title: "Serial number", value: glasses.live.serial ?? glasses.paired?.serial ?? "—",
                            systemImage: "barcode", monospaced: true)
                } header: {
                    Text("Device")
                } footer: {
                    Text("Press and hold a value to copy it.")
                }
                .listRowBackground(Theme.card)
                appSection
                if logsUnlocked {
                    logsSection
                }
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // A light tap for each tap on Version, then a success on the fifth as the log appears.
        .sensoryFeedback(.impact(weight: .light), trigger: versionTaps) { _, taps in
            taps > 0 && taps < Self.tapsToUnlock
        }
        .sensoryFeedback(.success, trigger: logsUnlocked) { _, unlocked in unlocked }
    }

    private var appSection: some View {
        Section {
            if logsUnlocked {
                InfoRow(title: "Version", value: Bundle.main.shortVersion, systemImage: "info.circle", monospaced: true)
            } else {
                Button(action: tapVersion) {
                    InfoRow(title: "Version", value: Bundle.main.shortVersion, systemImage: "info.circle",
                            monospaced: true)
                }
            }
        } header: {
            Text("ReGlass")
        } footer: {
            if let unlockHint {
                Text(unlockHint)
                    .contentTransition(.numericText(countsDown: true))
            }
        }
        .listRowBackground(Theme.card)
    }

    /// From the second tap on: how many are left, as a phone counts down to developer options.
    private var unlockHint: String? {
        let left = Self.tapsToUnlock - versionTaps
        guard !logsUnlocked, versionTaps >= 2, left > 0 else { return nil }
        return left == 1 ? "Tap once more to show the log." : "Tap \(left) more times to show the log."
    }

    private func tapVersion() {
        let taps = versionTaps + 1
        withAnimation(reduceMotion ? nil : .smooth) {
            versionTaps = taps
            if taps >= Self.tapsToUnlock { logsUnlocked = true }
        }
    }

    private var logsSection: some View {
        Section {
            NavigationLink {
                LogsView()
            } label: {
                Label("Activity log", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Logs")
        } footer: {
            Text("What ReGlass did, step by step, to read or share when something goes wrong. It keeps about 2 MB, then starts over, and never holds keys or tokens.")
        }
        .listRowBackground(Theme.card)
    }

    private var modelCode: String {
        guard let model = glasses.live.model ?? glasses.paired?.model, !model.isEmpty else { return "—" }
        return model
    }
}

extension Bundle {
    var shortVersion: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
