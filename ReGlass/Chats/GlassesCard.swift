import SwiftUI

/// The glasses, small, at the top of the conversations: picture, name, connection in words, and both batteries.
/// The whole card opens the glasses screen.
struct GlassesCard: View {
    let paired: PairedGlasses
    let live: GlassesLive
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var artWidth: CGFloat = 78

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if typeSize.isAccessibilitySize {
                // Large text: the picture takes its own line so the name and status get the full width.
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        art
                        Spacer(minLength: 0)
                        chevron
                    }
                    nameAndStatus
                }
            } else {
                HStack(alignment: .center, spacing: 14) {
                    art
                    nameAndStatus
                    Spacer(minLength: 0)
                    chevron
                }
            }
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            batteries
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Shows your glasses and their settings")
        .accessibilityAddTraits(.isButton)
    }

    private var connected: Bool { live.connection.isConnected }

    private var nameAndStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(paired.name)
                .displayFont(.title3)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            ConnectionLine(connection: live.connection)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
    }

    /// Grows with the text, but only so far: at the largest sizes the words need the room more than the picture.
    private var artSize: CGFloat { min(artWidth, 100) }

    /// The drawing on a small warm glow that brightens when the glasses are connected. The drawing is wide and low,
    /// centred in a square, so the frame is shorter than the square and its empty margins overflow it.
    private var art: some View {
        ZStack {
            Ellipse()
                .fill(Theme.halo)
                .frame(width: artSize * 1.05, height: artSize * 0.45)
                .blur(radius: 18)
                .opacity(connected ? 0.55 : 0.18)
            ArtImage(art: .front)
                .frame(width: artSize, height: artSize)
                .saturation(connected ? 1 : 0.6)
        }
        .frame(width: artSize, height: artSize * 0.58)
        .animation(.easeInOut(duration: 0.8), value: connected)
    }

    private var batteries: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 22))
        return layout {
            // Last known readings, not live ones: the rings dim like the battery card on the glasses screen, the
            // words beside them don't.
            BatteryChip(title: "Glasses", symbol: "eyeglasses", percent: live.battery,
                        charging: connected && live.charging, lastKnown: !connected)
            BatteryChip(title: connected && !live.caseIsLive && live.caseBattery != nil
                            ? "Case · seen " + (live.caseSeenAt?.relativeDescription ?? "earlier") : "Case",
                        symbol: "case.fill", percent: live.caseBattery,
                        charging: live.caseIsLive && live.caseCharging,
                        stale: connected && !live.caseIsLive, lastKnown: !connected)
            if !stacked { Spacer(minLength: 0) }
            if let updated = live.updatedAt, !connected {
                Text("as of \(updated.relativeDescription)")
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
        }
    }

    private var accessibilityText: String {
        var parts = [paired.name, live.connection.label]
        parts.append("Glasses battery " + spoken(live.battery, charging: connected && live.charging))
        parts.append("case battery " + spoken(live.caseBattery, charging: live.caseIsLive && live.caseCharging)
                     + (connected && !live.caseIsLive && live.caseBattery != nil
                        ? ", seen " + (live.caseSeenAt?.relativeDescription ?? "earlier") : ""))
        if let updated = live.updatedAt, !connected { parts.append("as of \(updated.relativeDescription)") }
        return parts.joined(separator: ", ")
    }

    private func spoken(_ percent: Int?, charging: Bool) -> String {
        guard let percent else { return "unknown" }
        return "\(percent) percent" + (charging ? ", charging" : "")
    }
}

