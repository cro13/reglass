import SwiftData
import SwiftUI

// Recently Deleted. Nothing deleted is erased straight away: it waits here for 30 days
// (`LibraryStore.keepDeletedDays`), then goes for good. Each list has its own, opened from a quiet row at its end
// (`RecentlyDeletedRow`): Chats' chats, Notes' notes, Reminders' reminders and list items.

/// Whose Recently Deleted: one per list.
enum DeletedKind: String, Hashable, Sendable {
    case chats
    case notes
    case reminders

    /// The line at the top of the page.
    var explanation: String {
        let days = LibraryStore.keepDeletedDays
        switch self {
        case .chats: return "Deleted chats stay here for \(days) days, then they're erased for good."
        case .notes: return "Deleted notes stay here for \(days) days, then they're erased for good."
        case .reminders: return "Deleted reminders and list items stay here for \(days) days, then they're erased for good."
        }
    }

    /// Where Put Back puts things, for the banner ("Put back in Notes").
    var listName: String {
        switch self {
        case .chats: return "Chats"
        case .notes: return "Notes"
        case .reminders: return "Reminders"
        }
    }

    /// "3 notes", "1 chat", "2 things" (reminders and items together).
    func count(_ n: Int) -> String {
        let noun: String
        switch self {
        case .chats: noun = n == 1 ? "chat" : "chats"
        case .notes: noun = n == 1 ? "note" : "notes"
        case .reminders: noun = n == 1 ? "thing" : "things"
        }
        return "\(n) \(noun)"
    }

    /// How long something deleted at `deletedAt` has left here: "30 days", "2 days", then "Last day" for its final
    /// 24 hours.
    static func left(_ deletedAt: Date, now: Date = .now) -> String {
        let days = Int((LibraryStore.erasedOn(deletedAt).timeIntervalSince(now) / 86_400).rounded(.up))
        return days <= 1 ? "Last day" : "\(days) days"
    }
}

// MARK: The row at the end of a list

/// The last row of Chats, Notes and Reminders while something waits in Recently Deleted: a bin, "Recently Deleted",
/// how many, and a chevron. A card like the rows above it, but with nothing to read, so it stays quiet.
struct RecentlyDeletedRow: View {
    let count: Int
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text("Recently Deleted")
                    .font(.body)
                    .foregroundStyle(Theme.ink.opacity(0.9))
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Theme.textTertiary)
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .animation(Theme.Motion.inline, value: count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recently Deleted, \(count)")
        .accessibilityHint("Deleted things wait here for \(LibraryStore.keepDeletedDays) days")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: The page

/// One list's Recently Deleted: the line saying how long things stay, then what was deleted, most recent first, each
/// with the days it has left. Swipe right to Put Back (it returns to its list and category), swipe left to Delete it
/// for good (with Undo); a tap shows both as pills under the row, and press and hold has them too. Put Back All and
/// Delete All at the bottom; Delete All asks first, in place.
struct RecentlyDeletedPage: View {
    let kind: DeletedKind

    var body: some View {
        ZStack {
            ReGlassBackdrop()
            switch kind {
            case .chats: DeletedChats()
            case .notes: DeletedNotes().modelContainer(LibraryStore.shared.container)
            case .reminders: DeletedReminders().modelContainer(LibraryStore.shared.container)
            }
        }
        .navigationTitle("Recently Deleted")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            // Anything past its 30 days goes as the page opens, so nothing here reads "0 days".
            LibraryStore.shared.purgeDeleted()
            ChatHistory.shared.purgeDeleted()
        }
    }
}

/// One thing on the page, whatever its kind.
private struct DeletedEntry: Identifiable {
    let id: UUID
    let deletedAt: Date
    /// What it is, for VoiceOver and the banner ("Bike rack idea").
    let name: String
    let row: AnyView
}

