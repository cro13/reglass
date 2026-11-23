import SwiftUI

// MARK: Connection status

extension GlassesLive.Connection {
    var label: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .searching: return "Looking for glasses"
        case .bluetoothOff: return "Bluetooth is off"
        case .bluetoothDenied: return "Bluetooth not allowed"
        case .refused: return "Needs attention"
        case .keyUnavailable: return "Unlock your iPhone"
        }
    }

    /// One sentence on what's going on and what to do, or nil when nothing needs saying.
    var explanation: String? {
        switch self {
        case .idle: return "Stay connected is off, so ReGlass isn't connecting to your glasses."
        case .connecting, .connected: return nil
        case .searching(let why): return why
        case .bluetoothOff: return "Turn on Bluetooth in Control Center to reach your glasses."
        case .bluetoothDenied: return "Allow Bluetooth for ReGlass in Settings → ReGlass."
        case .refused: return "Your glasses no longer accept ReGlass's key. They may have been set up again with Meta AI. Reconnect, or set them up again."
        case .keyUnavailable: return "ReGlass keeps its key locked until this iPhone has been unlocked once."
        }
    }

    var tint: Color {
        switch self {
        case .connected: return Theme.good
        case .connecting, .searching: return Theme.accent
        case .idle: return Theme.textTertiary
        case .bluetoothOff, .bluetoothDenied, .keyUnavailable: return Theme.warning
        case .refused: return Theme.critical
        }
    }

    var isWorking: Bool {
        switch self {
        case .connecting, .searching: return true
        default: return false
        }
    }
}

/// Dot + words. The dot breathes while ReGlass is working on it.
struct StatusPill: View {
    let connection: GlassesLive.Connection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        HStack(spacing: 8) {
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
                .foregroundStyle(Theme.ink)
                .contentTransition(.opacity)
        }
        .animation(Theme.Motion.inline(reduceMotion: reduceMotion), value: connection.label)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassSurface(in: Capsule())
        .onAppear { animate() }
        .onChange(of: connection.isWorking) { _, _ in animate() }
        .accessibilityElement(children: .combine)
    }

    private func animate() {
        breathe = false
        guard connection.isWorking, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { breathe = true }
    }
}

// MARK: Battery

/// A ring gauge for one battery, with the percent in the middle and a bolt while charging.
///
/// An old reading dims the ring only, never the words: the percent, title and note keep their full colour so they
/// stay readable (4.5:1 or more), and under Increase Contrast nothing dims at all.
struct BatteryRing: View {
    let percent: Int?
    let charging: Bool
    let title: String
    var size: CGFloat = 84
    /// An older reading (the case while the glasses are out of it): the ring dims, and `note` says how old.
    var stale = false
    var note: String?
    /// The last reading before the glasses went away: the ring dims and loses its colour.
    var lastKnown = false
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How far the ring dims for an old reading.
    private var ringOpacity: Double {
        guard contrast != .increased else { return 1 }
        if stale { return 0.45 }
        return lastKnown ? 0.6 : 1
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                ZStack {
                    Circle().stroke(Theme.track, lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: CGFloat(max(0, min(100, percent ?? 0))) / 100)
                        .stroke(Theme.batteryColor(percent, charging: charging).gradient,
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.reading, value: percent)
                }
                .opacity(ringOpacity)
                .saturation(lastKnown ? 0.4 : 1)
                .animation(.easeInOut(duration: 0.6), value: ringOpacity)
                .animation(.easeInOut(duration: 0.8), value: lastKnown)
                VStack(spacing: 0) {
                    if charging {
                        Image(systemName: "bolt.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.good)
                    }
                    Text(percent.map { "\($0)%" } ?? "—")
                        .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(percent ?? 0)))
                        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.reading, value: percent)
                        .foregroundStyle(Theme.ink)
                }
            }
            .frame(width: size, height: size)
            VStack(spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) battery")
        .accessibilityValue((percent.map { "\($0) percent\(charging ? ", charging" : "")" } ?? "unknown")
                            + (note.map { ", \($0)" } ?? ""))
    }
}

// MARK: Small pieces

/// A label/value line for settings cards.
struct InfoRow: View {
    let title: String
    let value: String
    var systemImage: String?
    var monospaced = false
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The icon column grows with the text, so large icons never run into the title.
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24

    var body: some View {
        HStack(alignment: stacked ? .firstTextBaseline : .center, spacing: 12) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(Theme.accent)
                    .frame(width: iconColumn)
            }
            if stacked {
                // Accessibility text sizes: value under the title, as iOS's own lists do, instead of squeezing both.
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.ink)
                    valueText.multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            } else {
                Text(title).foregroundStyle(Theme.ink)
                Spacer(minLength: 12)
                valueText
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var stacked: Bool { typeSize.isAccessibilitySize }

    private var valueText: some View {
        Text(value)
            .font(monospaced ? .callout.monospaced() : .callout)
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
    }
}

/// Signal strength as three rising bars.
struct SignalBars: View {
    let bars: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...3, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level <= bars ? Theme.ink : Theme.track)
                    .frame(width: 4, height: CGFloat(4 + level * 4))
            }
        }
        .accessibilityLabel("Signal \(bars) of 3")
    }
}

