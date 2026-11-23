import SwiftUI

/// The small glass banner just above the home's typing bar: "Note deleted · Undo", "Copied". One at a time; a new one
/// replaces the last.
///
/// Deleting goes through here, the same way on every page (Mail's way): the row goes at once, and the banner offers
/// Undo until something else happens. It never times out (HIG: an undo you can miss isn't one): the next action (a new
/// banner, another delete, opening a screen), a change of page, or ReGlass leaving the screen deletes it for real, and
/// only then. Lists hide the ids in `hidden` meanwhile. Should ReGlass be closed while one waits, the item simply stays.
///
/// Each delete is also registered with the window's `UndoManager`, so shaking the iPhone undoes it too. The two are
/// one undo: whichever is used brings the rows back and takes the other away.
@MainActor
final class LibraryToast: ObservableObject {
    static let shared = LibraryToast()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let symbol: Symbol
        let canUndo: Bool
    }

    /// The banner's symbol: an SF Symbol, or a category's own ("Moved to Work").
    enum Symbol: Equatable {
        case system(String)
        case category(String)

        var image: Image {
            switch self {
            case .system(let name): Image(systemName: name)
            case .category(let name): Image(category: name)
            }
        }
    }

    @Published private(set) var current: Toast?
    /// Rows deleted but still undoable: lists leave them out.
    @Published private(set) var hidden: Set<UUID> = []
    /// The window's undo manager, for shake to undo. The banner hands it over from its environment.
    weak var undoManager: UndoManager?

    private var waiting: (ids: Set<UUID>, commit: () -> Void)?
    /// The undo manager the waiting delete is registered with, so it can be taken off again.
    private weak var registered: UndoManager?
    private var timer: Task<Void, Never>?
    /// How long a plain note ("Copied") stays. An Undo stays until something else happens.
    private static let noteSeconds: Double = 1.8

    private init() {}

    /// A short note that something happened ("Copied"), gone after a moment.
    func show(_ text: String, symbol: String) {
        show(text, symbol: .system(symbol))
    }

    /// The same with a category's symbol ("Moved to Work").
    func show(_ text: String, category: String) {
        show(text, symbol: .category(category))
    }

    private func show(_ text: String, symbol: Symbol) {
        commitWaiting()
        present(Toast(text: text, symbol: symbol, canUndo: false))
    }

    /// Takes `id` off the lists now and deletes it for real (`commit`) once something else happens, unless Undo is
    /// tapped or the iPhone shaken first. `undoName` names it in the shake alert ("Undo Delete").
    func delete(_ id: UUID, text: String, undoName: String = "Delete", commit: @escaping () -> Void) {
        delete([id], text: text, undoName: undoName, commit: commit)
    }

    /// The same for several rows at once ("Got 3 · Clear"): one banner, one Undo brings them all back.
    func delete(_ ids: [UUID], text: String, undoName: String = "Delete", commit: @escaping () -> Void) {
        guard !ids.isEmpty else { return }
        commitWaiting()
        let ids = Set(ids)
        hidden.formUnion(ids)
        waiting = (ids, commit)
        waitingSince = .now
        registerShake(undoName)
        present(Toast(text: text, symbol: .system("trash"), canUndo: true))
    }

    /// When the delete waiting on its banner's Undo was made; nil when none waits.
    var waitingDeleteSince: Date? { waiting == nil ? nil : waitingSince }
    private var waitingSince: Date?

    /// Brings the deleted rows back (the banner's Undo).
    func undo() {
        unregisterShake()
        restore()
    }

    /// Deletes what's waiting now (the next action, another page, or ReGlass leaving the screen).
    func commitWaiting() {
        guard let pending = waiting else { return }
        waiting = nil
        unregisterShake()
        pending.commit()
        hidden.subtract(pending.ids)
        timer?.cancel()
        current = nil
    }

    private func restore() {
        guard let pending = waiting else { return }
        waiting = nil
        hidden.subtract(pending.ids)
        timer?.cancel()
        current = nil
    }

    /// Shake to undo: the undo manager calls back here. Its own action is used up by then, so only the banner goes.
    private func registerShake(_ name: String) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { toast in
            MainActor.assumeIsolated {
                toast.registered = nil
                toast.restore()
            }
        }
        manager.setActionName(name)
        registered = manager
    }

    private func unregisterShake() {
        registered?.removeAllActions(withTarget: self)
        registered = nil
    }

    private func present(_ toast: Toast) {
        timer?.cancel()
        current = toast
        guard !toast.canUndo else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noteSeconds))
            guard !Task.isCancelled, let self, self.current?.id == toast.id else { return }
            self.current = nil
        }
    }
}

