import SwiftData
import SwiftUI

/// The Search tab of the home: one search through every chat, note and reminder (`ReGlassSearch`), typed in the bar at
/// the bottom (`SearchBar`), as each page has its own bar. Before a word, it says what it looks through. Then the
/// matches, page by page in the tabs' order, with the words lit copper in their titles and in a line of what they say
/// (a long note or reply shows from its match on). Under All each page shows its first three, with Show All for the
/// rest; the chips at the top (All · Chats 4 · Notes 2 · Reminders 1, the category chips' row) narrow it to one page.
/// A note shows in Notes' own row (`NoteCard`).
///
/// A chat opens at the step that matched, its words lit, on Search's own stack; a note grows out of its card to read
/// and edit, as on Notes; a reminder or list item opens the Reminders page on it (`reveal`). Search keeps its words
/// while one is open, so Back lands on the results.
///
/// What waits in Recently Deleted is found too, dimmed in its own section at the end, so "where did that note go?"
/// finds it: a tap opens that list's Recently Deleted, a swipe right (or press and hold) puts it back.
struct SearchPage: View {
    let query: String
    @Binding var path: [AppRoute]
    /// Opens the Reminders page on this reminder or list item.
    let reveal: (UUID) -> Void
    @Query(filter: #Predicate<Conversation> { $0.deletedAt == nil }, sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]
    /// Chats in Recently Deleted, for the dimmed section at the end.
    @Query(filter: #Predicate<Conversation> { $0.deletedAt != nil }) private var deletedChats: [Conversation]
    @ObservedObject private var toast = LibraryToast.shared
    @ObservedObject private var order = CategoryOrder.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var library = SearchLibrary()
    @State private var deletedLibrary = SearchLibrary()
    @State private var scope: SearchScope?

    /// How many of each page show under All.
    private static let firstShown = 3

    var body: some View {
        let terms = SearchTerms(query)
        let results = terms.isEmpty ? SearchResults()
            : ReGlassSearch.find(terms, chats: conversations.map(ChatDocument.init), library: library,
                               hidden: toast.hidden)
        let scopes = results.scopes
        let shownScope = scope.flatMap { scopes.contains($0) ? $0 : nil }
        let deleted = terms.isEmpty ? [] : DeletedHit.find(terms, chats: deletedChats, library: deletedLibrary,
                                                           hidden: toast.hidden, scope: shownScope)
        List {
            if terms.isEmpty {
                SearchStart(chats: conversations.count, notes: library.notes.count,
                            reminders: library.reminderCount)
                    .transition(.libraryDissolve(reduceMotion: reduceMotion))
                    .libraryRow(top: 34, bottom: 20)
            } else if results.isEmpty && deleted.isEmpty {
                SearchNothing(phrase: terms.phrase)
                    .transition(.libraryDissolve(reduceMotion: reduceMotion))
                    .libraryRow(top: 30, bottom: 20)
            } else {
                if scopes.count >= 2 || shownScope != nil {
                    SearchScopeChips(scopes: scopes, results: results, selection: $scope)
                        .transition(.libraryDissolve(reduceMotion: reduceMotion))
                        .chipRow(top: 6, bottom: 0)
                }
                ForEach(shownScope.map { [$0] } ?? scopes) { page in
                    section(page, results: results, terms: terms, all: shownScope == nil,
                            first: page == (shownScope ?? scopes.first))
                }
                if !deleted.isEmpty {
                    deletedSection(deleted, terms: terms, first: results.isEmpty)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.32),
                   value: Self.motionKey(results, scope: shownScope) + deleted.map { "deleted" + $0.id.uuidString })
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.32), value: terms.isEmpty)
        // Words cleared: All again, for whatever's typed next.
        .onChange(of: terms.isEmpty) { _, empty in if empty { scope = nil } }
        .onAppear { loadLibrary() }
        .onReceive(NotificationCenter.default.publisher(for: LibraryStore.didChange)) { _ in loadLibrary() }
    }

    private func loadLibrary() {
        library = .load()
        deletedLibrary = .loadDeleted()
    }

    /// "Recently Deleted" and what matched there, dimmed: a tap opens that list's Recently Deleted, a swipe right or
    /// press and hold puts it back.
    @ViewBuilder
    private func deletedSection(_ hits: [DeletedHit], terms: SearchTerms, first: Bool) -> some View {
        LibrarySectionHeader(title: "Recently Deleted", count: hits.count)
            .libraryRow(top: first ? 14 : 24, bottom: 6)
        ForEach(hits) { hit in
            Button { path.append(.recentlyDeleted(hit.kind)) } label: {
                DeletedResultCard(hit: hit, terms: terms)
            }
            .buttonStyle(CardPressStyle())
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { putBack(hit) } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
                    .tint(Theme.Swipe.undo)
            }
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contextMenu {
                Button { putBack(hit) } label: { Label("Put Back", systemImage: "arrow.uturn.backward") }
                Button { path.append(.recentlyDeleted(hit.kind)) } label: {
                    Label("Show in Recently Deleted", systemImage: "trash")
                }
            }
            .accessibilityAction(named: "Put Back") { putBack(hit) }
            .libraryRow(top: 5, bottom: 5)
        }
    }

