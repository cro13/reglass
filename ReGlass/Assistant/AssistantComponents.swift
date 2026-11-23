import ReGlassAssistant
import SwiftUI

/// A compact pill for actions inside rows and cards (Test, Replace, Play now…): a 44pt target that hugs its label.
/// `prominent` is the copper pill for the row's main step, `glass` the usual choice, `destructive` a glass pill with
/// words in the destructive red (`Theme.actionRed`). Springs down on press; dims instead under Reduce Motion.
struct CompactPillStyle: ButtonStyle {
    enum Kind {
        case prominent, glass, destructive
    }

    var kind: Kind = .glass
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .labelStyle(CompactPillLabelStyle())
            .font(.subheadline.weight(.semibold))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: 44)
            .foregroundStyle(foreground)
            .background {
                if kind == .prominent {
                    Capsule().fill(isEnabled ? Theme.accentFill : Theme.track)
                }
            }
            .modifier(GlassIfNeeded(enabled: kind != .prominent))
            .contentShape(Capsule())
            .pressFeedback(pressed)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: pressed) { _, now in now && kind == .prominent }
    }

    private var foreground: Color {
        switch kind {
        case .prominent: return isEnabled ? Theme.onAccent : Theme.textTertiary
        case .glass: return Theme.ink.opacity(isEnabled ? 1 : 0.4)
        case .destructive: return Theme.actionRed.opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// Symbol and words close together inside a compact pill.
private struct CompactPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

private struct GlassIfNeeded: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.glassSurface(in: Capsule(), interactive: true)
        } else {
            content
        }
    }
}

/// One line of status: a symbol (or the arc spinner while working) beside words. Colour never stands alone.
struct AssistantStatusLine: View {
    enum Tone {
        case working, good, warning, critical, info, quiet
    }

    let tone: Tone
    let text: String
    var symbol: String?
    @ScaledMetric(relativeTo: .subheadline) private var iconColumn: CGFloat = 20

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if tone == .working {
                    ArcSpinner(size: 14, lineWidth: 1.5)
                        .alignmentGuide(.firstTextBaseline) { d in d.height * 0.8 }
                } else {
                    Image(systemName: symbol ?? defaultSymbol)
                        .foregroundStyle(color)
                }
            }
            .frame(width: iconColumn)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
    }

    private var defaultSymbol: String {
        switch tone {
        case .working: return "circle"
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .info: return "info.circle"
        case .quiet: return "minus.circle"
        }
    }

    private var color: Color {
        switch tone {
        case .working, .info: return Theme.accent
        case .good: return Theme.good
        case .warning: return Theme.warning
        case .critical: return Theme.critical
        case .quiet: return Theme.textTertiary
        }
    }
}

/// A row of compact pills that wraps to a column at large text sizes.
struct PillRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content() }
            VStack(alignment: .leading, spacing: 8) { content() }
        }
    }
}

/// A list row's leading symbol column, matching `InfoRow`.
struct RowSymbol: View {
    let name: String
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24

    var body: some View {
        Image(systemName: name)
            .font(.body)
            .foregroundStyle(Theme.accent)
            .frame(width: iconColumn)
            .accessibilityHidden(true)
    }
}

extension View {
    /// The spring ReGlass uses for inline changes, or a short fade under Reduce Motion.
    func assistantAnimation<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        animation(Theme.Motion.inline(reduceMotion: reduceMotion), value: value)
    }
}

/// A short task's progress (a lookup, a check), for its status line.
enum LookupState: Equatable {
    case idle
    case waiting(until: Date, text: String)
    case working(String)
    case finished(String, success: Bool)

    var isBusy: Bool {
        switch self {
        case .waiting, .working: return true
        default: return false
        }
    }

    /// A status line for the state, or nothing while idle.
    @ViewBuilder var statusLine: some View {
        switch self {
        case .idle:
            EmptyView()
        case .waiting(let until, let text):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                AssistantStatusLine(tone: .working, text: "\(text) \(left) s")
                    .monospacedDigit()
            }
        case .working(let text):
            AssistantStatusLine(tone: .working, text: text)
        case .finished(let text, let success):
            AssistantStatusLine(tone: success ? .good : .warning, text: text)
        }
    }
}

/// A screen's symbol, name and what it does, at the top of the screen.
struct ScreenHeader: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                RowSymbol(name: symbol)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
