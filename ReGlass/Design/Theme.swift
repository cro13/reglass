import SwiftUI
import UIKit

/// ReGlass's look: warm paper. A neutral off-white canvas (a warm near-black in Dark Mode), cards a step lighter, ink
/// for the words and copper as the one accent. Every colour here is a dynamic token that follows the system's Light or
/// Dark setting, and the quiet ones (secondary and tertiary text, hairlines, outlines) firm up under Increase Contrast.
/// Views use these tokens, never `.white`, `.black` or `Color(red:…)`. The values and their measured contrast are in
/// docs/DESIGN.md; change both together.
enum Theme {
    // MARK: Surfaces

    /// The screen: warm off-white (#F4F2EC; dark #1F1E1C). Flat screens, the sign-in privacy cover, the launch screen
    /// and the fade under the typing bars.
    static let canvas = dynamic(0xF4F2EC, 0x1F1E1C)
    /// The backdrop runs from a touch lighter at the top, through `canvas`, to a touch deeper at the bottom.
    static let backdropTop = dynamic(0xF8F7F3, 0x252421)
    static let backdropBottom = dynamic(0xEFECE5, 0x1B1A18)
    /// Cards and list rows, the content layer (#FBFAF7; dark #2A2926).
    static let card = dynamic(0xFBFAF7, 0x2A2926)
    /// A step above a card: text fields, and cards under Increase Contrast (#FFFFFF; dark #34322F).
    static let raised = dynamic(0xFFFFFF, 0x34322F)

    // MARK: Words

    /// Primary text and glyphs: titles, names, what was said (#1F1E1C; dark #EDEBE4). 14.9:1 on the canvas.
    static let ink = dynamic(0x1F1E1C, 0xEDEBE4)
    /// Supporting text: subtitles, values, snippets (#5E5B54; dark #B8B4AA). 6.0:1 on the canvas, 6.2:1 on a card.
    static let textSecondary = dynamic(0x5E5B54, 0xB8B4AA, contrast: (0x46443F, 0xD3CFC6))
    /// Captions, times, chevrons (#6F6B63; dark #A29E94). Still 4.7:1 on the canvas, so small captions stay readable.
    static let textTertiary = dynamic(0x6F6B63, 0xA29E94, contrast: (0x56534D, 0xC0BCB2))

    // MARK: Lines

    /// Card edges, dividers, rails (#E3E0D6; dark #3A3834). Decoration only: never the one thing that shows a control.
    static let hairline = dynamic(0xE3E0D6, 0x3A3834, contrast: (0xA9A59B, 0x65625B))
    /// Outlines that are the control itself (an empty checkbox circle, a pending step): 3:1 or more on every surface
    /// (#8E8A80; dark #85817A).
    static let control = dynamic(0x8E8A80, 0x85817A, contrast: (0x6F6B63, 0xA29E94))
    /// The faint track under a ring or arc, and the quiet fill of a disabled round button: ink at 10 % (dark 14 %).
    static let track = dynamic(0x1F1E1C, 0xEDEBE4, alpha: (0.10, 0.14))
    /// A text field's resting edge, a little firmer than a hairline (#D2CEC3; dark #4A4743). Focused, it turns `accentFill`.
    static let fieldEdge = dynamic(0xD2CEC3, 0x4A4743, contrast: (0x8E8A80, 0x85817A))
    /// A text field's fill.
    static let field = raised

    // MARK: Accent

    /// The one accent (copper), in its two tones. `accent` is for text and glyphs: tinted text buttons and links, SF
    /// Symbols, small dots, status words, selected labels (#9A582D; dark #D08C5E). 4.9:1 on the canvas, 5.3:1 on a card.
    static let accent = dynamic(0x9A582D, 0xD08C5E)
    /// The same copper for areas and strokes: toggles, rings, progress, filled pills and badges, selection washes, active
    /// outlines (#AC6232; dark #CB7F4D). 4.1:1 on the canvas (non-text needs 3:1). Labels on it are `onAccent`.
    static let accentFill = dynamic(0xAC6232, 0xCB7F4D)
    /// Labels and glyphs on `accentFill`: white in light (4.6:1), warm black in dark (5.3:1).
    static let onAccent = dynamic(0xFFFFFF, 0x1F1E1C)