    /// Back in its list; the row moves up into the results there.
    private func putBack(_ hit: DeletedHit) {
        switch hit.kind {
        case .chats: ChatHistory.shared.restore([hit.id])
        case .notes: LibraryStore.shared.restoreNote(hit.id)
        case .reminders:
            if LibraryStore.shared.restoreReminder(hit.id) == nil { LibraryStore.shared.restoreItems([hit.id]) }
        }
        LibraryToast.shared.show("Put back in \(hit.kind.listName)", symbol: "arrow.uturn.backward")
    }

    // MARK: Sections

    @ViewBuilder
    private func section(_ page: SearchScope, results: SearchResults, terms: SearchTerms, all: Bool,
                         first: Bool) -> some View {
        let count = results.count(page)
        let limit = all ? Self.firstShown : 200
        LibrarySectionHeader(title: page.title, count: count)
            .libraryRow(top: first ? 14 : 24, bottom: 6)
        switch page {
        case .chats:
            ForEach(results.chats.prefix(limit)) { hit in
                Button { path.append(.chatMatch(hit.id, entry: hit.entry, query: terms.phrase)) } label: {
                    ChatResultCard(hit: hit, terms: terms)
                }
                .buttonStyle(CardPressStyle())
                .libraryRow(top: 5, bottom: 5)
            }
        case .notes:
            ForEach(results.notes.prefix(limit)) { hit in
                Button { path.append(.note(hit.id)) } label: {
                    NoteCard(note: hit.note, excerpt: hit.excerpt, terms: terms)
                }
                .buttonStyle(CardPressStyle())
                .modifier(NoteZoomSource(id: hit.id))
                .libraryRow(top: 5, bottom: 5)
            }
        case .reminders:
            ForEach(results.reminders.prefix(limit)) { hit in
                Button { reveal(hit.id) } label: {
                    ReminderResultCard(hit: hit, terms: terms, category: hit.category.map(order.name(for:)))
                }
                .buttonStyle(CardPressStyle())
                .libraryRow(top: 5, bottom: 5)
            }
        }
        if count > limit {
            ShowAllButton(text: "Show All \(count) \(page.noun(count).capitalized)") {
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.38)) { scope = page }
            }
            .libraryRow(top: 2, bottom: 2)
        }
    }

    /// What the rows' motion follows: each result's id under its page.
    private static func motionKey(_ results: SearchResults, scope: SearchScope?) -> [String] {
        let all = scope == nil
        func ids(_ page: SearchScope, _ list: [UUID]) -> [String] {
            guard scope == nil || scope == page else { return [] }
            return list.prefix(all ? firstShown : 200).map { page.rawValue + $0.uuidString }
        }
        return ids(.chats, results.chats.map(\.id)) + ids(.notes, results.notes.map(\.id))
            + ids(.reminders, results.reminders.map(\.id))
    }
}

// MARK: The bar

/// "Search chats, notes and reminders": the home's glass bar, with a magnifying glass (copper while it has the
/// keyboard) and a clear button once there are words. Search runs as you type; Search on the keyboard puts it away.
struct SearchBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let active = focused.wrappedValue
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(active ? Theme.accent : Theme.textTertiary)
                .frame(width: 40, height: 44)
                .padding(.leading, 4)
                .accessibilityHidden(true)
            TextField("Search chats, notes and reminders", text: $query)
                .focused(focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { focused.wrappedValue = false }
                .padding(.vertical, 11)
                .frame(minHeight: 44)
            if !query.isEmpty {
                Button {
                    query = ""
                    focused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityLabel("Clear Search")
                .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .padding(4)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onTapGesture { focused.wrappedValue = true }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.75),
                   value: query.isEmpty)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.8),
                   value: active)
    }
}

// MARK: Before a word, and nothing found

/// What Search looks through, before anything is typed: the emblem at rest, one line, and how many of each there are.
/// Nothing is happening yet, so nothing moves on its own, as on the other pages' empty states.
private struct SearchStart: View {
    let chats: Int
    let notes: Int
    let reminders: Int