/// Rings expanding from the glasses while ReGlass listens for them. With Reduce Motion: still, faint rings.
struct SearchPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expand = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                if reduceMotion {
                    Circle()
                        .strokeBorder(Theme.accentFill, lineWidth: 1.5)
                        .scaleEffect(0.55 + Double(i) * 0.2)
                        .opacity(0.45 - Double(i) * 0.12)
                } else {
                    Circle()
                        .strokeBorder(Theme.accentFill, lineWidth: 1.5)
                        .scaleEffect(expand ? 1.0 : 0.35)
                        .opacity(expand ? 0 : 0.8)
                        .animation(.easeOut(duration: 2.4).repeatForever(autoreverses: false).delay(Double(i) * 0.8),
                                   value: expand)
                }
            }
        }
        .onAppear { expand = true }
        .accessibilityHidden(true)
    }
}

// MARK: Motion

/// Rises and fades in the first time it appears, `index` beats after its siblings, so a new screen's pieces arrive
/// one after another. Under Reduce Motion: a short fade in place. Not `enabled` when it first appears: it's simply
/// there, and stays put even if `enabled` turns on later (the view's identity doesn't change either way).
struct Entrance: ViewModifier {
    let index: Int
    var distance: CGFloat = 14
    var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var skipped = false

    func body(content: Content) -> some View {
        let visible = shown || skipped || !enabled
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : distance)
            .onAppear {
                guard !shown else { return }
                guard enabled else {
                    skipped = true
                    return
                }
                let animation: Animation = reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.55, dampingFraction: 0.84).delay(0.05 + 0.06 * Double(min(index, 8)))
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    /// See `Entrance`.
    func entrance(_ index: Int, distance: CGFloat = 14, enabled: Bool = true) -> some View {
        modifier(Entrance(index: index, distance: distance, enabled: enabled))
    }
}

/// A slow up-and-down drift, as if floating. Holds still while inactive and under Reduce Motion.
struct Drift: ViewModifier {
    var active = true
    var amplitude: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.phaseAnimator([-1.0, 1.0]) { view, phase in
            view.offset(y: active && !reduceMotion ? phase * amplitude : 0)
        } animation: { _ in
            .easeInOut(duration: 1.6)
        }
    }
}

/// ReGlass's waiting indicator: a copper arc with a fading tail, turning on a faint track. Under Reduce Motion it is
/// the system spinner, which reads as "working" without sweeping motion.
struct ArcSpinner: View {
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                ProgressView().controlSize(.small).tint(Theme.accentFill)
            } else {
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                    ZStack {
                        Circle().stroke(Theme.track, lineWidth: lineWidth)
                        Circle()
                            .trim(from: 0, to: 0.34)
                            // The tail fades in through the fill; the head is the brighter text tone.
                            .stroke(AngularGradient(colors: [Theme.accentFill.opacity(0), Theme.accentFill, Theme.accent],
                                                    center: .center, startAngle: .degrees(0), endAngle: .degrees(122)),
                                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                            .rotationEffect(.degrees(turn * 360))
                    }
                    .padding(lineWidth / 2)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A copper SF Symbol in a halo of warm light, inside a faint orbit. While ReGlass is working (`working`) the halo
/// breathes, ripples spread from it and a point of light circles the orbit; at rest it all holds still, so the
/// motion always means "something is happening". The symbol morphs when it changes. Under Reduce Motion everything
/// holds still and the symbol cross-fades. `size` is the orbit's diameter; the view takes 1.6 × that.
struct ReGlassEmblem: View {
    let symbol: String
    var working = false
    var size: CGFloat = 72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the current stretch of work began: the point of light sets off from the top each time, never jumping.
    @State private var workStarted = Date()

    private var moving: Bool { working && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !moving)) { context in
            let t = moving ? context.date.timeIntervalSince(workStarted) : 0
            ZStack {
                // Warm light (`Theme.halo`). Only its opacity breathes, and only while working.
                Circle()
                    .fill(Theme.halo)
                    .frame(width: size * 1.1, height: size * 1.1)
                    .blur(radius: size * 0.42)
                    .opacity(moving ? 0.42 + 0.12 * sin(t * 2 * .pi / 3.6) : 0.42)
                if moving {
                    ForEach(0..<2, id: \.self) { i in
                        let phase = (t / 2.2 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .strokeBorder(Theme.accentFill, lineWidth: 1)
                            .frame(width: size, height: size)
                            .scaleEffect(1 + phase * 0.55)
                            .opacity((1 - phase) * 0.45 * min(1, t * 2))
                    }
                }
                Circle()
                    .strokeBorder(Theme.hairline, lineWidth: 1)
                    .frame(width: size, height: size)
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 5, height: 5)
                    .offset(y: -size / 2)
                    .rotationEffect(.radians(t * 2 * .pi / 6.5))
                    .opacity(moving ? 0.9 : 0)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .ultraLight))
                    .foregroundStyle(Theme.accentGradient)
                    .contentTransition(reduceMotion ? ContentTransition.opacity : ContentTransition.symbolEffect(.replace))
                    .animation(.spring(response: 0.45, dampingFraction: 0.7), value: symbol)
            }
            .animation(.easeInOut(duration: 0.35), value: moving)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .onChange(of: working, initial: true) { _, now in if now { workStarted = .now } }
        .accessibilityHidden(true)
    }
}

