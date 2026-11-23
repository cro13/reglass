import SwiftUI

// Categories on the Notes and Reminders pages: the chip row at the top (All · Shopping 4 · To-do 2 · …) and the
// Move To ▸ menu on rows and the note screen. A category is only a name (`LibraryCategory`); the chips show the ones
// with something in them on that page, in `LibraryStore.categoryNames()` order. Each category has its own colour, as
// iOS gives each list one (`LibraryCategory.color`): its symbol and name wear it, never a fill. The symbols are ReGlass's
// own (`Image(category:)`), not SF Symbols.

// MARK: Colour

extension LibraryCategory {
    /// A category's colour: Shopping green, To-do blue, Appointments orange, Ideas yellow, Work purple, iOS's list
    /// colours in two tones. In light, deep enough that a name in caption type reads on the paper (4.5:1 or more on the
    /// canvas, more on a card); in dark, softened (about 30% less chroma in OKLCH, same hue) so they sit calmly on the
    /// warm black (4.8:1 or more on a card). One the owner made takes one of the rest by its name, so it keeps its colour
    /// whatever else comes and goes. Never copper (the accent) or red (deleting); orange leans amber to stay clear of copper.
    static func color(_ name: String) -> Color {
        if same(name, shopping) { return Self.green }
        if same(name, toDo) { return Self.blue }
        if same(name, appointments) { return Self.orange }
        if same(name, ideas) { return Self.yellow }
        if same(name, work) { return Self.purple }
        let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return Self.others[Int(hash % UInt64(Self.others.count))]
    }

    // Light, then dark. Measured in docs/DESIGN.md.
    private static let green = Theme.dynamic(0x2F7A3C, 0x66C173)
    private static let blue = Theme.dynamic(0x2F68B0, 0x5E97D9)
    private static let orange = Theme.dynamic(0x9E5C00, 0xE3A35C)
    private static let yellow = Theme.dynamic(0x806400, 0xECD26F)
    private static let purple = Theme.dynamic(0x8448A8, 0xC896E1)
    /// Pink, indigo, brown and grey, for the owner's own (the grey has no chroma to soften). Keep the order: a name's
    /// hash picks its place.
    private static let others = [Theme.dynamic(0xB03C55, 0xE67B8B), Theme.dynamic(0x4F52B5, 0xA7A8E8),
                                 Theme.dynamic(0x7A5E40, 0xAD9679), Theme.dynamic(0x69686D, 0xAEAEB2)]
}

// MARK: Symbol

extension Image {
    /// A category's symbol (`LibraryCategory.symbol`): ReGlass's own, Phosphor Regular as custom symbols in the asset
    /// catalog (calmer than SF's checklist and lightbulb). Like an SF Symbol it sizes with the
    /// font, sits on the text's baseline and takes a foreground style; unlike one it keeps its light regular stroke
    /// whatever the font's weight, so don't give it a weight. Decorative: VoiceOver reads the name beside it, never the
    /// asset's name; an icon on its own needs its own label.
    init(category name: String) {
        self.init(decorative: LibraryCategory.symbol(name))
    }
}

// MARK: Order

/// `LibraryStore.categoryNames()`, kept current: the defaults in their order, then the owner's own in the order first
/// used. The chips and the Move To ▸ menus follow it.
@MainActor
final class CategoryOrder: ObservableObject {
    static let shared = CategoryOrder()

    @Published private(set) var names: [String]
    private var observer: NSObjectProtocol?

    private init() {
        names = LibraryStore.shared.categoryNames()
        observer = NotificationCenter.default.addObserver(forName: LibraryStore.didChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let fresh = LibraryStore.shared.categoryNames()
        if fresh != names { names = fresh }
    }

    /// The shown name `stored` belongs to ("shopping" → "Shopping"), or `stored` itself.
    func name(for stored: String) -> String {
        names.first { LibraryCategory.same($0, stored) } ?? stored
    }
}

// MARK: Chips

/// One chip: a category with something in it on the page, and how many of them count (nil: show no number).
struct CategoryChip: Identifiable, Equatable {
    let name: String
    let count: Int?

    var id: String { name }

    /// The chips for a page, in `order`: one for each category some thing on the page carries (`present`), counting
    /// the ones in `counted` (Reminders: open items and reminders to come; Notes: every note). Names the order doesn't
    /// know yet come last, as first met.
    static func make(order: [String], present: [String?], counted: [String?]) -> [CategoryChip] {
        var names: [String] = []
        for stored in present.compactMap({ $0 }) where !stored.isEmpty {
            let name = order.first { LibraryCategory.same($0, stored) } ?? stored
            if !names.contains(where: { LibraryCategory.same($0, name) }) { names.append(name) }
        }
        let rank = { (name: String) in order.firstIndex { LibraryCategory.same($0, name) } ?? Int.max }
        let sorted = names.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        return sorted.map { name in
            let count = counted.compactMap { $0 }.filter { LibraryCategory.same($0, name) }.count
            return CategoryChip(name: name, count: count > 0 ? count : nil)
        }
    }