    var body: some View {
        VStack(spacing: 14) {
            StillEmblem(symbol: "magnifyingglass", size: 60)
                .padding(.bottom, -8)
                .entrance(2)
            VStack(spacing: 6) {
                Text("Search everything")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("Every chat, note and reminder on this iPhone, at once. A word or two is enough, in any order.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }
            .entrance(3)
            Text([Self.count(chats, "chat"), Self.count(notes, "note"), Self.count(reminders, "reminder")]
                .joined(separator: " · "))
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(Theme.textTertiary)
                .contentTransition(.numericText())
                .entrance(4)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }
}

/// Nothing anywhere has those words.
private struct SearchNothing: View {
    let phrase: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("Nothing matches \u{201C}\(phrase)\u{201D}")
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text("ReGlass looked through every chat, note and reminder.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// "Show All 9 Chats", under a page's first three: a copper text button, as links are.
private struct ShowAllButton: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(text)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 4)
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
    }
}

// MARK: Chips

/// All · Chats 4 · Notes 2 · Reminders 1: the category chips' row and chips (`ChipScroller`, `ChipButton`), each page
/// with its tab's symbol, all in copper.
private struct SearchScopeChips: View {
    let scopes: [SearchScope]
    let results: SearchResults
    @Binding var selection: SearchScope?
    @Namespace private var ring
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ChipScroller(selected: selection?.rawValue ?? ChipID.all, label: "Pages") {
            chip(nil)
            ForEach(scopes) { scope in
                chip(scope)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func chip(_ scope: SearchScope?) -> some View {
        let selected = selection == scope
        return ChipButton(title: scope?.title ?? "All", image: scope.map { Image(systemName: $0.symbol) },
                          tint: Theme.accent, fill: Theme.accentFill, count: scope.map(results.count),
                          selected: selected, namespace: ring) {
            guard !selected else { return }
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.38)) { selection = scope }
        }
        .id(scope?.rawValue ?? ChipID.all)
    }
}

// MARK: Results

/// A chat or reminder found: the title (its matching words copper) with a time across from it, a line or two of what
/// matched, and a quieter footer when there's something to add (where a reminder is at). The content card of Chats and
/// Notes: Surface Content, not glass, and it sinks under the finger (`CardPressStyle`).
private struct ResultCard<Footer: View>: View {
    let title: AttributedString
    let time: String?
    let excerpt: AttributedString?
    let label: String
    let hint: String
    @ViewBuilder let footer: Footer
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let stacked = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            if stacked {
                titleText.lineLimit(3)
                timeText.padding(.top, 4)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleText.lineLimit(1)
                    Spacer(minLength: 0)
                    timeText
                }
            }
            if let excerpt, !excerpt.characters.isEmpty {
                Text(excerpt)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(stacked ? 4 : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 5)
            }
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityAddTraits(.isButton)
    }

    private var titleText: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(Theme.ink)
    }

    @ViewBuilder
    private var timeText: some View {
        if let time {
            Text(time)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
        }
    }
}

/// Something in Recently Deleted that matches.
private struct DeletedHit: Identifiable {
    let id: UUID
    let kind: DeletedKind
    let title: String
    /// What matched, for a chat or note (who said it, then the words).
    let excerpt: AttributedString?
    let deletedAt: Date

    /// Up to 20, in the tabs' order: chats, notes, then reminders and list items; one page's with a chip open.
    @MainActor
    static func find(_ terms: SearchTerms, chats: [Conversation], library: SearchLibrary, hidden: Set<UUID>,
                     scope: SearchScope?) -> [DeletedHit] {
        let found = ReGlassSearch.find(terms, chats: chats.map(ChatDocument.init), library: library, hidden: hidden)
        let when = Dictionary(chats.map { ($0.id, $0.deletedAt ?? .now) }, uniquingKeysWith: { first, _ in first })
        var hits: [DeletedHit] = []
        if scope == nil || scope == .chats {
            hits += found.chats.map { hit in
                DeletedHit(id: hit.id, kind: .chats, title: hit.title,
                           excerpt: hit.excerpt.isEmpty ? nil : spoken(hit.speaker, terms.highlight(hit.excerpt)),
                           deletedAt: when[hit.id] ?? .now)
            }
        }
        if scope == nil || scope == .notes {
            hits += found.notes.map { hit in
                DeletedHit(id: hit.id, kind: .notes, title: hit.note.heading.isEmpty ? "Note" : hit.note.heading,
                           excerpt: hit.excerpt.isEmpty ? nil : terms.highlight(hit.excerpt),
                           deletedAt: hit.note.deletedAt ?? .now)
            }
        }
        if scope == nil || scope == .reminders {
            hits += found.reminders.map { hit in
                let deletedAt: Date?
                switch hit {
                case .reminder(let reminder): deletedAt = reminder.deletedAt
                case .item(let item): deletedAt = item.deletedAt
                }
                return DeletedHit(id: hit.id, kind: .reminders, title: hit.title, excerpt: nil, deletedAt: deletedAt ?? .now)
            }
        }
        return Array(hits.prefix(20))
    }
}

