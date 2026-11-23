import SwiftUI

/// The glasses at a glance: picture, connection, batteries, and the way into Settings. Pushed from the glasses card
/// at the top of the conversations. With no glasses (forgotten while it was open), the card that sets them up.
struct HomeView: View {
    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ReGlassBackdrop()
            ScrollView {
                VStack(spacing: 16) {
                    if let paired = glasses.paired {
                        HeroCard(paired: paired, live: glasses.live)
                        if let explanation = glasses.live.connection.explanation {
                            AttentionCard(connection: glasses.live.connection, explanation: explanation)
                                .transition(reduceMotion ? .opacity
                                            : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                        }
                        BatteryCard(live: glasses.live, notChargingInCase: glasses.notChargingInCase)
                        StateCard(live: glasses.live)
                        AudioCard()
                    } else {
                        // Forgotten while this screen was open (Settings closes back here): the way to set them up.
                        ConnectGlassesCard()
                    }
                    settingsLink
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
                // The attention card comes and goes with the connection: the cards below make room with a spring
                // instead of jumping.
                .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86),
                           value: glasses.live.connection.explanation)
            }
            .refreshable { glasses.refresh() }
        }
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        // No gear up here: the settings link row below is this screen's one way into Settings (the three home pages
        // keep theirs in their headers).
    }

    private var settingsLink: some View {
        NavigationLink(value: AppRoute.settings) {
            HStack(spacing: 14) {
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Glasses Settings")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text("Connection, device info, Meta account")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .contentShape(Rectangle())
            .contentCard(cornerRadius: 22, padding: 16)
        }
        .buttonStyle(CardPressStyle())
    }
}

// MARK: Cards

private struct HeroCard: View {
    let paired: PairedGlasses
    let live: GlassesLive

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Ellipse()
                    .fill(Theme.halo)
                    .frame(width: 280, height: 120)
                    .blur(radius: 55)
                    .opacity(live.connection.isConnected ? 0.55 : 0.18)
                    .animation(.easeInOut(duration: 0.8), value: live.connection.isConnected)
                ArtImage(art: .hero)
                    .frame(height: 170)
                    .saturation(live.connection.isConnected ? 1 : 0.6)
            }
            .frame(height: 190)
            VStack(spacing: 4) {
                Text(paired.name)
                    .displayFont(.title2)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)   // wraps at large text sizes instead of cutting the name off
                Text(paired.productLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            StatusPill(connection: live.connection)
        }
        .frame(maxWidth: .infinity)
        .contentCard(cornerRadius: 30, padding: 22)
    }
}

private struct AttentionCard: View {
    @EnvironmentObject private var glasses: GlassesController
    let connection: GlassesLive.Connection
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(connection.tint)
                    .font(.body.weight(.semibold))
                Text(explanation)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch connection {
            case .refused:
                // Setup tries ReGlass's saved key first and only offers a transfer if the glasses still refuse it.
                Button("Reconnect or Set Up Again") { glasses.showingSetup = true }
                    .buttonStyle(PrimaryButtonStyle())
            case .idle:
                Button("Connect") {
                    if glasses.stayConnected { glasses.connectIfReady() } else { glasses.stayConnected = true }
                }
                .buttonStyle(SecondaryButtonStyle())
            case .keyUnavailable:
                Button("Try Again") { glasses.connectIfReady() }
                    .buttonStyle(SecondaryButtonStyle())
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 22, padding: 16)
    }

    private var icon: String {
        switch connection {
        case .searching: return "antenna.radiowaves.left.and.right"
        case .bluetoothOff, .bluetoothDenied: return "bolt.horizontal.circle"
        case .refused: return "exclamationmark.triangle.fill"
        case .keyUnavailable: return "lock.fill"
        default: return "info.circle.fill"
        }
    }
}

private struct BatteryCard: View {
    let live: GlassesLive
    let notChargingInCase: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Battery")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                if let updated = live.updatedAt, !live.connection.isConnected {
                    Text("as of \(updated.relativeDescription)")
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            // Last known readings, not live ones: the rings dim like the glasses picture, with no charging bolt. Their
            // words stay at full colour, so they keep their contrast.
            HStack {
                Spacer()
                BatteryRing(percent: live.battery, charging: connected && live.charging, title: "Glasses",
                            lastKnown: !connected)
                Spacer()
                BatteryRing(percent: live.caseBattery, charging: live.caseIsLive && live.caseCharging, title: "Case",
                            stale: connected && !live.caseIsLive && live.caseBattery != nil,
                            note: connected && !live.caseIsLive && live.caseBattery != nil
                                ? "seen " + (live.caseSeenAt?.relativeDescription ?? "earlier") : nil,
                            lastKnown: !connected)
                Spacer()
            }
            if notChargingInCase {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                        .font(.subheadline.weight(.semibold))
                    Text("Seated in the case, not charging — check how they rest on the nose bridge.")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
        .contentCard()
    }

    private var connected: Bool { live.connection.isConnected }
}

private struct StateCard: View {
    let live: GlassesLive
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Three tiles in a row; at accessibility text sizes they stack so nothing gets cut off.
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            tile(icon: wornIcon, title: wornTitle, subtitle: "Wearing")
            tile(icon: powerIcon, title: powerTitle, subtitle: "Power")
            tile(icon: "cpu", title: live.firmware.map(shortFirmware) ?? "—", subtitle: "Firmware")
        }
    }

    /// Wearing and charging are only known while connected; a stale "Not charging" would be a wrong answer.
    private var connected: Bool { live.connection.isConnected }

    private var wornTitle: String {
        guard connected else { return "—" }
        if live.inCase == true { return "In case" }
        guard let worn = live.worn else { return "—" }
        return worn ? "On" : "Off"
    }

    private var wornIcon: String {
        guard connected else { return "eyeglasses" }
        if live.inCase == true { return "case.fill" }
        return live.worn == false ? "eyeglasses.slash" : "eyeglasses"
    }

    private var powerTitle: String {
        guard connected else { return "—" }
        return live.charging ? "Charging" : "Not charging"
    }

    private var powerIcon: String {
        guard connected else { return "bolt" }
        return live.charging ? "bolt.fill" : "bolt.slash"
    }

    private func shortFirmware(_ build: String) -> String {
        build.count > 12 ? String(build.prefix(12)) + "…" : build
    }

    private func tile(icon: String, title: String, subtitle: String) -> some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(HStackLayout(alignment: .center, spacing: 14))
                             : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return layout {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: stacked ? 2 : 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(stacked ? nil : 1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 20, padding: 14)
        .accessibilityElement(children: .combine)
    }
}

private struct AudioCard: View {
    @EnvironmentObject private var glasses: GlassesController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sound")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Toggle(isOn: $glasses.adaptiveVolume) {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Adaptive Volume")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Adjusts to the noise around you")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .tint(Theme.accentFill)
            Divider().overlay(Theme.hairline)
            Toggle(isOn: $glasses.spatialAudio) {
                HStack(spacing: 12) {
                    Image(systemName: "person.spatialaudio.stereo.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Spatial Audio")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Head-tracked stereo on the glasses")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .tint(Theme.accentFill)
        }
        .contentCard()
    }
}