/// The banner itself: a glass capsule with the symbol, the words and, for a delete, a copper Undo (which sinks under the
/// finger and taps softly as the rows come back). It rises from the bar and sinks back (a fade under Reduce Motion),
/// and VoiceOver reads it as it appears. A screen that's covered by
/// another one (the home under an open note) passes `shown: false`, so only the one on top shows, buzzes and speaks.
struct LibraryToastView: View {
    var shown = true
    @ObservedObject private var toast = LibraryToast.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Goes up with each Undo, for a soft tap as the rows come back.
    @State private var undos = 0

    var body: some View {
        ZStack {
            if shown, let current = toast.current {
                HStack(spacing: 10) {
                    current.symbol.image
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityHidden(true)
                    Text(current.text)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        // Accessibility sizes: up to three lines rather than cutting a long name off.
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                    if current.canUndo {
                        Button {
                            undos += 1
                            toast.undo()
                        } label: {
                            Text("Undo")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6)
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(SoftPressStyle())
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, current.canUndo ? 10 : 16)
                .padding(.vertical, typeSize.isAccessibilitySize ? 8 : 0)
                .frame(minHeight: 44)
                // A capsule round one line; a rounded rectangle once the words may wrap, so its ends don't clip them.
                .glassSurface(in: typeSize.isAccessibilitySize
                                  ? AnyShape(RoundedRectangle(cornerRadius: 22, style: .continuous)) : AnyShape(Capsule()))
                .id(current.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)).combined(with: .scale(scale: 0.96)))
                .onAppear {
                    AccessibilityNotification.Announcement(current.canUndo ? "\(current.text). Undo available." : current.text).post()
                }
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.82), value: toast.current)
        .sensoryFeedback(trigger: shown ? toast.current?.id : nil) { _, id in
            id == nil ? nil : .impact(weight: .light, intensity: 0.6)
        }
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: undos)
        .onChange(of: scenePhase) { _, phase in if phase != .active { toast.commitWaiting() } }
        // Shake to undo goes to the window's undo manager; the banner's environment has it.
        .onAppear { if let undoManager { toast.undoManager = undoManager } }
        .onChange(of: undoManager) { _, manager in if let manager { toast.undoManager = manager } }
    }
}

extension Notification.Name {
    /// Opens Reminders with the bar started on `object` (a String, e.g. "Remind me about “Bike rack idea” ") and the
    /// keyboard up, for the owner to finish in their own words: "Remind Me" on a note, chat or list item, "Change Time"
    /// or "Remind Me Again" on a reminder. `userInfo[ReminderBar.categoryKey]`, when there, opens that category's chip.
    /// Use `ReminderBar.start(_:category:)`.
    static let reglassReminderDraft = Notification.Name("ReGlassReminderDraft")
}

/// Starting the Reminders bar from anywhere in the app.
enum ReminderBar {
    static let categoryKey = "category"

    /// `category`: the chip to open, so the new reminder goes under it ("Remind Me" on a Shopping item). Nil keeps the
    /// chip that's open when started on the Reminders page, and opens All when started from another page.
    @MainActor
    static func start(_ text: String, category: String? = nil) {
        NotificationCenter.default.post(name: .reglassReminderDraft, object: text,
                                        userInfo: category.map { [categoryKey: $0] })
    }

    /// A title shortened for a draft: one line, at most 80 characters.
    static func short(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).first.map(String.init) ?? title
        let words = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.count > 80 ? String(words.prefix(80)) + "\u{2026}" : words
    }
}
