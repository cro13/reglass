import SwiftData
import SwiftUI
import UIKit

/// One note, open to read and edit in place: the title and the words are fields, saved a moment after you stop
/// typing, when you're done, and when you leave. A typed note without a title gets one from ReGlass (`NoteTitler`):
/// meanwhile the empty title says so with a soft shimmer, and the title fades in when it comes; a tap edits it like
/// any other. Copy, Remind Me, Move To ▸ and Delete sit in the round ••• button at the top; the note's category shows
/// under where it came from. Delete closes the note at once and the home's banner offers Undo.
struct NoteScreen: View {
    let id: UUID

    var body: some View {
        // The app's root environment holds Chats' container; the note lives in the library's.
        NoteEditor(id: id)
            .modelContainer(LibraryStore.shared.container)
            .modifier(NoteZoomDestination(id: id))
    }
}

/// Grows out of the note's card on Notes and shrinks back into it on the way out (a swipe down closes it too); the
/// usual push where there's no card to come from, and under Reduce Motion (where iOS cross-fades it).
private struct NoteZoomDestination: ViewModifier {
    let id: UUID
    @Environment(\.noteZoom) private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let zoom, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: id, in: zoom))
        } else {
            content
        }
    }
}

private struct NoteEditor: View {
    let id: UUID
    @Query private var matches: [ReGlassNote]
    @ObservedObject private var titler = NoteTitler.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var title = ""
    @State private var text = ""
    @State private var loaded = false
    /// Deleted: nothing loads or saves any more while the screen closes.
    @State private var leaving = false
    /// The note's title in the store as this screen last saw it, to tell when one has just arrived.
    @State private var storedTitle = ""
    @State private var pendingSave: Task<Void, Never>?
    @State private var saves = 0
    /// Goes up each time a title arrives from ReGlass, which fades it in.
    @State private var titleArrivals = 0
    /// The check beside "Saved", shown for a moment after each save.
    @State private var savedCheck = false
    @State private var savedCheckTimer: Task<Void, Never>?
    @FocusState private var field: Field?

    private enum Field: Hashable {
        case title, text
    }

    init(id: UUID) {
        self.id = id
        _matches = Query(filter: #Predicate<ReGlassNote> { $0.id == id && $0.deletedAt == nil })
    }

    private var titling: Bool { titler.titling.contains(id) }

    var body: some View {
        ZStack {
            ReGlassBackdrop()
            // Empty only if the note is deleted elsewhere while it's open.
            if let note = matches.first {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        origin(note)
                            .entrance(0)
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 1)
                            .padding(.top, 12)
                        titleField
                            .entrance(1)
                            .padding(.top, 14)
                        textField
                            .entrance(2)
                            .padding(.top, 12)
                        if savedCheck {
                            edited(note)
                                .padding(.top, 18)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .overlay(alignment: .bottom) {
            // "Copied" shows here; after Delete, the home's own banner carries the Undo.
            if !leaving {
                LibraryToastView()
                    .padding(.bottom, 6)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { toolbar }
        .onAppear { load(force: false) }
        .onChange(of: title) { _, _ in saveSoon() }
        .onChange(of: text) { _, _ in saveSoon() }
        .onChange(of: field) { _, now in if now == nil { saveNow() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveNow() } }
        .onChange(of: matches.first?.updated) { _, _ in storeChanged() }
        // ReGlass's title leaves the note's last change as it was, so it's followed on its own.
        .onChange(of: matches.first?.title) { _, _ in storeChanged() }
        .onDisappear { saveNow() }
    }

    // MARK: Pieces

    /// "Done" while a field is being edited, and the round ••• button with the note's actions. Done is the system's
    /// prominent glass button in the accent fill with an `onAccent` label (as the bars' send button), a separate piece of
    /// glass beside the ••• button, so that one never moves.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if field != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Button { field = nil } label: {
                    Text("Done")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.onAccent)
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accentFill)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
        }
        if matches.first != nil {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(action: copy) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button(action: remind) {
                        Label("Remind Me", systemImage: "bell")
                    }
                    MoveToMenu(current: matches.first?.category, allowsNone: true, move: move)
                    Divider()
                    Button(role: .destructive, action: delete) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .tint(Theme.ink)   // ink like the system back button
                .accessibilityLabel("More")
            }
        }
    }

