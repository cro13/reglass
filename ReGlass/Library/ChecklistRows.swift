import SwiftUI

// The checklists on the Reminders page: one per category with things to do or buy (`ReGlassItem`). Each open item is a
// compact card row with a circle; tapping it fills the circle copper, strikes the words through and drops the row into
// the dimmed "Got 3 · Clear" group under its list. Tapping a got one brings it back. The page owns the actions (tick,
// swipes, the press-and-hold menu, Undo); these are only the rows.

/// One category's checklist as the page shows it.
struct ReminderChecklist: Identifiable {
    /// The category's shown name.
    let name: String
    /// Still to do or buy, in the order added.
    let open: [ReGlassItem]
    /// Ticked off, most recently first.
    let got: [ReGlassItem]

    var id: String { name }

    /// How many got rows show; "Got 40" still counts them all, and Clear clears them all.
    static let gotShown = 30

    /// The checklists under `chip` (every one under All), in `order`: a list for each category with something open or
    /// got. Names the order doesn't know yet come last.
    static func make(_ items: [ReGlassItem], in chip: String?, order: [String]) -> [ReminderChecklist] {
        var names: [String] = []
        var open: [String: [ReGlassItem]] = [:]
        var got: [String: [ReGlassItem]] = [:]
        for item in items where CategoryChip.files(item.category, under: chip) {
            let name = order.first { LibraryCategory.same($0, item.category) }
                ?? names.first { LibraryCategory.same($0, item.category) }
                ?? item.category
            if !names.contains(name) { names.append(name) }
            if item.isOpen { open[name, default: []].append(item) } else { got[name, default: []].append(item) }
        }
        let rank = { (name: String) in order.firstIndex(of: name) ?? Int.max }
        return names.enumerated()
            .sorted { a, b in rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset }
            .map { _, name in
                ReminderChecklist(name: name,
                          open: (open[name] ?? []).sorted { $0.created < $1.created },
                          got: (got[name] ?? []).sorted { ($0.completed ?? $0.created) > ($1.completed ?? $1.created) })
            }
    }
}

/// One thing still to do or buy: the circle, the words, and its topic on the right. The whole row ticks it off.
struct ChecklistItemRow: View {
    let item: ReGlassItem
    /// Ticked a moment ago: the circle fills and the words strike through before the row moves down.
    let ticked: Bool
    let tick: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: tick) {
            HStack(spacing: 8) {
                ChecklistCircle(checked: ticked)
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(Theme.ink.opacity(ticked ? 0.55 : 1))
                    .strikethrough(ticked, color: Theme.textTertiary)
                    .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let topic = item.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 4)
            .padding(.trailing, 16)
            .padding(.vertical, 2)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.topic].compactMap { $0 }.joined(separator: ", "))
        .accessibilityValue(ticked ? "Got it" : "")
        .accessibilityHint("Ticks it off")
        .accessibilityAddTraits(.isButton)
    }
}

/// "Got 3 · Clear": the head of a checklist's dimmed group of ticked-off things. Clear removes them (with Undo).
struct ChecklistGotHeader: View {
    let count: Int
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text("Got \(count)")
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
                .contentTransition(.numericText())
                .accessibilityLabel("Got \(count)")
            Text("·")
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
            Button(action: clear) {
                Text("Clear")
                    .foregroundStyle(Theme.actionRed)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(SoftPressStyle())
            .accessibilityLabel("Clear the \(count) Got")
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.semibold))
        .padding(.leading, 10)
    }
}

/// One got thing: a dimmed filled circle and the words struck through in Text Secondary. A tap brings it back. Only
/// the circle dims (and not under Increase Contrast): the words keep their contrast, quieter by colour alone.
struct ChecklistGotRow: View {
    let item: ReGlassItem
    let bringBack: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: bringBack) {
            HStack(spacing: 8) {
                ChecklistCircle(checked: true)
                    .opacity(contrast == .increased ? 1 : 0.5)
                Text(item.title)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .strikethrough(true, color: Theme.textTertiary)
                    .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 4)
            .padding(.trailing, 16)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue("Got it")
        .accessibilityHint("Puts it back on the list")
        .accessibilityAddTraits(.isButton)
    }
}

/// Nothing left open on a list that has got things.
struct ChecklistDoneLine: View {
    let category: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.body)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(LibraryCategory.same(category, LibraryCategory.shopping) ? "Nothing left to buy." : "Nothing left on \(category).")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The circle at the start of an item: an empty ring, or filled copper with a dark check. Ticking fills it with a
/// spring, the check springs in, and one copper ring spreads from it and fades (none under Reduce Motion).
struct ChecklistCircle: View {
    let checked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.control, lineWidth: 1.5)
                .opacity(checked ? 0 : 1)
            // The fill and check grow in; under Reduce Motion they only fade.
            Circle()
                .fill(Theme.accentFill)
                .scaleEffect(checked || reduceMotion ? 1 : 0.3)
                .opacity(checked ? 1 : 0)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.46, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .scaleEffect(checked || reduceMotion ? 1 : 0.4)
                .opacity(checked ? 1 : 0)
        }
        .frame(width: size, height: size)
        .modifier(TickBurst(checked: checked))
        .frame(width: max(44, size + 16), height: max(44, size + 16))
        .accessibilityHidden(true)
    }
}

/// One copper ring that spreads from a circle and fades the moment it's ticked: a list item's circle, a reminder's
/// ring. Nothing under Reduce Motion, nor when it's unticked.
struct TickBurst: ViewModifier {
    let checked: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            Circle()
                .stroke(Theme.accentFill, lineWidth: 1.5)
                .keyframeAnimator(initialValue: Burst(), trigger: checked) { ring, burst in
                    ring.scaleEffect(burst.scale).opacity(burst.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.scale) {
                        MoveKeyframe(1)
                        CubicKeyframe(2.1, duration: 0.55)
                    }
                    KeyframeTrack(\.opacity) {
                        MoveKeyframe(checked && !reduceMotion ? 0.7 : 0)
                        CubicKeyframe(0, duration: 0.55)
                    }
                }
        }
    }

    private struct Burst {
        var scale = 1.0
        var opacity = 0.0
    }
}