private struct DeletedNotes: View {
    @Query(filter: #Predicate<ReGlassNote> { $0.deletedAt != nil }, sort: \ReGlassNote.deletedAt, order: .reverse)
    private var notes: [ReGlassNote]

    var body: some View {
        DeletedList(kind: .notes, entries: notes.map { note in
            let snapshot = note.snapshot
            return DeletedEntry(id: note.id, deletedAt: note.deletedAt ?? .now, name: note.heading,
                                row: AnyView(NoteCard(note: snapshot, left: DeletedKind.left(note.deletedAt ?? .now))))
        }, restore: { ids in
            for id in ids { LibraryStore.shared.restoreNote(id) }
        }, erase: { ids in
            LibraryStore.shared.eraseNotes(ids)
        })
    }
}

private struct DeletedReminders: View {
    @Query(filter: #Predicate<ReGlassReminder> { $0.deletedAt != nil }) private var reminders: [ReGlassReminder]
    @Query(filter: #Predicate<ReGlassItem> { $0.deletedAt != nil }) private var items: [ReGlassItem]
    @ObservedObject private var order = CategoryOrder.shared

    var body: some View {
        let entries = reminders.map { reminder in
            DeletedEntry(id: reminder.id, deletedAt: reminder.deletedAt ?? .now, name: reminder.title,
                         row: AnyView(DeletedLine(symbol: "bell", tint: Theme.textSecondary, title: reminder.title,
                                                  subtitle: Self.when(reminder), subtitleTint: Theme.textSecondary,
                                                  left: DeletedKind.left(reminder.deletedAt ?? .now))))
        } + items.map { item in
            let list = order.name(for: item.category)
            return DeletedEntry(id: item.id, deletedAt: item.deletedAt ?? .now, name: item.title,
                                row: AnyView(DeletedLine(symbol: item.isOpen ? "circle" : "checkmark.circle",
                                                         tint: Theme.textSecondary, title: item.title,
                                                         subtitle: item.isOpen ? list : "\(list) · Got",
                                                         subtitleTint: LibraryCategory.color(item.category),
                                                         category: item.category,
                                                         left: DeletedKind.left(item.deletedAt ?? .now))))
        }
        let reminderIDs = Set(reminders.map(\.id))
        DeletedList(kind: .reminders, entries: entries.sorted { $0.deletedAt > $1.deletedAt }, restore: { ids in
            let store = LibraryStore.shared
            for id in ids where reminderIDs.contains(id) { store.restoreReminder(id) }
            store.restoreItems(ids.filter { !reminderIDs.contains($0) })
        }, erase: { ids in
            let store = LibraryStore.shared
            store.eraseReminders(ids.filter { reminderIDs.contains($0) })
            store.eraseItems(ids.filter { !reminderIDs.contains($0) })
        })
    }

    /// "Was due Tue 09:00", "Went off Today 18:00", "Ticked off".
    private static func when(_ reminder: ReGlassReminder) -> String {
        if reminder.completed != nil { return "Ticked off" }
        if let fired = reminder.fired { return "Went off \(fired.libraryDayTime)" }
        return "Was due \(reminder.due.libraryDayTime)"
    }
}

private struct DeletedChats: View {
    @Query(filter: #Predicate<Conversation> { $0.deletedAt != nil }, sort: \Conversation.deletedAt, order: .reverse)
    private var conversations: [Conversation]

    var body: some View {
        DeletedList(kind: .chats, entries: conversations.map { conversation in
            let entries = conversation.orderedEntries
            let title = ChatsView.title(of: conversation, entries)
            return DeletedEntry(id: conversation.id, deletedAt: conversation.deletedAt ?? .now, name: title,
                                row: AnyView(DeletedLine(symbol: nil, tint: Theme.textSecondary, title: title,
                                                         subtitle: Self.snippet(entries), subtitleTint: Theme.textSecondary,
                                                         left: DeletedKind.left(conversation.deletedAt ?? .now))))
        }, restore: { ids in
            ChatHistory.shared.restore(ids)
        }, erase: { ids in
            ChatHistory.shared.erase(ids)
        })
    }

    /// The last thing the glasses said, else the last thing ReGlass did, on one line.
    private static func snippet(_ entries: [ChatEntry]) -> String {
        let text = entries.last(where: { $0.kind == .reply })?.text ?? entries.last(where: { $0.kind == .action })?.text ?? ""
        return text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

// MARK: The list

private struct DeletedList: View {
    let kind: DeletedKind
    let entries: [DeletedEntry]
    let restore: ([UUID]) -> Void
    let erase: ([UUID]) -> Void
    @ObservedObject private var toast = LibraryToast.shared
    /// The row a tap opened, showing Put Back and Delete. One at a time.
    @State private var expanded: UUID?
    /// Delete All was tapped: the bar asks before erasing.
    @State private var confirmingAll = false
    /// Goes up with each Put Back, for a light success tap.
    @State private var putBacks = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A row deleted for good a moment ago stays out while its Undo shows.
        let shown = entries.filter { !toast.hidden.contains($0.id) }
        List {
            Text(kind.explanation)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .libraryRow(top: 8, bottom: 8)
            if shown.isEmpty {
                VStack(spacing: 14) {
                    StillEmblem(symbol: "trash", size: 56)
                    Text("Nothing here")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity)
                .libraryRow(top: 60, bottom: 20)
            }
            ForEach(shown) { entry in
                row(entry)
                    .libraryRow(top: 5, bottom: 5)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.35), value: shown.map(\.id))
        .animation(reduceMotion ? .easeOut(duration: 0.2) : Theme.Motion.inline, value: expanded)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !shown.isEmpty || toast.current != nil {
                VStack(spacing: 10) {
                    LibraryToastView()
                    if !shown.isEmpty { bar(shown) }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
        }
        .sensoryFeedback(.success, trigger: putBacks)
        .onChange(of: shown.count) { _, count in
            if count == 0 { confirmingAll = false }
        }
    }

    // MARK: Rows

    private func row(_ entry: DeletedEntry) -> some View {
        VStack(spacing: 8) {
            Button {
                expanded = expanded == entry.id ? nil : entry.id
            } label: {
                entry.row
            }
            .buttonStyle(CardPressStyle())
            if expanded == entry.id {
                HStack(spacing: 10) {
                    pill("Put Back", symbol: "arrow.uturn.backward", tint: Theme.accent) { putBack([entry]) }
                    pill("Delete", symbol: "trash", tint: Theme.actionRed) { eraseOne(entry) }
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { putBack([entry]) } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
                .tint(Theme.Swipe.undo)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { eraseOne(entry) } label: { Label("Delete", systemImage: "trash") }
                .tint(Theme.Swipe.delete)
        }
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu {
            Button { putBack([entry]) } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
            Divider()
            Button(role: .destructive) { eraseOne(entry) } label: { Label("Delete", systemImage: "trash") }
        }
        .accessibilityAction(named: "Put Back") { putBack([entry]) }
        .accessibilityAction(named: "Delete") { eraseOne(entry) }
    }

    /// A glass capsule with a symbol and a word in `tint`: the row's Put Back and Delete, and the bar's buttons.
    private func pill(_ title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Capsule())
                .glassSurface(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }

    // MARK: Bar

    /// Put Back All and Delete All; after Delete All, "Delete 3 notes for good?" with Cancel and Delete, in place.
    @ViewBuilder
    private func bar(_ shown: [DeletedEntry]) -> some View {
        if confirmingAll {
            VStack(spacing: 10) {
                Text("Delete \(kind.count(shown.count)) for good?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 10) {
                    pill("Cancel", symbol: "xmark", tint: Theme.ink) { confirmingAll = false }
                    pill("Delete", symbol: "trash", tint: Theme.actionRed) {
                        confirmingAll = false
                        erase(shown.map(\.id))
                        LibraryToast.shared.show("Deleted \(kind.count(shown.count)) for good", symbol: "trash")
                    }
                }
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
        } else {
            HStack(spacing: 10) {
                pill("Put Back All", symbol: "arrow.uturn.backward", tint: Theme.accent) { putBack(shown) }
                pill("Delete All", symbol: "trash", tint: Theme.actionRed) { confirmingAll = true }
            }
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    // MARK: Actions

    /// Back in its list at once, with a banner saying where.
    private func putBack(_ chosen: [DeletedEntry]) {
        guard !chosen.isEmpty else { return }
        LibraryToast.shared.commitWaiting()
        expanded = nil
        restore(chosen.map(\.id))
        putBacks += 1
        let what = chosen.count == 1 ? "Put back in \(kind.listName)" : "Put back \(kind.count(chosen.count))"
        LibraryToast.shared.show(what, symbol: "arrow.uturn.backward")
    }

    /// Gone from the page at once, erased once something else happens, unless Undo is tapped.
    private func eraseOne(_ entry: DeletedEntry) {
        expanded = nil
        let id = entry.id
        LibraryToast.shared.delete(id, text: "Deleted for good") { erase([id]) }
    }
}

// MARK: Rows

/// A deleted reminder, list item or chat: a quiet symbol, the title, one line under it, and the days it has left on
/// the right. A content card like the lists' own.
private struct DeletedLine: View {
    /// An SF Symbol, or nil for none (chats).
    let symbol: String?
    let tint: Color
    let title: String
    let subtitle: String
    let subtitleTint: Color
    /// A list item's category: its symbol in front of the subtitle.
    var category: String?
    let left: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 26)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title.isEmpty ? "Untitled" : title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(left)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                }
                if !subtitle.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        if let category {
                            Image(category: category)
                                .font(.caption2)
                                .foregroundStyle(subtitleTint)
                        }
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(subtitleTint)
                            .lineLimit(1)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle, "\(left) left"].filter { !$0.isEmpty }.joined(separator: ". "))
        .accessibilityHint("Shows Put Back and Delete")
        .accessibilityAddTraits(.isButton)
    }
}