/// Words that arrive a sentence at a time (a reply as ReGlass says it): what's already there stays perfectly still and
/// only the newest sentence fades in, rising a couple of points, so the eye goes to what's new instead of the whole
/// paragraph flickering. Under Reduce Motion the new sentence only fades. Style it like any `Text` (font, colour,
/// line spacing); it's one paragraph, selectable as a whole.
///
///     StreamingText(sentences: reply.sentences)
///         .font(.body)
///         .foregroundStyle(Theme.ink)
struct StreamingText: View {
    let sentences: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        text
            .keyframeAnimator(initialValue: 1.0, trigger: sentences.count) { content, progress in
                content.textRenderer(FreshSentenceRenderer(progress: progress, rise: reduceMotion ? 0 : 3))
            } keyframes: { _ in
                MoveKeyframe(0.0)
                CubicKeyframe(1.0, duration: reduceMotion ? 0.25 : 0.5)
            }
    }

    /// Every sentence but the last as they are; the last one marked, for the renderer to bring in.
    private var text: Text {
        guard let last = sentences.last else { return Text(verbatim: "") }
        let earlier = sentences.dropLast().joined(separator: " ")
        let fresh = Text(verbatim: earlier.isEmpty ? last : " " + last).customAttribute(FreshSentence())
        return earlier.isEmpty ? fresh : Text("\(Text(verbatim: earlier))\(fresh)")
    }
}

/// Marks the newest sentence in a `StreamingText`.
private struct FreshSentence: TextAttribute {}

/// Draws a `StreamingText`: the marked sentence at `progress` opacity, `rise` points low at the start.
private struct FreshSentenceRenderer: TextRenderer, Animatable {
    var progress: Double
    var rise: CGFloat

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                if run[FreshSentence.self] != nil {
                    var fresh = context
                    fresh.opacity = progress
                    fresh.translateBy(x: 0, y: (1 - progress) * rise)
                    fresh.draw(run)
                } else {
                    context.draw(run)
                }
            }
        }
    }
}

/// Rings that spread once from the centre and fade: a moment of success. Nothing under Reduce Motion.
struct BurstRings: View {
    var count = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var burst = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                ForEach(0..<count, id: \.self) { i in
                    Circle()
                        .strokeBorder(Theme.accentFill, lineWidth: 1.5)
                        .scaleEffect(burst ? 1 : 0.3)
                        .opacity(burst ? 0 : 0.75)
                        .animation(.easeOut(duration: 1.3).delay(Double(i) * 0.18), value: burst)
                }
            }
        }
        .onAppear { burst = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Points of light running from left to right, with a key riding along: ReGlass's key going from this iPhone to the
/// glasses. Under Reduce Motion the dots hold at an even glow and the key rests in the middle.
struct HandoverFlow: View {
    var dots = 5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let phase = reduceMotion ? 0.5 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(0..<dots, id: \.self) { i in
                            let position = (Double(i) + 0.5) / Double(dots)
                            let near = max(0, 1 - abs(phase - position) * 3.2)
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 4, height: 4)
                                .opacity(reduceMotion ? 0.5 : 0.18 + 0.82 * near)
                                .scaleEffect(reduceMotion ? 1 : 1 + 0.6 * near)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    Image(systemName: "key.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .rotationEffect(.degrees(-45))
                        .position(x: width * phase, y: geo.size.height / 2 - 14)
                        .opacity(reduceMotion ? 1 : min(1, min(phase, 1 - phase) * 6))
                }
                .frame(height: geo.size.height)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A band of copper light that glints across its frame every few seconds. Mask it to a drawing (see `GlowingArt`): masked
/// to the glasses, it runs along their lines as a sheen of the accent. Callers leave it out under Reduce Motion.
struct GlintBand: View {
    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            LinearGradient(colors: [.clear, Theme.accent.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: width * 0.28, height: geo.size.height * 1.4)
                .rotationEffect(.degrees(16))
                .frame(width: width, height: geo.size.height, alignment: .leading)
                .keyframeAnimator(initialValue: -0.4, repeating: true) { band, x in
                    band.offset(x: width * x)
                } keyframes: { _ in
                    KeyframeTrack {
                        LinearKeyframe(-0.4, duration: 1.6)
                        CubicKeyframe(1.15, duration: 1.3)
                        LinearKeyframe(1.15, duration: 2.6)
                    }
                }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A checkmark line for reassurance lists.
struct CheckLine: View {
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 26
    let text: String
    var systemImage = "checkmark.circle.fill"

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: iconColumn)   // one icon column, so every line's text starts at the same edge
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension Date {
    /// "just now", "5 min ago", …
    var relativeDescription: String {
        if Date().timeIntervalSince(self) < 45 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
