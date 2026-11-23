import SwiftUI
import UIKit

/// The home's three pages, in the tab bar's order, and Search across them (the round tab on its own at the end).
enum HomePage: Int, CaseIterable, Hashable {
    case chats, notes, reminders, search

    var title: String {
        switch self {
        case .chats: return "Chats"
        case .notes: return "Notes"
        case .reminders: return "Reminders"
        case .search: return "Search"
        }
    }

    /// The tab's symbol.
    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .notes: return "note.text"
        case .reminders: return "bell"
        case .search: return "magnifyingglass"
        }
    }
}

/// ReGlass's home: Chats · Notes · Reminders as tabs in the system's Liquid Glass tab bar (Chats first, the chosen one
/// in copper, a red count on Reminders for the ones due now or overdue), and Search, the round tab on its own, which looks
/// through Chats, Notes and Reminders. Each page has its title and the glass Settings button at the top, and its own bar
/// for typing floating just above the tabs: ask ReGlass, write a note, set a reminder, or search (the keyboard comes
/// up as Search opens).
/// Pages change from the tabs only, so a sideways swipe on a row is always the row's own actions (Mail-style). The
/// glasses card stays at the top of Chats (or, with no glasses yet, the card that sets them up). While the keyboard is
/// up, the tabs give way to it.
///
/// Each tab has its own navigation stack and path, as in iOS's own apps: a pushed screen (a chat, a note, Settings)
/// keeps the tab bar below it, the system back button and the edge swipe, and each tab remembers where it was. The
/// typing bars belong to the pages themselves, so they never show over a pushed screen.
///
/// Notes and Reminders read ReGlass's library (`LibraryStore`), so their subtrees carry its model container; Chats
/// keep the app's root container. Each of the two keeps its open category chip here, so its bar can follow it.
struct LibraryHome: View {
    @State private var page: HomePage = .chats
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var chatsPath: [AppRoute] = []
    @State private var notesPath: [AppRoute] = []
    @State private var remindersPath: [AppRoute] = []
    @State private var searchPath: [AppRoute] = []
    @State private var noteDraft = ""
    @State private var searchQuery = ""
    /// A reminder or list item Search asked Reminders to show.
    @State private var revealReminder: UUID?
    @State private var reminderDraft = ""
    /// The chip open on Notes and on Reminders (nil: All).
    @State private var noteCategory: String?
    @State private var reminderCategory: String?
    /// The reminders the tab counts: due now or overdue (`countDue`).
    @State private var due: [UUID] = []
    @ObservedObject private var toast = LibraryToast.shared
    @FocusState private var askingReGlass: Bool
    @FocusState private var writingNote: Bool
    @FocusState private var settingReminder: Bool
    @FocusState private var searching: Bool
    /// A note opens out of its card and closes back into it, on Notes and in Search's results.
    @Namespace private var noteZoom
    @Namespace private var searchZoom

    // The Reminders count keeps the system's red badge, as every iOS app's does: it means "due", not "ReGlass".