    /// How the note was made and when: "Said to your glasses · Today 14:32", and under it its category ("Ideas ·
    /// ReGlass") once it has one.
    private func origin(_ note: ReGlassNote) -> some View {
        TimelineView(.everyMinute) { _ in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: note.source.markSymbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(minWidth: 18)
                        .accessibilityHidden(true)
                    let mod = note.category == nil ? (note.modified.map { " · Modified \($0.modifiedPhrase)" } ?? "") : ""
                    Text("\(note.source.madeHow) · \(note.created.libraryDayTime)\(mod)")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                if let category = LibraryStore.clean(note.category) {
                    let name = CategoryOrder.shared.name(for: category)
                    let color = LibraryCategory.color(name)
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(category: name)
                            .font(.subheadline)
                            .foregroundStyle(color)
                            .frame(minWidth: 18)
                            .accessibilityHidden(true)
                        let topic = LibraryStore.clean(note.topic).map { " · \($0)" } ?? ""
                        let mod = note.modified.map { " · Modified \($0.modifiedPhrase)" } ?? ""
                        Text("\(Text(name).foregroundStyle(color))\(Text(topic).foregroundStyle(Theme.textSecondary))\(Text(mod).foregroundStyle(Theme.textTertiary))")
                            .font(.subheadline.weight(.medium))
                            .contentTransition(.opacity)
                    }
                    .accessibilityElement(children: .combine)
                    .transition(.libraryDissolve(reduceMotion: reduceMotion))
                }
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.35), value: note.category)
    }

    /// The title, never required. Empty, it says "Title" quietly, or "ReGlass is adding a title…" while ReGlass writes
    /// one. ReGlass's title fades in when it comes (out of a soft blur; a plain fade under Reduce Motion).
    ///
    /// An empty field with no prompt measures almost nothing tall, so a hidden line of title type keeps one line of
    /// room under it: the placeholder sits on that line's baseline, and a tap anywhere on the line starts the title.
    private var titleField: some View {
        ZStack(alignment: .topLeading) {
            Text("Title")
                .displayFont(.title)
                .hidden()
                .overlay(alignment: Alignment(horizontal: .leading, vertical: .firstTextBaseline)) {
                    titlePlaceholder
                }
            TextField("", text: $title, axis: .vertical)
                .displayFont(.title)
                .foregroundStyle(Theme.ink)
                .focused($field, equals: .title)
                .submitLabel(.next)
                .onSubmit { field = .text }
                .keyframeAnimator(initialValue: TitleArrival(), trigger: titleArrivals) { content, arrival in
                    content
                        .opacity(arrival.opacity)
                        .blur(radius: arrival.blur)
                } keyframes: { _ in
                    KeyframeTrack(\.opacity) {
                        MoveKeyframe(0)
                        CubicKeyframe(1, duration: 0.6)
                    }
                    KeyframeTrack(\.blur) {
                        MoveKeyframe(reduceMotion ? 0 : 8)
                        CubicKeyframe(0, duration: 0.6)
                    }
                }
                .accessibilityLabel("Title")
                .accessibilityHint(titling && title.isEmpty ? "ReGlass is adding a title." : "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { field = .title }
        }
    }

    private enum Placeholder: Equatable {
        case none, quiet, titling
    }

    /// Also none once the store has a title the field hasn't taken yet, so the shimmer hands straight over to
    /// ReGlass's title fading in rather than overlapping it.
    private var placeholder: Placeholder {
        guard title.isEmpty, (matches.first?.title ?? "").isEmpty else { return .none }
        return titling && field != .title ? .titling : .quiet
    }

    /// What an empty title shows, smaller than a title so it never reads as a question waiting for an answer. Goes the
    /// moment there's a title (typed, or ReGlass's fading in); the two placeholders cross-fade.
    private var titlePlaceholder: some View {
        ZStack(alignment: .leading) {
            switch placeholder {
            case .none:
                EmptyView()
            case .quiet:
                Text("Title")
                    .foregroundStyle(Theme.textTertiary)
                    .transition(.opacity)
            case .titling:
                TitlingLabel()
                    .transition(.opacity)
            }
        }
        .font(.title3)
        .lineLimit(1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(placeholder == .none ? nil : .easeInOut(duration: 0.35), value: placeholder)
    }

    private var textField: some View {
        TextField("Write something", text: $text, axis: .vertical)
            .font(.body)
            .foregroundStyle(Theme.ink.opacity(0.92))
            .lineSpacing(4)
            .focused($field, equals: .text)
            .accessibilityLabel("Note")
            // The room under a short note still starts typing at its end.
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { field = .text }
            }
    }

    /// "Saved", and when it last changed once it has been ("Saved · modified 5 min ago", `ReGlassNote.modified`). A copper
    /// check pops in beside it each time ReGlass saves and fades a moment later, so saving is felt without a second
    /// colour staying on screen.
    private func edited(_ note: ReGlassNote) -> some View {
        TimelineView(.everyMinute) { _ in
            HStack(spacing: 6) {
                Text(note.modified.map { "Saved · modified \($0.modifiedPhrase)" } ?? "Saved")
                    .foregroundStyle(Theme.textTertiary)
                    .contentTransition(.opacity)
                if savedCheck {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .symbolEffect(.bounce, value: saves)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .font(.footnote)
        }
        .animation(.easeOut(duration: 0.2), value: note.updated)
        .animation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.35, dampingFraction: 0.62),
                   value: savedCheck)
    }

    // MARK: Actions

    /// Fills the fields from the store: once when the screen opens, and again (`force`) when the note changes
    /// elsewhere.
    private func load(force: Bool) {
        guard !leaving, let note = matches.first, force || !loaded else { return }
        let rawTitle = (note.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = note.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if rawTitle.isEmpty, !titling, lines.count == 2,
           !lines[0].trimmingCharacters(in: .whitespaces).isEmpty,
           !lines[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let promotedTitle = lines[0].trimmingCharacters(in: .whitespaces)
            let promotedBody = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if title != promotedTitle { title = promotedTitle }
            if text.trimmingCharacters(in: .whitespacesAndNewlines) != promotedBody { text = promotedBody }
        } else {
            if title != (note.title ?? "") { title = note.title ?? "" }
            if text.trimmingCharacters(in: .whitespacesAndNewlines) != note.text { text = note.text }
        }
        storedTitle = note.title ?? ""
        loaded = true
    }

    /// The note changed in the store: elsewhere (a voice "add to that note"), by ReGlass writing its
    /// title, or by a save from here. Not being edited, the fields follow. Being edited, only a title that has just
    /// arrived comes in, and only into an empty title field, so leaving never saves the empty field over it.
    private func storeChanged() {
        guard loaded, !leaving, let note = matches.first else { return }
        let stored = note.title ?? ""
        let arrived = storedTitle.isEmpty && !stored.isEmpty
            && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        storedTitle = stored
        if field == nil {
            load(force: true)
        } else if arrived {
            title = stored
        }
        if arrived { titleArrivals += 1 }
    }

    /// A moment after the last keystroke.
    private func saveSoon() {
        guard loaded, !leaving else { return }
        pendingSave?.cancel()
        pendingSave = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Saves what changed. Empty words aren't saved (a note keeps its last words); an empty title goes back to the
    /// first line.
    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard loaded, !leaving, let note = matches.first else { return }
        let newText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if (note.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           "\(newTitle)\n\(newText)" == note.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            return
        }
        let textChanged = !newText.isEmpty && newText != note.text
        let titleChanged = newTitle != (note.title ?? "")
        guard textChanged || titleChanged else { return }
        LibraryStore.shared.updateNote(id, text: textChanged ? newText : nil, title: titleChanged ? newTitle : nil)
        saves += 1
        showSavedCheck()
    }

    private func showSavedCheck() {
        savedCheck = true
        savedCheckTimer?.cancel()
        savedCheckTimer = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            savedCheck = false
        }
    }

    /// The title, a blank line and the words, as the list's Copy does.
    private func copy() {
        saveNow()
        guard let note = matches.first else { return }
        let heading = note.title.flatMap { $0.isEmpty ? nil : $0 + "\n\n" } ?? ""
        UIPasteboard.general.string = heading + note.text
        LibraryToast.shared.show("Copied", symbol: "doc.on.doc")
    }

    /// Reminders, with the bar started on the note's heading for you to say when. Reminders opens in its own tab; the
    /// note stays open in Notes, as you left it.
    private func remind() {
        saveNow()
        guard let note = matches.first else { return }
        let heading = note.heading.isEmpty ? "Note" : note.heading
        ReminderBar.start("Remind me about \u{201C}\(ReminderBar.short(heading))\u{201D} ")
    }

    /// Into another category, keeping its topic ("Ideas · Garden" → "Work · Garden"); None drops both.
    private func move(_ category: String?) {
        saveNow()
        guard let note = matches.first else { return }
        let old = note.category.map(CategoryOrder.shared.name(for:))
        LibraryStore.shared.moveNote(id, to: category, topic: category == nil ? nil : note.topic)
        LibraryToast.shared.moved(to: category, from: old)
    }

    /// Closes the note and leaves the deleting to the home's banner: gone from the list at once, deleted for real
    /// once something else happens, unless Undo is tapped (or the iPhone shaken). What's typed is saved first, so Undo brings the note back as you
    /// left it; after that, nothing more is loaded or saved here.
    private func delete() {
        saveNow()
        leaving = true
        field = nil
        dismiss()
        let noteID = id
        LibraryToast.shared.delete(noteID, text: "Note deleted") { LibraryStore.shared.deleteNote(noteID) }
    }
}

/// The empty title's opacity and blur while ReGlass's title fades in.
private struct TitleArrival {
    var opacity = 1.0
    var blur = 0.0
}

/// "ReGlass is adding a title…" in quiet type, with a band of copper light passing slowly through the words: one pass,
/// then a rest. Still under Reduce Motion.
private struct TitlingLabel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let words = "ReGlass is adding a title\u{2026}"

    var body: some View {
        if reduceMotion {
            Text(Self.words)
                .foregroundStyle(Theme.textTertiary)
        } else {
            TimelineView(.animation) { context in
                Text(Self.words)
                    .foregroundStyle(Self.light(at: context.date))
            }
        }
    }

    /// One pass every 2.4 s: the band crosses the words in 1.6 s, then waits past their end.
    private static func light(at date: Date) -> LinearGradient {
        let cycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4)
        let centre = -0.4 + 1.8 * min(cycle / 1.6, 1)
        return LinearGradient(stops: [
            .init(color: Theme.textTertiary, location: 0),
            .init(color: Theme.accent, location: 0.5),
            .init(color: Theme.textTertiary, location: 1),
        ], startPoint: UnitPoint(x: centre - 0.3, y: 0.5), endPoint: UnitPoint(x: centre + 0.3, y: 0.5))
    }
}
