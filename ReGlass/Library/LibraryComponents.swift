import SwiftUI

// Pieces shared by the home's Notes and Reminders pages, their composers and the note screen.

// MARK: Where it came from

extension LibrarySource {
    /// The small mark on a row: a mic for something said, a keyboard for something typed on this iPhone.
    var markSymbol: String {
        switch self {
        case .voice: return "mic.fill"
        case .typed: return "keyboard"
        }
    }

    /// How it was made, in words ("Said to your glasses").
    var madeHow: String {
        switch self {
        case .voice: return "Said to your glasses"
        case .typed: return "Typed on your iPhone"
        }
    }
}

// MARK: Rows and headers

extension View {
    /// A list row that is only its content: no system background, separator or default insets.
    func libraryRow(top: CGFloat, bottom: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// A group's name over its rows ("Coming up", "Earlier", a checklist's "Shopping"), with an optional count beside it
/// and, for a category, its symbol in front.
struct LibrarySectionHeader: View {
    let title: String
    var count: Int?
    /// A checklist's category: its symbol, in its colour, before the title.
    var category: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let category {
                Image(category: category)
                    .font(.footnote)
                    .foregroundStyle(LibraryCategory.color(category))
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            if let count {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The entrance for the rows on screen when a page opens; rows scrolled to later just appear.
struct OptionalEntranceIndex: ViewModifier {
    let index: Int?

    func body(content: Content) -> some View {
        if let index { content.entrance(index) } else { content }
    }
}

// MARK: Teaching the voice phrase

/// What to say to the glasses, on a quiet capsule (content, not a control, so not Liquid Glass), with a waveform that
/// ripples twice as the phrase arrives, as if just said, then rests (still under Reduce Motion). Shown, not
/// instructed: one example, no steps.
struct SpokenPhrase: View {
    let phrase: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var said = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.variableColor.iterative, options: .repeat(2), value: said)
                .accessibilityHidden(true)
                .task {
                    // After the capsule's own entrance has landed.
                    guard !reduceMotion else { return }
                    try? await Task.sleep(for: .milliseconds(650))
                    said = true
                }
            Text(phrase)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentSurface(in: Capsule())
    }
}

/// Before the first note or reminder: ReGlass's emblem, what this place is for, the phrase that fills it, and a line
/// about the bar below. Its pieces arrive one after another, then hold still: nothing here is happening yet, so
/// nothing moves on its own.
struct LibraryEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    let phrase: String
    let footer: String

    var body: some View {
        VStack(spacing: 14) {
            StillEmblem(symbol: symbol, size: 60)
                .padding(.bottom, -8)
                .entrance(2)
            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }
            .entrance(3)
            SpokenPhrase(phrase: phrase)
                .padding(.top, 4)
                .entrance(4)
            Text(footer)
                .font(.footnote)
                .foregroundStyle(Theme.textTertiary)
                .entrance(5)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// `ReGlassEmblem` at rest: the copper symbol in its halo of warm light and its faint ring, without the breathing glow
/// and the circling point of light, which belong to ReGlass working on something. Same size and look, so an empty page
/// matches the rest of ReGlass.
struct StillEmblem: View {
    let symbol: String
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.halo)
                .frame(width: size * 1.1, height: size * 1.1)
                .blur(radius: size * 0.42)
                .opacity(0.42)
            Circle()
                .strokeBorder(Theme.hairline, lineWidth: 1)
                .frame(width: size, height: size)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .ultraLight))
                .foregroundStyle(Theme.accentGradient)
        }
        .frame(width: size * 1.6, height: size * 1.6)
        .accessibilityHidden(true)
    }
}

// MARK: Motion

/// A button that leaves its own label alone and only reports when it's held, so the card around it can sink as a
/// whole (`CardSink`). For a reminder's row, whose ring is a button of its own and can't sit inside another one.
struct PressReportingStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, now in pressed = now }
    }
}

/// A card answering a press, as a note's card does (`CardPressStyle`): down quickly to 98 %, back with a little bounce.
/// A dim instead under Reduce Motion.
struct CardSink: ViewModifier {
    let pressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? 0.98 : 1)
            .opacity(pressed && reduceMotion ? 0.75 : 1)
            .animation(pressed ? .spring(response: 0.18, dampingFraction: 0.8) : .spring(response: 0.4, dampingFraction: 0.52),
                       value: pressed)
    }
}

extension EnvironmentValues {
    /// Where an open note zooms from: the Notes tab's namespace, set on its navigation stack. Nil elsewhere, so a note
    /// opened any other way slides in as usual.
    @Entry var noteZoom: Namespace.ID? = nil
}

/// ReGlass's dissolve: a soft blur crossfade with a hint of scale. A plain fade under Reduce Motion.
private struct BlurDissolve: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .blur(radius: hidden ? 6 : 0)
            .opacity(hidden ? 0 : 1)
            .scaleEffect(hidden ? 0.97 : 1)
    }
}

extension AnyTransition {
    /// See `BlurDissolve`.
    static func libraryDissolve(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: BlurDissolve(hidden: true), identity: BlurDissolve(hidden: false))
    }
}

/// A small control you press: sinks a little and springs back. A dim instead under Reduce Motion.
struct SoftPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(configuration.isPressed ? .spring(response: 0.18, dampingFraction: 0.8)
                                               : .spring(response: 0.4, dampingFraction: 0.55),
                       value: configuration.isPressed)
    }
}

// MARK: Times

extension Date {
    /// After "Modified": "just now", "12 min ago", "at 14:32" (earlier today), "yesterday", "on Monday" (this past
    /// week), then "on 26 Oct" (with the year once it isn't this year).
    var modifiedPhrase: String {
        let now = Date.now
        let seconds = now.timeIntervalSince(self)
        let calendar = Calendar.current
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDateInToday(self) { return "at " + formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(self) { return "yesterday" }
        if seconds < 6 * 86_400 { return "on " + formatted(.dateTime.weekday(.wide)) }
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        let thisYear = calendar.isDate(self, equalTo: now, toGranularity: .year)
        return "on " + (thisYear ? formatted(style) : formatted(style.year()))
    }

    /// "Today", "Tomorrow", "Yesterday", "Thu" (within six days either way), then "29 Oct".
    var libraryDay: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInTomorrow(self) { return "Tomorrow" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        if abs(timeIntervalSinceNow) < 6 * 86_400 { return formatted(.dateTime.weekday(.abbreviated)) }
        let style = Date.FormatStyle.dateTime.day().month(.abbreviated)
        return calendar.isDate(self, equalTo: .now, toGranularity: .year) ? formatted(style) : formatted(style.year())
    }

    /// "Today 18:00", "Tomorrow 09:00", "Thu 09:00", "29 Oct 09:00".
    var libraryDayTime: String {
        "\(libraryDay) \(formatted(date: .omitted, time: .shortened))"
    }
}

/// "in 10 min", "in 3 hr, 20 min", "in 2 days, 4 hr"; "in under a minute" at the end.
func libraryTimeUntil(_ seconds: TimeInterval) -> String {
    guard seconds >= 60 else { return "in under a minute" }
    let rounded = (seconds / 60).rounded(.up) * 60
    let text = Duration.seconds(rounded).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated,
                                                          maximumUnitCount: 2))
    return "in " + text
}
