import SwiftData
import SwiftUI
import UIKit

/// The Notes page of the home: every note, newest written first, under the category chips (All · Ideas 6 · Work 2 ·
/// …); the Search tab finds a note by its words. Each row shows the note's heading, when it was written and how, two lines of it, its
/// category ("Ideas · Garden") and, once changed since, when (`NoteCard`). A row opens the note, ready to edit, and has
/// Mail's row actions: swipe right to copy it or be reminded about it, swipe left to delete it (with Undo), or press
/// and hold for those and Move To ▸. A deleted note waits in Recently Deleted for 30 days, behind a row at the end of
/// the list while there's something in it. The home's bar below writes a new one, in the open chip's category.
struct NotesPage: View {
    @Binding var path: [AppRoute]
    /// The chip that's open (nil: All). The home's bar writes into it.
    @Binding var category: String?
    @Query(filter: #Predicate<ReGlassNote> { $0.deletedAt == nil }, sort: \ReGlassNote.created, order: .reverse)
    private var notes: [ReGlassNote]
    /// What waits in Recently Deleted, for the row at the end.
    @Query(filter: #Predicate<ReGlassNote> { $0.deletedAt != nil }) private var deleted: [ReGlassNote]
    @ObservedObject private var toast = LibraryToast.shared
    @ObservedObject private var order = CategoryOrder.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let topID = "notes-top"

    var body: some View {
        // A note just deleted leaves at once; Undo brings it back.
        let left = notes.filter { !toast.hidden.contains($0.id) }
        let chips = CategoryChip.make(order: order.names, present: left.map(\.category), counted: left.map(\.category))
        let chip = CategoryChip.valid(category, in: chips)
        let found = notes.filter { CategoryChip.files($0.category, under: chip) }
        let shown = found.filter { !toast.hidden.contains($0.id) }
        let anyLeft = !left.isEmpty
        let chipsShown = anyLeft && CategoryChip.showsRow(chips, selection: chip,
                                                          unfiled: left.contains { CategoryChip.unfiled($0.category) })
        ScrollViewReader { proxy in
            List {
                // Where a note just written lands, for the list to scroll back to.
                Color.clear
                    .frame(height: 0)
                    .id(Self.topID)
                    .libraryRow(top: 0, bottom: 0)
                if chipsShown {
                    CategoryChips(chips: chips, selection: $category)
                        .entrance(2)
                        .transition(.libraryDissolve(reduceMotion: reduceMotion))
                        .chipRow(top: 6, bottom: 6)
                }
                if !anyLeft {
                    LibraryEmptyState(symbol: "note.text",
                                      title: "No notes yet",
                                      message: "Ideas you say to your glasses are kept here, word for word.",
                                      phrase: "“Hey Meta, take a note…”",
                                      footer: "Or write one below.")
                        .libraryRow(top: 34, bottom: 20)
                } else {
                    ForEach(shown) { note in
                        Button { path.append(.note(note.id)) } label: {
                            NoteCard(note: note.snapshot)
                        }
                        .buttonStyle(CardPressStyle())
                        .modifier(NoteZoomSource(id: note.id))
                        .modifier(NoteRowActions(category: note.category,
                                                 copy: { copy(note) }, remind: { remind(note) },
                                                 move: { move(note, to: $0) }, delete: { delete(note) }))
                        // Counted with deleted-but-undoable notes, so a delete doesn't replay a row's entrance.
                        .modifier(OptionalEntranceIndex(index: found.prefix(7).firstIndex(of: note).map { $0 + 3 }))
                        .libraryRow(top: !chipsShown && note.id == shown.first?.id ? 10 : 5, bottom: 5)
                    }
                }
                let waiting = deleted.filter { !toast.hidden.contains($0.id) }.count
                if waiting > 0 {
                    RecentlyDeletedRow(count: waiting) { path.append(.recentlyDeleted(.notes)) }
                        .transition(.libraryDissolve(reduceMotion: reduceMotion))
                        .libraryRow(top: anyLeft ? 14 : 4, bottom: 5)
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.bottom, 12, for: .scrollContent)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.35), value: shown.map(\.id))
            // The open chip's category has no notes left (moved, deleted): back to All, and the bar with it.
            .onChange(of: chips.map(\.name)) { _, _ in
                if category != nil, chip == nil { withAnimation(reduceMotion ? nil : .snappy(duration: 0.38)) { category = nil } }
            }
            // A note just written below: bring the top of the list, where it lands, into view. Not when the top note
            // was deleted (Undo's time ran out): the list just closes up where it is.
            .onChange(of: notes.first?.id) { old, _ in
                guard let old, notes.contains(where: { $0.id == old }) else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { proxy.scrollTo(Self.topID, anchor: .top) }
            }
        }
    }

    // MARK: Row actions

    /// The title, a blank line and the words, as the note's own Copy does.
    private func copy(_ note: ReGlassNote) {
        let heading = note.title.flatMap { $0.isEmpty ? nil : $0 + "\n\n" } ?? ""
        UIPasteboard.general.string = heading + note.text
        LibraryToast.shared.show("Copied", symbol: "doc.on.doc")
    }

    /// Reminders, with the bar started on the note's heading, for the owner to say when.
    private func remind(_ note: ReGlassNote) {
        let heading = note.heading.isEmpty ? "Note" : note.heading
        ReminderBar.start("Remind me about \u{201C}\(ReminderBar.short(heading))\u{201D} ")
    }

    /// Into another category, keeping its topic ("Ideas · Garden" → "Work · Garden"); None drops both.
    private func move(_ note: ReGlassNote, to category: String?) {
        let old = note.category.map(order.name(for:))
        LibraryStore.shared.moveNote(note.id, to: category, topic: category == nil ? nil : note.topic)
        LibraryToast.shared.moved(to: category, from: old)
    }

    /// Gone from the list now, deleted for real once the banner's Undo has passed.
    private func delete(_ note: ReGlassNote) {
        let id = note.id
        LibraryToast.shared.delete(id, text: "Note deleted") {
            LibraryStore.shared.deleteNote(id)
        }
    }
}

// MARK: Row

/// One note. The heading, and across from it when it was written ("Today 14:32") after the mark for how it was made;
/// up to two lines of what it says; then a quieter line: the category on the left ("Ideas · Garden", the name in the
/// category's colour) and, once it has been changed since, when ("Modified yesterday") on the right in smaller type,
/// under the day it was written. No category and no change: no third line.
///
/// Search shows its notes in the same row, with the lines from the first match on (`excerpt`) and its words lit copper
/// in the heading and the lines. Recently Deleted shows the days the note has left there (`left`) where the date is.
struct NoteCard: View {
    let note: NoteSnapshot
    /// The lines to show under the heading instead of the note's first ones.
    var excerpt: String?
    /// Search's words, lit copper (none: plain).
    var terms = SearchTerms("")
    /// In Recently Deleted: how long it has left there ("29 days"), in place of when it was written.
    var left: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        let footer = filed != nil || note.modified != nil
        VStack(alignment: .leading, spacing: 0) {
            if stacked {
                headingText.lineLimit(3)
                corner.padding(.top, 4)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    headingText.lineLimit(1)
                    Spacer(minLength: 0)
                    corner
                }
            }
            if !snippet.isEmpty {
                Text(terms.highlight(snippet))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(stacked ? 4 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
            }
            if footer {
                Group {
                    if stacked {
                        VStack(alignment: .leading, spacing: 4) {
                            category
                            modified
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            category
                            Spacer(minLength: 0)
                            modified
                        }
                    }
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([note.heading, snippet,
                             filed.map { [$0.name, $0.topic].compactMap { $0 }.joined(separator: ", ") } ?? "",
                             left.map { "\($0) left" } ?? "\(note.source.madeHow), \(note.created.libraryDayTime)",
                             note.modified.map { "Modified \($0.modifiedPhrase)" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityHint(left == nil ? "Opens the note" : "Shows Put Back and Delete")
        .accessibilityAddTraits(.isButton)
    }

    private var headingText: some View {
        Text(terms.highlight(note.heading.isEmpty ? "Note" : note.heading))
            .font(.headline)
            .foregroundStyle(Theme.ink)
    }

    /// The top right: when it was written, or in Recently Deleted the days it has left.
    @ViewBuilder
    private var corner: some View {
        if let left {
            Text(left)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
                .accessibilityHidden(true)
        } else {
            written
        }
    }

    /// The mark for how it was made, then the day and time it was written. Today's says "Today", so it's kept current
    /// past midnight while the list is on screen.
    private var written: some View {
        HStack(spacing: 5) {
            Image(systemName: note.source.markSymbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            TimelineView(.everyMinute) { _ in
                Text(note.created.libraryDayTime)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// "Ideas · Garden": the category's symbol and name in its colour, the topic quieter.
    @ViewBuilder
    private var category: some View {
        if let filed {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(category: filed.name)
                    .font(.caption2)
                Text("\(Text(filed.name).fontWeight(.medium))\(Text(filed.topic.map { " · \($0)" } ?? "").foregroundStyle(Theme.textTertiary))")
                    .font(.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(LibraryCategory.color(filed.name))
            .layoutPriority(1)
        }
    }

    /// "Modified 12 min ago", kept current while the list is on screen; nothing if it hasn't been changed since.
    @ViewBuilder
    private var modified: some View {
        if let modified = note.modified {
            TimelineView(.everyMinute) { _ in
                Text("Modified \(modified.modifiedPhrase)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            .fixedSize()
        }
    }

    /// Its category's shown name and topic, or nil for a note with no category yet.
    private var filed: (name: String, topic: String?)? {
        guard let category = LibraryStore.clean(note.category) else { return nil }
        return (CategoryOrder.shared.name(for: category), LibraryStore.clean(note.topic))
    }

    /// The words under the heading: all of the text when the note has a title, else what follows its first line
    /// (which is the heading). Line breaks become spaces so two lines hold as much as they can.
    private var snippet: String {
        if let excerpt { return excerpt }
        let body: String
        if let title = note.title, !title.isEmpty {
            body = note.text
        } else {
            let parts = note.text.split(separator: "\n", maxSplits: 1)
            body = parts.count > 1 ? String(parts[1]) : ""
        }
        return body.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: Opening

/// The card a note opens out of: the note screen grows from it and shrinks back into it, its rounded corners and all
/// (`NoteZoomDestination`). Not under Reduce Motion, where the note cross-fades in as iOS's own pushes do.
struct NoteZoomSource: ViewModifier {
    let id: UUID
    @Environment(\.noteZoom) private var zoom
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let zoom, !reduceMotion {
            content.matchedTransitionSource(id: id, in: zoom) { source in
                source.clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        } else {
            content
        }
    }
}

// MARK: Row actions

/// Mail's row actions on a note card, as on a chat (`CardRowActions`): swipe right for Copy and Remind Me, swipe left
/// to Delete (a full swipe deletes straight away), and on a press and hold the same with Move To ▸ as well.
private struct NoteRowActions: ViewModifier {
    let category: String?
    let copy: () -> Void
    let remind: () -> Void
    let move: (String?) -> Void
    let delete: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                    .tint(Theme.Swipe.copy)
                Button(action: remind) { Label("Remind Me", systemImage: "bell") }
                    .tint(Theme.Swipe.remind)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
                    .tint(Theme.Swipe.delete)
            }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contextMenu {
                Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                Button(action: remind) { Label("Remind Me", systemImage: "bell") }
                MoveToMenu(current: category, allowsNone: true, move: move)
                Divider()
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
            }
    }
}
