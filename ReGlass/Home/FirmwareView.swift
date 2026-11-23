import ReGlassKit
import SwiftUI

/// Shows the running firmware and Meta's available update. After the wearer confirms, the signed update is
/// sent to the glasses and `FirmwareUpdateCover` shows progress.
struct FirmwareView: View {
    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @AppStorage(DeveloperView.unlockKey) private var developerUnlocked = false
    #endif
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24
    @State private var confirmingTarget: String?

    private var state: FirmwareUpdateState { glasses.firmwareUpdate }

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            List {
                Section {
                    InfoRow(title: "On your glasses", value: glasses.currentFirmwareVersion ?? "—", systemImage: "cpu",
                            monospaced: true)
                } footer: {
                    Text("Updates come from Meta, signed for your glasses. ReGlass sends them to your glasses over Bluetooth. Tested only with the Ray-Ban Meta Clubmaster (Audio). Other Meta glasses may use Wi-Fi or a different update process.")
                }
                .listRowBackground(Theme.card)
                Section {
                    updateRow
                } header: {
                    Text("Update")
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Firmware")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            if case .unknown = state.check { glasses.checkFirmwareUpdate() }
        }
        .onChange(of: glasses.firmwareOffer?.targetVersion) { _, _ in confirmingTarget = nil }
        .onChange(of: state.isRunning) { _, running in if running { confirmingTarget = nil } }
    }

    @ViewBuilder
    private var updateRow: some View {
        switch state.check {
        case .unknown, .checking:
            HStack(spacing: 10) {
                ArcSpinner()
                Text("Checking with Meta…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
            }
        case .upToDate(let version):
            VStack(alignment: .leading, spacing: 6) {
                status("Your glasses are up to date (\(version)).", systemImage: "checkmark.circle.fill", tint: Theme.good)
                checkAgain
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                status(message, systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
                checkAgain
            }
        case .available(let update):
            available(update)
        }
    }

    private func available(_ update: FirmwareAvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .frame(width: iconColumn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(update.targetVersion)")
                        .font(.body.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text("\(FirmwareUpdateState.size(update.bytes)) · takes \(FirmwareUpdateState.estimate(bytes: update.bytes))")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if update.powerwash {
                status("This update would erase your glasses, so ReGlass won't install it.",
                       systemImage: "exclamationmark.triangle.fill", tint: Theme.warning)
            } else if confirmingTarget == update.targetVersion {
                confirmation(update)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text("ReGlass keeps the screen on while it updates. Leave it open with your glasses nearby. They need at least \(FirmwareOtaInstaller.minimumBatteryPercent) % battery.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, iconColumn + 12)
                if let blocker = glasses.firmwareUpdateBlocker {
                    Text(blocker)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.warning)
                        .padding(.leading, iconColumn + 12)
                }
                pills {
                    Button("Update Glasses") {
                        withAnimation(Theme.Motion.inline(reduceMotion: reduceMotion)) {
                            confirmingTarget = update.targetVersion
                        }
                    }
                    .buttonStyle(CompactPillStyle(kind: .prominent))
                    .disabled(glasses.firmwareUpdateBlocker != nil)
                    #if DEBUG
                    if developerUnlocked {
                        Button("Rehearse") {
                            glasses.startFirmwareUpdate(expectedTarget: update.targetVersion, rehearsal: true)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(glasses.firmwareUpdateBlocker != nil)
                        .accessibilityHint("Sends the whole update, then stops before your glasses install it")
                    }
                    #endif
                }
                .padding(.leading, iconColumn + 12)
            }
        }
        .animation(Theme.Motion.inline(reduceMotion: reduceMotion), value: confirmingTarget)
    }

    private func confirmation(_ update: FirmwareAvailableUpdate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install version \(update.targetVersion) on your glasses?")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text("Once your glasses have the whole update, they install it and restart on their own. It can't be undone: Meta only offers the newest version.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Wake word sets are made for one firmware version. Afterwards, download the factory set again in Wake word before restoring Hey Meta; a custom set needs a version made for \(update.targetVersion).")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            pills {
                Button("Install") {
                    confirmingTarget = nil
                    glasses.startFirmwareUpdate(expectedTarget: update.targetVersion, rehearsal: false)
                }
                .buttonStyle(CompactPillStyle(kind: .prominent))
                .disabled(glasses.firmwareUpdateBlocker != nil)
                Button("Cancel") {
                    withAnimation(Theme.Motion.inline(reduceMotion: reduceMotion)) { confirmingTarget = nil }
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.leading, iconColumn + 12)
    }

    private var checkAgain: some View {
        Button("Check Again") { glasses.checkFirmwareUpdate() }
            .buttonStyle(QuietButtonStyle())
            .padding(.leading, iconColumn)
    }

    private func status(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: iconColumn)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func pills<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content() }
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }
}