    /// The fills of swipe buttons: iOS's own colours (they follow Light and Dark by themselves), each with one meaning
    /// on every page, as Mail and Notes use them. Every swipe button sets its own: the app-wide copper tint wins over a
    /// button's role in swipe actions, which once made Delete the accent colour.
    enum Swipe {
        /// Copy.
        static let copy = Color(uiColor: .systemBlue)
        /// Remind Me, Remind Me Again.
        static let remind = Color(uiColor: .systemOrange)
        /// Done.
        static let done = Color(uiColor: .systemGreen)
        /// Snooze.
        static let snooze = Color(uiColor: .systemIndigo)
        /// Not Done: back on the list.
        static let undo = Color(uiColor: .systemGray)
        /// Delete.
        static let delete = Color(uiColor: .systemRed)
    }

    // MARK: Status

    /// Connected, charged, done (#2E7A47; dark #6FCB8D). 4.7:1 on the canvas.
    static let good = dynamic(0x2E7A47, 0x6FCB8D)
    /// Needs a look: Bluetooth off, low battery, a lookup that failed (#8F5A00; dark #EBB55B). 5.2:1 on the canvas.
    static let warning = dynamic(0x8F5A00, 0xEBB55B)
    /// Something is wrong: battery at 10 %, glasses that refuse ReGlass (#B8322A; dark #FF8A7A). 5.3:1 on the canvas.
    static let critical = dynamic(0xB8322A, 0xFF8A7A)
    /// A glyph on a filled status colour (the check in a green circle): white in light, warm black in dark.
    static let onStatus = onAccent
    /// Destructive actions: Delete, Forget, Sign Out, Delete All. iOS's own red, in its accessible tone so small words
    /// keep 4.8:1 on the canvas (#D70015; dark #FF6961). Swipe buttons keep `Swipe.delete`.
    static let actionRed = dynamic(0xD70015, 0xFF6961)

    // MARK: Light and shade