/// A match in Recently Deleted: the result card, dimmed, with the days it has left where the time is and "In Recently
/// Deleted" with the list it came from underneath.
private struct DeletedResultCard: View {
    let hit: DeletedHit
    let terms: SearchTerms

    var body: some View {
        let left = DeletedKind.left(hit.deletedAt)
        ResultCard(title: terms.highlight(hit.title), time: left, excerpt: hit.excerpt,
                   label: ["In Recently Deleted", hit.kind.listName, hit.title,
                           hit.excerpt.map { String($0.characters) } ?? "", "\(left) left"]
                       .filter { !$0.isEmpty }.joined(separator: ". "),
                   hint: "Opens Recently Deleted") {
            Label("Deleted from \(hit.kind.listName)", systemImage: "trash")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 8)
        }
        .opacity(0.8)
    }
}

/// "You  …bought the tickets for Paris…": who said it, quietly, then the words.
private func spoken(_ speaker: String?, _ text: AttributedString) -> AttributedString {
    guard let speaker else { return text }
    var lead = AttributedString(speaker + "  ")
    lead.foregroundColor = Theme.textTertiary
    lead.font = .subheadline.weight(.medium)
    return lead + text
}

private struct ChatResultCard: View {
    let hit: ChatHit
    let terms: SearchTerms

    var body: some View {
        ResultCard(title: terms.highlight(hit.title), time: hit.updated.libraryDayTime,
                   excerpt: hit.excerpt.isEmpty ? nil : spoken(hit.speaker, terms.highlight(hit.excerpt)),
                   label: ["Chat", hit.title, [hit.speaker, hit.excerpt].compactMap { $0 }.joined(separator: ": "),
                           hit.updated.libraryDayTime].filter { !$0.isEmpty }.joined(separator: ". "),
                   hint: "Opens the chat") {
            EmptyView()
        }
    }
}

private struct ReminderResultCard: View {
    let hit: ReminderHit
    let terms: SearchTerms
    /// Its category's shown name.
    let category: String?

    var body: some View {
        ResultCard(title: terms.highlight(hit.title), time: time, excerpt: nil,
                   label: ["Reminder", hit.title, status, category ?? "", time ?? ""]
                       .filter { !$0.isEmpty }.joined(separator: ". "),
                   hint: "Shows it in Reminders") {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // Still to come is live, so copper; done or gone off is only said, quietly.
                Label(status, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(hit.isOpen ? Theme.accent : Theme.textSecondary)
                    .lineLimit(1)
                if let category {
                    CategoryLine(name: category)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
        }
    }

    /// When it's due, went off or was ticked off; nothing for a list item still open.
    private var time: String? {
        switch hit {
        case .reminder(let reminder):
            return (reminder.completed ?? reminder.fired ?? reminder.due).libraryDayTime
        case .item(let item):
            return item.completed?.libraryDayTime
        }
    }

    private var status: String {
        switch hit {
        case .reminder(let reminder):
            if reminder.completed != nil { return "Ticked off" }
            if reminder.fired != nil { return "Went off" }
            return "Coming up"
        case .item(let item):
            return item.isOpen ? "On the list" : "Ticked off"
        }
    }

    private var symbol: String {
        switch hit {
        case .reminder(let reminder):
            if reminder.completed != nil { return "checkmark.circle" }
            return reminder.fired != nil ? "bell" : "bell.badge"
        case .item(let item):
            return item.isOpen ? "circle" : "checkmark.circle"
        }
    }
}

/// A reminder's category: its symbol and name in its colour, as on the Reminders page. Never copper, so search's words
/// aren't lit here.
private struct CategoryLine: View {
    let name: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(category: name)
                .font(.caption2)
            Text(name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(LibraryCategory.color(name))
        .accessibilityHidden(true)
    }
}

// MARK: Shown from Search

extension View {
    /// The thin copper ring round a row Search opened a page on, for a moment: a 1.5pt accent-fill stroke (a search
    /// ring) with a soft blur of itself behind it, light rather than a shadow.
    func searchFlash(_ on: Bool) -> some View {
        overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.accentFill, lineWidth: 3)
                    .blur(radius: 6)
                    .opacity(0.8)
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.accentFill, lineWidth: 1.5)
            }
            .opacity(on ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