    /// The row shows once a chip would narrow the page: two categories have something in them, or one does and
    /// something else on the page has none (`unfiled`: three Ideas notes among six). It stays while
    /// one is selected so All is always one tap away.
    static func showsRow(_ chips: [CategoryChip], selection: String?, unfiled: Bool) -> Bool {
        chips.count >= 2 || (chips.count == 1 && unfiled) || (selection != nil && !chips.isEmpty)
    }

    /// True when a thing carries no category (no chip but All shows it).
    static func unfiled(_ stored: String?) -> Bool {
        stored?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    /// True when a thing filed under `stored` shows under `chip`; everything shows under All (nil).
    static func files(_ stored: String?, under chip: String?) -> Bool {
        guard let chip else { return true }
        guard let stored else { return false }
        return LibraryCategory.same(stored, chip)
    }

    /// `selection` while it still has a chip; nil (All) once its category has nothing left on the page.
    static func valid(_ selection: String?, in chips: [CategoryChip]) -> String? {
        guard let selection else { return nil }
        return chips.first { LibraryCategory.same($0.name, selection) }?.name
    }
}


/// The row of chips: All, then a compact glass capsule per category with its symbol (in the category's colour), its
/// name and a count. The selected one wears a thin ring in its colour (copper for All) that slides across to the next one
/// chosen (a cross-fade under Reduce Motion), and the row scrolls sideways when the chips outgrow the screen
/// (`ChipScroller`).
struct CategoryChips: View {
    let chips: [CategoryChip]
    @Binding var selection: String?
    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ChipScroller(selected: selection ?? ChipID.all, label: "Categories") {
            chip(nil, count: nil)
            ForEach(chips) { chip in
                self.chip(chip.name, count: chip.count)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func chip(_ name: String?, count: Int?) -> some View {
        let isSelected: Bool
        if let name {
            isSelected = selection.map { LibraryCategory.same($0, name) } ?? false
        } else {
            isSelected = selection == nil
        }
        return ChipButton(title: name ?? "All", image: name.map { Image(category: $0) },
                          tint: name.map(LibraryCategory.color) ?? Theme.accent,
                          fill: name.map(LibraryCategory.color) ?? Theme.accentFill,
                          count: count, selected: isSelected, namespace: ring) {
            guard !isSelected else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.38)) { selection = name }
        }
        .id(name ?? ChipID.all)
    }
}

/// A row of chips that scrolls sideways when they outgrow the screen, its last 28pt fading out so a chip cut by the
/// edge reads as more to come (and its first 28pt once scrolled away from the start). Nothing fades while every chip
/// fits. The chosen chip (each chip's `.id`, `ChipID.all` for All) is scrolled to the middle as it changes. Shared by the
/// category chips and Search's All · Chats · Notes · Reminders.
struct ChipScroller<Content: View>: View {
    /// The id of the chip that's chosen.
    let selected: String
    /// What VoiceOver calls the row.
    let label: String
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var edges = ChipEdges()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    content
                }
                .padding(.horizontal, 20)
            }
            .scrollClipDisabled()
            .onScrollGeometryChange(for: ChipEdges.self) { geometry in
                ChipEdges(overflows: geometry.contentSize.width > geometry.containerSize.width + 1,
                          atStart: geometry.visibleRect.minX <= 1,
                          atEnd: geometry.visibleRect.maxX >= geometry.contentSize.width - 1)
            } action: { _, now in
                edges = now
            }
            // Taller than the row, so the glass edges the scroll view lets through aren't cut by the mask.
            .mask { edgeFade.padding(.vertical, -24) }
            .onChange(of: selected) { _, now in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                    proxy.scrollTo(now, anchor: .center)
                }
            }
            .onAppear {
                if selected != ChipID.all { proxy.scrollTo(selected, anchor: .center) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    /// Opaque, with the end(s) the chips run past going transparent over 28pt. Transparent in a mask means hidden,
    /// so an end that doesn't fade is plain black.
    private var edgeFade: some View {
        let start = edges.overflows && !edges.atStart
        let end = edges.overflows && !edges.atEnd
        return HStack(spacing: 0) {
            LinearGradient(colors: [start ? .clear : .black, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 28)
            Color.black
            LinearGradient(colors: [.black, end ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: 28)
        }
        .animation(.easeOut(duration: 0.2), value: start)
        .animation(.easeOut(duration: 0.2), value: end)
    }
}

/// The id of the All chip, which every chip row starts with.
enum ChipID {
    static let all = "chip-all"
}

/// Where the chip row stands: whether it outgrows the screen, and whether it's scrolled to its start or its end.
private struct ChipEdges: Equatable {
    var overflows = false
    var atStart = true
    var atEnd = true
}

/// One chip: a compact Liquid Glass capsule with an optional symbol, the name and a count. Chosen, it takes a wash of
/// `fill` and a thin ring of `tint` (the only thing that moves between chips; the glass stays where it is), and its
/// symbol turns `tint` and its count ink (a count in `tint` fell under 4.5:1 on the wash). A category's chip is in its
/// colour, every other in copper.
struct ChipButton: View {
    let title: String
    /// A category's symbol (`Image(category:)`) or a page's SF Symbol; none for All.
    let image: Image?
    /// For the symbol and the ring: `Theme.accent`, or a category's colour.
    let tint: Color
    /// For the wash behind a chosen chip: `Theme.accentFill`, or a category's colour.
    let fill: Color
    let count: Int?
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let image {
                    image
                        .font(.footnote)
                        .foregroundStyle(tint)
                        .opacity(selected ? 1 : 0.85)
                }
                // Always as wide as its semibold self, so choosing a chip never nudges the ones beside it.
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .hidden()
                    .overlay {
                        Text(title)
                            .font(.subheadline.weight(selected ? .semibold : .medium))
                            .foregroundStyle(Theme.ink.opacity(selected ? 1 : 0.78))
                    }
                if let count {
                    Text("\(count)")
                        .font(.footnote.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Theme.ink : Theme.textSecondary)
                        .contentTransition(.numericText())
                }
            }
            .lineLimit(1)
            .padding(.horizontal, image == nil ? 16 : 13)
            .frame(minHeight: 36)
            .background {
                if selected {
                    Capsule()
                        .fill(fill.opacity(colorScheme == .dark ? 0.22 : 0.12))
                        .transition(.opacity)
                }
            }
            .glassSurface(in: Capsule(), interactive: true)
            .overlay {
                if selected {
                    Capsule()
                        .strokeBorder(tint, lineWidth: 1.2)
                        .opacity(0.95)
                        .modifier(SlidingRing(namespace: namespace, enabled: !reduceMotion))
                        .transition(.opacity)
                }
            }
            // A 44pt target around the 36pt capsule.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.3), value: count)
        .accessibilityLabel(count.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The ring moves from one chip to the next; under Reduce Motion it fades in place.
private struct SlidingRing: ViewModifier {
    let namespace: Namespace.ID
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.matchedGeometryEffect(id: "category-ring", in: namespace)
        } else {
            content
        }
    }
}

extension View {
    /// The chip row as a list row: edge to edge, so the chips scroll in from the screen's edge.
    func chipRow(top: CGFloat, bottom: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 0, bottom: bottom, trailing: 0))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

// MARK: Move To

/// "Move To ▸" in a press-and-hold or ••• menu: every category with its symbol, a check on the current one, and
/// "None" for notes and reminders (a list item always has a category). Picking one calls `move` with its name (nil:
/// none); picking the current one changes nothing.
struct MoveToMenu: View {
    let current: String?
    var allowsNone = false
    let move: (String?) -> Void
    @ObservedObject private var order = CategoryOrder.shared

    var body: some View {
        let current = self.current.map(order.name(for:))
        Menu {
            Picker(selection: Binding(get: { current }, set: { picked in
                switch (picked, current) {
                case (nil, nil): return
                case let (picked?, current?) where LibraryCategory.same(picked, current): return
                default: move(picked)
                }
            })) {
                ForEach(order.names, id: \.self) { name in
                    Label(name, image: LibraryCategory.symbol(name))
                        .tag(Optional(name))
                }
                if allowsNone {
                    Label("None", systemImage: "circle.dashed")
                        .tag(String?.none)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            Label("Move To", systemImage: "folder")
        }
    }
}

extension LibraryToast {
    /// "Moved to Work", with the category's symbol; "Out of Ideas" when a note or reminder goes back to none.
    func moved(to category: String?, from old: String?) {
        if let category {
            show("Moved to \(category)", category: category)
        } else {
            show(old.map { "Out of \($0)" } ?? "No category", symbol: "circle.dashed")
        }
    }
}