    /// Warm light: the soft glow behind the glasses and the emblems, and the daylight at the top of the backdrop.
    /// Translucent by itself (35 % in light, 30 % in dark), so it warms what's under it without tinting it.
    static let glow = dynamic(0xE3A176, 0xCB7F4D, alpha: (0.35, 0.30))
    /// The paler end of the glow.
    static let glowSoft = dynamic(0xF0C5A8, 0xD08C5E, alpha: (0.35, 0.30))
    /// The glow as a gradient, for blurred halos.
    static let halo = LinearGradient(colors: [glowSoft, glow], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Dims the page under a dialog: warm ink at 32 % in light, black at 55 % in dark.
    static let scrim = dynamic(0x1F1E1C, 0x000000, alpha: (0.32, 0.55))

    /// `accent` to `accentFill`: only where depth is the point, the ReGlass Emblem's symbol and the live countdown ring.
    /// (The setup ring and the arc spinner run the same two tones as angular gradients.) Everything else is flat:
    /// `accent` for text and glyphs, `accentFill` for areas and strokes.
    static let accentGradient = LinearGradient(colors: [accent, accentFill], startPoint: .topLeading, endPoint: .bottomTrailing)

    // MARK: Old names

    @available(*, deprecated, renamed: "canvas", message: "The navy is gone: use Theme.canvas.")
    static var background: Color { canvas }
    @available(*, deprecated, renamed: "backdropTop", message: "The navy is gone: use Theme.backdropTop.")
    static var navyTop: Color { backdropTop }
    @available(*, deprecated, renamed: "backdropBottom", message: "The navy is gone: use Theme.backdropBottom.")
    static var navyBottom: Color { backdropBottom }
    @available(*, deprecated, renamed: "glow", message: "The blue studio light is gone: use Theme.glow.")
    static var studioLight: Color { glow }
    @available(*, deprecated, renamed: "halo", message: "The blue studio light is gone: use Theme.halo.")
    static var studioGlow: LinearGradient { halo }

    /// ReGlass's springs, in one place so every screen moves alike. Each has a Reduce Motion partner: a short fade,
    /// or no animation at all where the change is only movement.
    enum Motion {
        /// A finger going down on something: fast, no bounce.
        static let press = Animation.spring(response: 0.18, dampingFraction: 0.8)
        /// The finger lifting: back with a little bounce, so the press feels answered.
        static let release = Animation.spring(response: 0.4, dampingFraction: 0.52)
        /// Something changing in place (a row opening, a status line swapping, a button changing its job).
        static let inline = Animation.spring(response: 0.42, dampingFraction: 0.86)
        /// Something new arriving in a list or a conversation.
        static let arrive = Animation.spring(response: 0.45, dampingFraction: 0.85)
        /// A number or gauge moving to a new reading: the digits and the ring share it, so they move as one.
        static let reading = Animation.spring(response: 0.6, dampingFraction: 0.85)
        /// The Reduce Motion stand-in for all of the above.
        static let fade = Animation.easeOut(duration: 0.2)

        /// `inline`, or a short fade under Reduce Motion.
        static func inline(reduceMotion: Bool) -> Animation { reduceMotion ? fade : inline }
        /// `arrive`, or a short fade under Reduce Motion.
        static func arrive(reduceMotion: Bool) -> Animation { reduceMotion ? fade : arrive }
        /// `press` going down, `release` coming back up.
        static func press(_ pressed: Bool) -> Animation { pressed ? press : release }
    }

    static func batteryColor(_ percent: Int?, charging: Bool) -> Color {
        guard let percent else { return textTertiary }
        if charging { return good }
        if percent <= 10 { return critical }
        if percent <= 20 { return warning }
        return good
    }

    /// A colour that follows Light and Dark: `light` and `dark` as 0xRRGGBB, with firmer values under Increase Contrast
    /// (`contrast`, light then dark) and an optional alpha for each appearance.
    static func dynamic(_ light: UInt32, _ dark: UInt32, contrast: (UInt32, UInt32)? = nil,
                        alpha: (CGFloat, CGFloat) = (1, 1)) -> Color {
        Color(uiColor: UIColor { traits in
            let high = traits.accessibilityContrast == .high
            if traits.userInterfaceStyle == .dark {
                return UIColor(rgb: high ? (contrast?.1 ?? dark) : dark, alpha: alpha.1)
            }
            return UIColor(rgb: high ? (contrast?.0 ?? light) : light, alpha: alpha.0)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32, alpha: CGFloat) {
        self.init(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }
}

extension Font {
    /// ReGlass's display voice: Inter Display SemiBold (bundled in ReGlass/Fonts, SIL Open Font License). Only the
    /// wordmark, screen titles and the glasses' name; everything else stays San Francisco. Sized from the text
    /// style it stands in for, so Dynamic Type scales it like the system font.
    ///
    /// SemiBold is the only Inter weight shipped, so with Bold Text on the title falls back to San Francisco Bold,
    /// which is bolder than the SemiBold around it, as Bold Text asks. This reads the setting when it's called; prefer
    /// `displayFont(_:)`, which follows the environment and redraws the moment Bold Text is switched.
    static func display(_ style: Font.TextStyle) -> Font {
        display(style, bold: UIAccessibility.isBoldTextEnabled)
    }

    /// The display font for `style`, bolder when `bold` (Bold Text is on).
    static func display(_ style: Font.TextStyle, bold: Bool) -> Font {
        bold ? .system(style, weight: .bold)
             : .custom("InterDisplay-SemiBold", size: displaySize(style), relativeTo: style)
    }

    /// The default (Large) point size of each text style.
    private static func displaySize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        default: return 17
        }
    }
}

/// `Font.display(style)` that follows Bold Text: it reads the environment's legibility weight, so the title changes
/// face as soon as the setting does, without waiting for its view to redraw for some other reason.
private struct DisplayFont: ViewModifier {
    let style: Font.TextStyle
    @Environment(\.legibilityWeight) private var legibilityWeight

    func body(content: Content) -> some View {
        content.font(.display(style, bold: legibilityWeight == .bold))
    }
}

extension View {
    /// Inter Display SemiBold in `style`, or San Francisco Bold under Bold Text. See `Font.display(_:)`.
    func displayFont(_ style: Font.TextStyle) -> some View {
        modifier(DisplayFont(style: style))
    }
}

/// The app's background: warm paper, a touch lighter at the top, with one soft patch of warm daylight in the top
/// corner. Flat enough that cards and words carry the page.
struct ReGlassBackdrop: View {
    var intensity: Double = 1

    var body: some View {
        // The light sits in an overlay so its fixed size never widens the screen's layout.
        LinearGradient(colors: [Theme.backdropTop, Theme.canvas, Theme.backdropBottom], startPoint: .top, endPoint: .bottom)
            .overlay {
                Circle().fill(Theme.glow)
                    .frame(width: 460, height: 460).blur(radius: 170)
                    .opacity(0.3 * intensity).offset(x: -150, y: -360)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

// MARK: Surfaces

/// A content card: the card fill with a hairline, in the content layer. Liquid Glass is for the controls that
/// float over content (bars, composers, pills, round buttons, chips, the toast), never for cards and rows
/// (HIG › Materials: "Don't use Liquid Glass in the content layer").
struct ContentCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 24
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .contentSurface(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The content layer's surface: `card` with a hairline edge; under Increase Contrast, `raised` with a firmer edge (the
/// hairline token firms up by itself).
private struct ContentSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        content
            .background(increased ? Theme.raised : Theme.card, in: shape)
            .overlay(shape.strokeBorder(Theme.hairline, lineWidth: increased ? 1 : 0.75))
    }
}

extension View {
    /// Apple's Liquid Glass in `shape`, for the functional layer only: controls that float over content (bars,
    /// composers, pills, round buttons, chips, banners). `interactive` is for things you press. Untinted: the glass
    /// takes its warmth from the paper under it in both appearances. Cards and rows use `contentSurface(in:)`.
    func glassSurface<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    }

    /// A card or row in the content layer: a quiet fill and hairline in `shape`, never Liquid Glass.
    func contentSurface<S: InsettableShape>(in shape: S) -> some View {
        modifier(ContentSurface(shape: shape))
    }

    /// A text field's surface: `field` with a `fieldEdge` that turns copper while `focused`.
    func fieldSurface(focused: Bool, cornerRadius: CGFloat = 16) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(focused ? Theme.accentFill : Theme.fieldEdge, lineWidth: 1))
    }
}

extension View {
    func contentCard(cornerRadius: CGFloat = 24, padding: CGFloat = 18) -> some View {
        modifier(ContentCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: Buttons

/// Pills hug their label: generous side padding, never narrower than 190pt or wider than 300pt (long labels wrap),
/// at least 50pt tall, centred in whatever holds them. A press springs the pill down and lets it bounce back; under
/// Reduce Motion it dims instead.
private enum Pill {
    static let minWidth: CGFloat = 190
    static let maxWidth: CGFloat = 300
    static let minHeight: CGFloat = 50
}

/// Offers its content at most `maxWidth` and takes the content's own size. `frame(maxWidth:)` would stretch every
/// pill to the cap; this lets a short label stay short and a long one wrap.
struct WidthCap: Layout {
    var maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.first?.sizeThatFits(capped(proposal)) ?? .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(bounds.size))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
    }
}

private extension View {
    /// The label's type, padding and minimum size inside a pill.
    func pillLabel() -> some View {
        font(.headline)
            .multilineTextAlignment(.center)
            .padding(.vertical, 13)
            .padding(.horizontal, 30)
            .frame(minWidth: Pill.minWidth, minHeight: Pill.minHeight)
    }