/// The connection's dot and words, without a pill around them. The dot breathes while ReGlass is working on it.
private struct ConnectionLine: View {
    let connection: GlassesLive.Connection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(connection.tint.opacity(0.35))
                    .frame(width: 14, height: 14)
                    .scaleEffect(connection.isWorking && breathe ? 1.6 : 1)
                    .opacity(connection.isWorking && breathe ? 0 : 1)
                Circle().fill(connection.tint).frame(width: 8, height: 8)
            }
            .frame(width: 14, height: 14)
            Text(connection.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.opacity)
        }
        // "Connecting…" becomes "Connected": the words cross-fade as the dot turns green.
        .animation(Theme.Motion.inline(reduceMotion: reduceMotion), value: connection.label)
        .onAppear { animate() }
        .onChange(of: connection.isWorking) { _, _ in animate() }
    }

    private func animate() {
        breathe = false
        guard connection.isWorking, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { breathe = true }
    }
}

/// One battery, small: a thin ring in the battery's signal colour around the thing it belongs to, then the percent
/// (rounded, rolling digits) over its name. A bolt replaces the symbol while charging. An old reading dims the ring
/// and its symbol only; the percent and name keep their colour (and under Increase Contrast nothing dims).
private struct BatteryChip: View {
    let title: String
    let symbol: String
    let percent: Int?
    let charging: Bool
    /// An older reading (the case while the glasses are out of it).
    var stale = false
    /// The last reading before the glasses went away: the ring also loses its colour.
    var lastKnown = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var ring: CGFloat = 32

    /// The ring and the digits move to a new reading together, on one spring.
    private var readingAnimation: Animation { reduceMotion ? Theme.Motion.fade : Theme.Motion.reading }

    private var ringOpacity: Double {
        guard contrast != .increased else { return 1 }
        if stale { return 0.45 }
        return lastKnown ? 0.6 : 1
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, percent ?? 0))) / 100)
                    .stroke(Theme.batteryColor(percent, charging: charging).gradient,
                            style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(readingAnimation, value: percent)
                Image(systemName: charging ? "bolt.fill" : symbol)
                    .font(.system(size: ring * 0.36, weight: .semibold))
                    .foregroundStyle(charging ? Theme.good : Theme.textSecondary)
                    // Plugged in: the symbol morphs into the bolt (a cross-fade under Reduce Motion).
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .animation(Theme.Motion.inline(reduceMotion: reduceMotion), value: charging)
            }
            .padding(1.75)
            .frame(width: ring, height: ring)
            .opacity(ringOpacity)
            .saturation(lastKnown ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.6), value: ringOpacity)
            .animation(.easeInOut(duration: 0.8), value: lastKnown)
            VStack(alignment: .leading, spacing: 1) {
                Text(percent.map { "\($0)%" } ?? "—")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    // Digits roll down as the battery drains and up as it charges.
                    .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(percent ?? 0)))
                    .animation(readingAnimation, value: percent)
                    .foregroundStyle(Theme.ink)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

/// In the glasses card's place while there are no glasses: setup put off with Not Now, or the glasses forgotten in
/// Settings. The picture, unlit, what connecting brings, and Set Up, which opens setup over the home (its close button
/// comes back here). Also the glasses screen's content then.
struct ConnectGlassesCard: View {
    @EnvironmentObject private var glasses: GlassesController
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var artWidth: CGFloat = 78

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        VStack(alignment: .leading, spacing: 14) {
            layout {
                art
                VStack(alignment: .leading, spacing: 5) {
                    Text("Connect your glasses")
                        .displayFont(.title3)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Their batteries and status show here, and ReGlass answers through them.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Set Up") { glasses.showingSetup = true }
                .buttonStyle(CompactPillStyle(kind: .prominent))
                .accessibilityLabel("Set Up Glasses")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .contentSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// The cut-out, unlit and greyed like disconnected glasses.
    private var art: some View {
        let size = min(artWidth, 100)
        return ZStack {
            Ellipse()
                .fill(Theme.halo)
                .frame(width: size * 1.05, height: size * 0.45)
                .blur(radius: 18)
                .opacity(0.18)
            ArtImage(art: .front)
                .frame(width: size, height: size)
                .saturation(0.6)
        }
        .frame(width: size, height: size * 0.58)
    }
}