    var body: some View {
        TabView(selection: $page) {
            Tab(HomePage.chats.title, systemImage: HomePage.chats.symbol, value: HomePage.chats) {
                tabStack(.chats, path: $chatsPath) {
                    ChatsView(path: $chatsPath)
                } bar: {
                    // A new chat opens at once, with ReGlass's answer coming in there.
                    ChatComposer(purpose: .newChat, composing: $askingReGlass) { chat in
                        askingReGlass = false
                        chatsPath.append(.conversation(chat))
                    }
                }
            }
            Tab(HomePage.notes.title, systemImage: HomePage.notes.symbol, value: HomePage.notes) {
                tabStack(.notes, path: $notesPath) {
                    NotesPage(path: $notesPath, category: $noteCategory)
                        .modelContainer(LibraryStore.shared.container)
                } bar: {
                    NoteComposer(draft: $noteDraft, focused: $writingNote, category: noteCategory)
                }
                .environment(\.noteZoom, noteZoom)
            }
            Tab(HomePage.reminders.title, systemImage: HomePage.reminders.symbol, value: HomePage.reminders) {
                tabStack(.reminders, path: $remindersPath) {
                    RemindersPage(active: page == .reminders, category: $reminderCategory, reveal: $revealReminder,
                                  path: $remindersPath)
                        .modelContainer(LibraryStore.shared.container)
                } bar: {
                    ReminderComposer(draft: $reminderDraft, focused: $settingReminder, active: page == .reminders,
                                     category: reminderCategory)
                }
            }
            .badge(due.filter { !toast.hidden.contains($0) }.count)
            Tab(HomePage.search.title, systemImage: HomePage.search.symbol, value: HomePage.search, role: .search) {
                tabStack(.search, path: $searchPath) {
                    SearchPage(query: searchQuery, path: $searchPath, reveal: showReminder)
                } bar: {
                    SearchBar(query: $searchQuery, focused: $searching)
                }
                .environment(\.noteZoom, searchZoom)
            }
        }
        .tint(Theme.accent)
        .sensoryFeedback(.selection, trigger: page)
        .onChange(of: page) { _, now in
            // A half-typed note or reminder stays in its draft; the keyboard goes with the page it belonged to.
            askingReGlass = false
            writingNote = false
            settingReminder = false
            searching = false
            // Another page: a delete waiting on its Undo goes through.
            toast.commitWaiting()
            // Search is for typing: the keyboard comes up as it opens, once the page is on screen (not over a chat or
            // note opened from its results).
            if now == .search, searchPath.isEmpty {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    if page == .search, searchPath.isEmpty { searching = true }
                }
            }
        }
        // Opening a screen is the next action too: a delete waiting on its Undo goes through. Closing one isn't (a
        // note deleted from its own screen closes it, and the Undo then shows on Notes).
        .onChange(of: chatsPath.count + notesPath.count + remindersPath.count + searchPath.count) { before, now in
            if now > before { toast.commitWaiting() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reglassReminderDraft)) { notification in
            guard let draft = notification.object as? String else { return }
            startReminder(draft, category: notification.userInfo?[ReminderBar.categoryKey] as? String)
        }
        .onReceive(NotificationCenter.default.publisher(for: LibraryStore.didChange)) { _ in countDue() }
        // A reminder's time comes, or its hour after going off passes, without the library changing.
        .task {
            while !Task.isCancelled {
                countDue()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// One tab: its own navigation stack, with the page at the root (`tabPage`) and every route it can push.
    private func tabStack<Content: View, Bar: View>(_ item: HomePage, path: Binding<[AppRoute]>,
                                                    @ViewBuilder content: () -> Content,
                                                    @ViewBuilder bar: () -> Bar) -> some View {
        NavigationStack(path: path) {
            tabPage(item, path: path, content: content, bar: bar)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: AppRoute.self) { route in
                    AppDestination(route: route)
                }
        }
    }

    /// One page: the backdrop, the page's title with Settings, the page itself, and its bar floating over the bottom
    /// of the list (which scrolls on underneath), with the Undo banner just above the bar. Only the page on screen,
    /// with nothing pushed over it, shows the banner, so it buzzes and speaks once.
    private func tabPage<Content: View, Bar: View>(_ item: HomePage, path: Binding<[AppRoute]>,
                                                   @ViewBuilder content: () -> Content,
                                                   @ViewBuilder bar: () -> Bar) -> some View {
        ZStack {
            ReGlassBackdrop()
            VStack(spacing: 0) {
                header(item, path: path)
                    .entrance(0)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                content()
                    .frame(maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ZStack(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: Theme.backdropBottom.opacity(0), location: 0),
                        .init(color: Theme.backdropBottom.opacity(0.86), location: 0.48),
                        .init(color: Theme.backdropBottom.opacity(0.96), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 84)
                .allowsHitTesting(false)
                bar()
            }
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) {
                // Its bottom sits 6pt above the bar's top, so it never pushes the list.
                LibraryToastView(shown: page == item && path.wrappedValue.isEmpty)
                    .alignmentGuide(.top) { $0[.bottom] + 6 }
            }
        }
    }

    private func header(_ item: HomePage, path: Binding<[AppRoute]>) -> some View {
        HStack(alignment: .center) {
            Text(item.title)
                .displayFont(.largeTitle)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { path.wrappedValue.append(.settings) } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)   // stays inside its 44pt circle
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
                    .glassSurface(in: Circle(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    /// Reminders, with the bar started on `draft` and the keyboard up, for the owner to finish in their own words.
    /// `category` opens that chip (an item's Remind Me); a draft from another page opens All, so a chip left open
    /// earlier doesn't file a note's reminder under it. A screen pushed on Reminders closes; the other tabs keep theirs.
    private func startReminder(_ draft: String, category: String?) {
        remindersPath.removeAll()
        AssistantController.shared.startReminderAfresh()
        reminderDraft = draft
        if let category {
            reminderCategory = category
        } else if page != .reminders {
            reminderCategory = nil
        }
        page = .reminders
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))   // after the page has changed, so the bar takes the focus
            if page == .reminders { settingReminder = true }
        }
    }

    /// Reminders, on a reminder or list item Search found: the page opens it and brings it into view. A screen pushed
    /// on Reminders closes first, so the page is there to show it.
    private func showReminder(_ id: UUID) {
        searching = false
        remindersPath.removeAll()
        revealReminder = id
        page = .reminders
    }

    /// The tab's count: reminders due now or overdue, not every one still to come. That is, ones whose time has come
    /// but that haven't gone off yet (the glasses away, say), and ones that went off within the hour and weren't ticked
    /// off (the hour Snooze is offered). Ones waiting out their Undo are left out in `body`.
    private func countDue() {
        let now = Date.now
        let store = LibraryStore.shared
        let late = store.upcomingReminders().filter { $0.due <= now }
        let rang = store.earlierReminders().filter { reminder in
            guard let fired = reminder.fired, reminder.completed == nil else { return false }
            return now.timeIntervalSince(fired) < RemindersPage.snoozeWindow
        }
        let ids = (late + rang).map(\.id)
        if ids != due { due = ids }
    }
}