    /// Caps and centres a finished pill. Only the pill itself takes taps, not the space beside it.
    func pillPlacement(pressed: Bool) -> some View {
        contentShape(Capsule())
            .pressFeedback(pressed)
            .modifier(CapWidth(maxWidth: Pill.maxWidth))
            .frame(maxWidth: .infinity)
    }
}

private struct CapWidth: ViewModifier {
    let maxWidth: CGFloat
    func body(content: Content) -> some View { WidthCap(maxWidth: maxWidth) { content } }
}

/// Down quickly to `scale`, back with a little bounce. A dim instead under Reduce Motion. See `pressFeedback(_:scale:)`.
private struct PressFeedback: ViewModifier {
    let pressed: Bool
    var scale: CGFloat = 0.95
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .opacity(pressed && reduceMotion ? 0.75 : 1)
            .animation(Theme.Motion.press(pressed), value: pressed)
    }
}

extension View {
    /// ReGlass's press: sinks to `scale` as the finger goes down and springs back as it lifts; under Reduce Motion it
    /// dims instead of moving. For controls that track their own press (a custom gesture); buttons use `PressableStyle`.
    func pressFeedback(_ pressed: Bool, scale: CGFloat = 0.95) -> some View {
        modifier(PressFeedback(pressed: pressed, scale: scale))
    }
}

/// Any button that isn't a pill: an icon, a round button, a card or a row. It sinks to `scale` on touch-down and
/// springs back on release (a dim under Reduce Motion). `haptic` adds a light tap the moment the finger lands, for
/// the few presses that start something (Send, Start); leave it off for navigation and frequent taps.
///
///     Button(action: send) { Image(systemName: "arrow.up") }
///         .buttonStyle(PressableStyle(scale: 0.88, haptic: true))
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.96
    var haptic = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pressFeedback(configuration.isPressed, scale: scale)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: configuration.isPressed) { _, pressed in
                pressed && haptic
            }
    }
}

/// A copper capsule with a white label (warm black in Dark Mode): the one obvious next step on a screen. Disabled, it
/// goes quiet: a faint fill and a tertiary label. A light tap of haptics on press.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pillLabel()
            .foregroundStyle(isEnabled ? Theme.onAccent : Theme.textTertiary)
            .background(Capsule().fill(isEnabled ? Theme.accentFill : Theme.track))
            .pillPlacement(pressed: configuration.isPressed)
            .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: configuration.isPressed) { _, pressed in pressed }
    }
}

/// A Liquid Glass capsule with an ink label, for the alternative action.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pillLabel()
            .foregroundStyle(Theme.ink.opacity(isEnabled ? 1 : 0.4))
            .glassSurface(in: Capsule(), interactive: true)
            .pillPlacement(pressed: configuration.isPressed)
    }
}

/// Quiet text action under the main buttons. Still a 44pt target.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.textSecondary.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Theme.Motion.press(configuration.isPressed), value: configuration.isPressed)
    }
}

// MARK: Artwork

/// Where each picture of the glasses appears. All use the `Glasses` picture; only the margin differs.
enum GlassesArt {
    case hero, front, inCase, brand
}

/// The glasses, as a picture that floats on the page with no background square or disc.
struct ArtImage: View {
    let art: GlassesArt

    var body: some View {
        Image("Glasses")
            .resizable()
            .scaledToFit()
            .padding(padding)
            .accessibilityHidden(true)
    }

    private var padding: CGFloat {
        switch art {
        case .hero: return 20
        case .brand: return 16
        case .inCase: return 8
        case .front: return 4
        }
    }
}
