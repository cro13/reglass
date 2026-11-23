import SwiftData
import SwiftUI
import UIKit
import UserNotifications

/// The Reminders page of the home. "Coming up": every open reminder, soonest first, each counting down live (minutes
/// and seconds within the hour, the time and day beyond it) inside a ring that drains toward the moment it's due; tap
/// the ring to tick one off. Then a checklist for each category with things to do or buy (Shopping, To-do…): tap one
/// to tick it off and it drops into the list's dimmed "Got 3 · Clear" group. "Earlier": the reminders that went off or
/// were ticked off, most recent first. The home's bar below sets a new one, or adds to the list that's open, by typing.
///
/// The chips at the top (All · Shopping 4 · To-do 2 · …) narrow the page to one category: its checklist first, then
/// its reminders, so Shopping usually shows just the list. Reminders with no category show under All only.
///
/// Rows act like Mail's: swipe right to tick one off (Coming up, a list) or to be reminded again or snooze (Earlier),
/// swipe left to delete, press and hold for every choice, Copy and Move To ▸ too. A tap on a reminder opens it in
/// place: all of its title, the line ReGlass says, and compact pills for its choices. A new time is never picked here:
/// "Change Time", "Remind Me Again" and an item's "Remind Me" start the bar with the words ("Move “Check on the food”
/// to ") for the owner to finish in their own, and ReGlass's assistant reads the time. Deleting is Mail's way too
/// (`LibraryToast`): the row goes at once and the banner offers Undo (so does a shake) until the next action;
/// meanwhile the reminder doesn't go off.
///
/// Search opens the page on a reminder or list item it found (`reveal`): back to All if the open chip hides it, the
/// reminder opened in place, scrolled to the middle, and a copper ring that glows round it for a moment.
///
/// Delivery isn't done here: the reminder scheduler follows `LibraryStore.didChange` by itself. Notification permission
/// is asked in context, right after the first reminder is set from the bar (`ReminderComposer`), not on opening the
/// page; this page only reads where it stands and offers iPhone Settings if it was turned down.
struct RemindersPage: View {
    /// This page is the one on screen.
    let active: Bool
    /// The chip that's open (nil: All). The home's bar adds to it.
    @Binding var category: String?
    /// A reminder or list item to show, from Search. Taken (set back to nil) as it's shown.
    @Binding var reveal: UUID?
    /// The tab's stack, for Recently Deleted.
    @Binding var path: [AppRoute]
    @Query(filter: #Predicate<ReGlassReminder> { $0.deletedAt == nil }, sort: \ReGlassReminder.due)
    private var reminders: [ReGlassReminder]
    @Query(filter: #Predicate<ReGlassItem> { $0.deletedAt == nil }, sort: \ReGlassItem.created)
    private var items: [ReGlassItem]
    /// What waits in Recently Deleted, for the row at the end.
    @Query(filter: #Predicate<ReGlassReminder> { $0.deletedAt != nil }) private var deletedReminders: [ReGlassReminder]
    @Query(filter: #Predicate<ReGlassItem> { $0.deletedAt != nil }) private var deletedItems: [ReGlassItem]
    @ObservedObject private var toast = LibraryToast.shared
    @ObservedObject private var order = CategoryOrder.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var notifications: UNAuthorizationStatus?
    @State private var ticks = 0
    @State private var itemTicks = 0
    @State private var reopened = 0
    /// Rows being ticked off: the ring closes and the check lands before the row moves down to Earlier.
    @State private var ticking: Set<UUID> = []
    /// Items being ticked off: the circle fills before the row drops into its list's got group.
    @State private var tickingItems: Set<UUID> = []
    /// The row a tap opened. One at a time.
    @State private var expanded: UUID?
    /// The row Search showed: its ring glows for a moment.
    @State private var flashed: UUID?
    /// The row Search showed, kept on screen even past Earlier's or a list's got rows' limit.
    @State private var kept: UUID?

    /// How many of the reminders that went off or were ticked off are kept on screen.
    private static let earlierLimit = 30
    /// A reminder that went off this recently, and isn't ticked off, can be snoozed from its row. The Reminders tab
    /// counts it as due meanwhile.
    static let snoozeWindow: TimeInterval = 3600

    var body: some View {
        // A row deleted a moment ago stays out while its Undo shows.
        let shown = reminders.filter { !toast.hidden.contains($0.id) }
        let things = items.filter { !toast.hidden.contains($0.id) }
        let chips = CategoryChip.make(order: order.names,
                                      present: shown.map(\.category) + things.map { Optional($0.category) },
                                      counted: Self.comingUp(shown, in: nil).map(\.category)
                                          + things.filter(\.isOpen).map { Optional($0.category) })
        let chip = CategoryChip.valid(category, in: chips)
        let open = Self.comingUp(shown, in: chip)
        let earlier = Self.earlier(shown, in: chip, keeping: kept)
        let lists = ReminderChecklist.make(things, in: chip, order: order.names)
        let entrances = Self.entrances(chip: chip, anyReminders: !shown.isEmpty, open: open, lists: lists,
                                       earlier: earlier)
        ScrollViewReader { proxy in
            List {
                if CategoryChip.showsRow(chips, selection: chip,
                                         unfiled: shown.contains { CategoryChip.unfiled($0.category) }
                                             || things.contains { CategoryChip.unfiled($0.category) }) {
                    CategoryChips(chips: chips, selection: $category)
                        .entrance(1)
                        .transition(.libraryDissolve(reduceMotion: reduceMotion))
                        .chipRow(top: 6, bottom: 0)
                }
                if notifications == .denied {
                    NotificationsOffRow {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                    .transition(.libraryDissolve(reduceMotion: reduceMotion))
                    .libraryRow(top: 10, bottom: 4)
                }
                if shown.isEmpty && things.isEmpty {
                    LibraryEmptyState(symbol: "bell",
                                      title: "No reminders yet",
                                      message: "When one is due, ReGlass says it on your glasses, or alerts your iPhone when you're not wearing them.",
                                      phrase: "“Hey Meta, remind me in ten minutes…”",
                                      footer: "Or set one below.")
                        .libraryRow(top: 34, bottom: 20)
                } else if chip == nil {
                    // All: what's coming up, then the lists, then what went off.
                    if !shown.isEmpty {
                        comingUpSection(open, entrances: entrances, top: 14, proxy: proxy)
                    }
                    checklistSections(lists, entrances: entrances, first: shown.isEmpty, headed: true)
                    earlierSection(earlier, entrances: entrances, proxy: proxy)
                } else {
                    // One category: its list first (the chip already names it), then its reminders.
                    checklistSections(lists, entrances: entrances, first: true, headed: false)
                    if lists.isEmpty && open.isEmpty {
                        // Only ones that went off: say so, rather than opening on "Earlier".
                        NothingComingUp(category: chip)
                            .transition(.libraryDissolve(reduceMotion: reduceMotion))
                            .libraryRow(top: 16, bottom: 4)
                    }
                    if !open.isEmpty {
                        comingUpSection(open, entrances: entrances, top: lists.isEmpty ? 14 : 24, proxy: proxy)
                    }
                    earlierSection(earlier, entrances: entrances, proxy: proxy)
                }
                let waiting = (deletedReminders.map(\.id) + deletedItems.map(\.id)).filter { !toast.hidden.contains($0) }.count
                if waiting > 0 {
                    RecentlyDeletedRow(count: waiting) { path.append(.recentlyDeleted(.reminders)) }
                        .transition(.libraryDissolve(reduceMotion: reduceMotion))
                        .libraryRow(top: shown.isEmpty && things.isEmpty ? 4 : 18, bottom: 5)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .contentMargins(.bottom, 12, for: .scrollContent)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.4),
                       value: Self.motionKey(open: open, earlier: earlier, lists: lists))
            .animation(.easeOut(duration: 0.25), value: notifications)
            .onChange(of: reveal) { _, id in show(id, proxy: proxy) }
            .onAppear { show(reveal, proxy: proxy) }
        }
        .sensoryFeedback(.success, trigger: ticks)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.8), trigger: itemTicks)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: reopened)
        .sensoryFeedback(trigger: expanded) { _, now in now == nil ? nil : .selection }
        // The open chip's category has nothing left here (cleared, moved, deleted): back to All, and the bar with it.
        .onChange(of: chips.map(\.name)) { _, _ in
            if category != nil, chip == nil { withAnimation(reduceMotion ? nil : .snappy(duration: 0.38)) { category = nil } }
        }
        .onChange(of: category) { _, _ in
            if category != nil, CategoryChip.valid(category, in: chips) == nil { category = nil }
        }
        .task(id: active) {
            guard active else { return }
            await checkNotifications()
        }
        // Back from iPhone Settings, or from the permission alert: the row comes or goes with the answer.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, active else { return }
            Task { await checkNotifications() }
        }
    }

    // MARK: Sections

    /// "Coming up" and its rows; under All, "Nothing coming up" when none are.
    @ViewBuilder
    private func comingUpSection(_ open: [ReGlassReminder], entrances: [AnyHashable: Int], top: CGFloat,
                                 proxy: ScrollViewProxy) -> some View {
        LibrarySectionHeader(title: "Coming up", count: open.isEmpty ? nil : open.count)
            .modifier(OptionalEntranceIndex(index: entrances[Self.comingUpKey]))
            .libraryRow(top: top, bottom: 6)
        if open.isEmpty {
            NothingComingUp()
                .transition(.libraryDissolve(reduceMotion: reduceMotion))
                .libraryRow(top: 4, bottom: 6)
        }
        ForEach(open) { reminder in
            let item = reminder.snapshot
            UpcomingRow(reminder: reminder,
                        ticked: ticking.contains(item.id),
                        expanded: expanded == item.id,
                        toggle: { toggle(item.id, proxy: proxy) },
                        tick: { tickOff(item) },
                        changeTime: { changeTime(item) },
                        copy: { copy(item) })
                .searchFlash(flashed == item.id)
                .id(item.id)
                .swipeActions(edge: .leading, allowsFullSwipe: true) { doneButton(item) }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) { deleteButton(item) }
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contextMenu { upcomingMenu(item) }
                .modifier(OptionalEntranceIndex(index: entrances[item.id]))
                .libraryRow(top: 5, bottom: 5)
        }
    }

    /// A checklist per category: its name with the open count (`headed`; not under its own chip, which names it
    /// already), the open rows, then the dimmed got group.
    @ViewBuilder
    private func checklistSections(_ lists: [ReminderChecklist], entrances: [AnyHashable: Int], first: Bool,
                                   headed: Bool) -> some View {
        ForEach(lists) { list in
            if headed {
                LibrarySectionHeader(title: list.name, count: list.open.isEmpty ? nil : list.open.count,
                                     category: list.name)
                    .modifier(OptionalEntranceIndex(index: entrances[Self.listKey(list.name)]))
                    .libraryRow(top: first && list.id == lists.first?.id ? 14 : 24, bottom: 6)
            }
            if list.open.isEmpty {
                ChecklistDoneLine(category: list.name)
                    .transition(.libraryDissolve(reduceMotion: reduceMotion))
                    .libraryRow(top: headed ? 2 : 14, bottom: 4)
            }
            ForEach(list.open) { thing in
                let item = thing.snapshot
                ChecklistItemRow(item: thing, ticked: tickingItems.contains(item.id)) { tickItem(item.id) }
                    .searchFlash(flashed == item.id)
                    .id(item.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        Button { tickItem(item.id) } label: { Label("Done", systemImage: "checkmark") }
                            .tint(Theme.Swipe.done)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) { deleteItemButton(item) }
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu { itemMenu(item) }
                    .modifier(OptionalEntranceIndex(index: entrances[item.id]))
                    .libraryRow(top: !headed && thing.id == list.open.first?.id ? 12 : 3, bottom: 3)
            }
            if !list.got.isEmpty {
                ChecklistGotHeader(count: list.got.count) { clear(list) }
                    .transition(.libraryDissolve(reduceMotion: reduceMotion))
                    .libraryRow(top: list.open.isEmpty ? 2 : 6, bottom: 0)
                ForEach(gotRows(list)) { thing in
                    let item = thing.snapshot
                    ChecklistGotRow(item: thing) { bringBack(item.id) }
                        .searchFlash(flashed == item.id)
                        .id(item.id)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { bringBack(item.id) } label: { Label("Not Done", systemImage: "arrow.uturn.backward") }
                                .tint(Theme.Swipe.undo)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) { deleteItemButton(item) }
                        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .contextMenu { gotMenu(item) }
                        .libraryRow(top: 0, bottom: 0)
                }
            }
        }
    }

    /// "Earlier" and its rows, when there are any.
    @ViewBuilder
    private func earlierSection(_ earlier: [ReGlassReminder], entrances: [AnyHashable: Int],
                                proxy: ScrollViewProxy) -> some View {
        if !earlier.isEmpty {
            LibrarySectionHeader(title: "Earlier")
                .modifier(OptionalEntranceIndex(index: entrances[Self.earlierKey]))
                .libraryRow(top: 24, bottom: 6)
            ForEach(earlier) { reminder in
                let item = reminder.snapshot
                let snoozable = Self.canSnooze(item)
                EarlierRow(reminder: reminder,
                           expanded: expanded == item.id,
                           canReopen: Self.canReopen(item),
                           canSnooze: snoozable,
                           toggle: { toggle(item.id, proxy: proxy) },
                           remindAgain: { remindAgain(item) },
                           snooze: { snooze(item) },
                           reopen: { reopen(item) },
                           copy: { copy(item) })
                    .searchFlash(flashed == item.id)
                    .id(item.id)
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if snoozable { snoozeButton(item) }
                        remindAgainButton(item)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) { deleteButton(item) }
                    .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .contextMenu { earlierMenu(item) }
                    .libraryRow(top: 4, bottom: 4)
            }
        }
    }

    // MARK: What shows

    /// Coming up: the reminders still to come, under `chip` (every one under All), soonest first as queried. The one
    /// place that decides what counts as coming up: the page, the chips' counts and the sections all ask here.
    static func comingUp(_ reminders: [ReGlassReminder], in chip: String?) -> [ReGlassReminder] {
        reminders.filter { reminder in
            reminder.isOpen
                && CategoryChip.files(reminder.category, under: chip)
        }
    }

    /// Went off or ticked off, under `chip`, most recent first: the latest `earlierLimit`, and `keeping` (the one
    /// Search showed) wherever it is.
    private static func earlier(_ reminders: [ReGlassReminder], in chip: String?, keeping: UUID?) -> [ReGlassReminder] {
        let done = reminders.filter { !$0.isOpen && CategoryChip.files($0.category, under: chip) }
        let sorted = done.sorted { ($0.fired ?? $0.completed ?? $0.due) > ($1.fired ?? $1.completed ?? $1.due) }
        var shown = Array(sorted.prefix(earlierLimit))
        if let keeping, !shown.contains(where: { $0.id == keeping }),
           let kept = sorted.first(where: { $0.id == keeping }) {
            shown.append(kept)
        }
        return shown
    }

    /// A list's got rows on screen: the latest `ReminderChecklist.gotShown`, and the one Search showed.
    private func gotRows(_ list: ReminderChecklist) -> [ReGlassItem] {
        var rows = Array(list.got.prefix(ReminderChecklist.gotShown))
        if let kept, !rows.contains(where: { $0.id == kept }), let item = list.got.first(where: { $0.id == kept }) {
            rows.append(item)
        }
        return rows
    }

    /// Ticked off before it went off, and its time is still ahead: "Not Done" opens it again.
    private static func canReopen(_ item: ReminderSnapshot) -> Bool {
        item.fired == nil && item.completed != nil && item.due.timeIntervalSinceNow > 5
    }

    /// Went off within the hour and isn't ticked off: Snooze moves it `LibraryStore.snoozeMinutes` on.
    private static func canSnooze(_ item: ReminderSnapshot) -> Bool {
        guard let fired = item.fired, item.completed == nil else { return false }
        return Date.now.timeIntervalSince(fired) < snoozeWindow
    }

    private static let comingUpKey = "coming-up"
    /// What the rows' motion follows: every row's id tagged by its section, so a row moving between neighbouring
    /// sections (the last open item into Got) still changes the value and animates.
    private static func motionKey(open: [ReGlassReminder], earlier: [ReGlassReminder],
                                  lists: [ReminderChecklist]) -> [String] {
        var key: [String] = open.map { "c" + $0.id.uuidString }
        for list in lists {
            key += list.open.map { "o" + $0.id.uuidString }
            key += list.got.map { "g" + $0.id.uuidString }
        }
        key += earlier.map { "e" + $0.id.uuidString }
        return key
    }

    private static let earlierKey = "earlier"
    private static func listKey(_ name: String) -> String { "list-" + name }

    /// The entrance order of what's on screen when the page opens, top to bottom: the first few headers and rows rise
    /// in one after another; the rest just appear.
    private static func entrances(chip: String?, anyReminders: Bool, open: [ReGlassReminder], lists: [ReminderChecklist],
                                  earlier: [ReGlassReminder]) -> [AnyHashable: Int] {
        var keys: [AnyHashable] = []
        func addComingUp() {
            keys.append(comingUpKey)
            keys += open.prefix(6).map { AnyHashable($0.id) }
        }
        if chip == nil, anyReminders { addComingUp() }
        for list in lists {
            keys.append(listKey(list.name))
            keys += list.open.prefix(6).map { AnyHashable($0.id) }
        }
        if chip != nil, !open.isEmpty { addComingUp() }
        if !earlier.isEmpty { keys.append(earlierKey) }
        return Dictionary(keys.prefix(9).enumerated().map { ($1, $0 + 2) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Actions

    private var openingAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.42, dampingFraction: 0.84)
    }

    /// Opens a row (closing any other), or closes it. A row low on the screen then scrolls up, so its pills clear
    /// the bar.
    private func toggle(_ id: UUID, proxy: ScrollViewProxy) {
        let opening = expanded != id
        withAnimation(openingAnimation) { expanded = opening ? id : nil }
        guard opening else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 220 : 380))
            guard expanded == id else { return }
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) { proxy.scrollTo(id) }
        }
    }

    /// Search found this reminder or list item: show it. Back to All when the open chip hides it, the reminder opened
    /// in place, then (once the page is on screen) scrolled to the middle with its ring glowing for a moment.
    private func show(_ id: UUID?, proxy: ScrollViewProxy) {
        guard let id else { return }
        reveal = nil
        let reminder = reminders.first { $0.id == id }
        let item = reminder == nil ? items.first { $0.id == id } : nil
        guard reminder != nil || item != nil else { return }
        let filed = reminder?.category ?? item?.category
        if category != nil, !CategoryChip.files(filed, under: category) { category = nil }
        kept = id
        withAnimation(openingAnimation) { expanded = reminder?.id }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 250 : 450))
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { proxy.scrollTo(id, anchor: .center) }
            withAnimation(.easeOut(duration: 0.3)) { flashed = id }
            try? await Task.sleep(for: .seconds(1.8))
            if flashed == id { withAnimation(.easeOut(duration: 0.7)) { flashed = nil } }
        }
    }

    private func collapse() {
        guard expanded != nil else { return }
        withAnimation(openingAnimation) { expanded = nil }
    }

    /// The ring's tick, wherever it's asked for (the ring, a swipe, the menu, the Done pill, VoiceOver).
    private func tickOff(_ item: ReminderSnapshot) {
        let id = item.id
        guard !ticking.contains(id) else { return }
        if expanded == id { collapse() }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.38, dampingFraction: 0.6)) {
            _ = ticking.insert(id)
        }
        ticks += 1
        // Long enough to see the ring close and the check land before the row moves down to Earlier.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 250 : 550))
            // Deleted meanwhile: leave it as it was, so Undo brings it back still to come.
            if !LibraryToast.shared.hidden.contains(id) { LibraryStore.shared.completeReminder(id) }
            ticking.remove(id)
        }
    }

    /// Off the list at once; deleted for real once the banner's Undo has gone.
    private func delete(_ item: ReminderSnapshot) {
        let id = item.id
        if expanded == id { expanded = nil }
        LibraryToast.shared.delete(id, text: "Reminder deleted") { LibraryStore.shared.deleteReminder(id) }
    }

    /// The title, and for one still to come its day and time ("Check on the food · Wed 28 Oct, 18:00").
    private func copy(_ item: ReminderSnapshot) {
        let title = ReminderSpeech.displayTitle(item.title)
        let when = item.due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        UIPasteboard.general.string = item.isOpen ? "\(title) · \(when)" : title
        LibraryToast.shared.show("Copied", symbol: "doc.on.doc")
    }

    private func changeTime(_ item: ReminderSnapshot) {
        collapse()
        ReminderBar.start("Move \u{201C}\(ReminderBar.short(ReminderSpeech.displayTitle(item.title)))\u{201D} to ")
    }

    private func remindAgain(_ item: ReminderSnapshot) {
        collapse()
        ReminderBar.start("Remind me again about \u{201C}\(ReminderBar.short(ReminderSpeech.displayTitle(item.title)))\u{201D} ")
    }

    /// Rings again in ten minutes; it moves up to Coming up, counting down.
    private func snooze(_ item: ReminderSnapshot) {
        collapse()
        guard let moved = LibraryStore.shared.snoozeReminder(item.id) else { return }
        LibraryToast.shared.show("Snoozed till \(moved.due.formatted(date: .omitted, time: .shortened))",
                                 symbol: "moon.zzz")
    }

    private func reopen(_ item: ReminderSnapshot) {
        collapse()
        if LibraryStore.shared.reopenReminder(item.id) != nil {
            reopened += 1
        } else {
            LibraryToast.shared.show("Its time has passed", symbol: "clock")
        }
    }

    private func moveReminder(_ item: ReminderSnapshot, to category: String?) {
        LibraryStore.shared.moveReminder(item.id, to: category)
        LibraryToast.shared.moved(to: category, from: item.category.map(order.name(for:)))
    }

    // MARK: Item actions

    /// The circle's tick, wherever it's asked for (the row, a swipe, the menu, VoiceOver).
    private func tickItem(_ id: UUID) {
        guard !tickingItems.contains(id) else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.58)) {
            _ = tickingItems.insert(id)
        }
        itemTicks += 1
        // Long enough to see the circle fill and the words strike through before the row drops into Got.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 250 : 520))
            if !LibraryToast.shared.hidden.contains(id) { LibraryStore.shared.completeItems([id]) }
            tickingItems.remove(id)
        }
    }

    /// Back on the list, where it was.
    private func bringBack(_ id: UUID) {
        guard !LibraryStore.shared.reopenItems([id]).isEmpty else { return }
        reopened += 1
    }

    /// The got ones go at once; the banner offers Undo for all of them.
    private func clear(_ list: ReminderChecklist) {
        let ids = list.got.map(\.id)
        LibraryToast.shared.delete(ids, text: "Cleared \(ids.count) from \(list.name)") {
            LibraryStore.shared.deleteItems(ids)
        }
    }

    private func deleteItem(_ item: ItemSnapshot) {
        let id = item.id
        LibraryToast.shared.delete(id, text: "Deleted from \(order.name(for: item.category))") {
            LibraryStore.shared.deleteItem(id)
        }
    }

    private func copyItem(_ item: ItemSnapshot) {
        UIPasteboard.general.string = item.title
        LibraryToast.shared.show("Copied", symbol: "doc.on.doc")
    }

    /// The bar, started on the item and with its category's chip open, so the reminder lands under it.
    private func remindItem(_ item: ItemSnapshot) {
        ReminderBar.start("Remind me about \u{201C}\(ReminderBar.short(item.title))\u{201D} ",
                          category: order.name(for: item.category))
    }

    private func moveItem(_ item: ItemSnapshot, to category: String?) {
        guard let category else { return }
        LibraryStore.shared.moveItem(item.id, to: category, topic: item.topic)
        LibraryToast.shared.moved(to: category, from: order.name(for: item.category))
    }

    // MARK: Swipes and menus

    // Each in its `Theme.Swipe` colour: Done green, Remind Me Again orange, Snooze indigo, Delete red. VoiceOver offers
    // the swipes as the row's actions.

    private func doneButton(_ item: ReminderSnapshot) -> some View {
        Button { tickOff(item) } label: { Label("Done", systemImage: "checkmark") }
            .tint(Theme.Swipe.done)
    }

    private func remindAgainButton(_ item: ReminderSnapshot) -> some View {
        Button { remindAgain(item) } label: { Label("Remind Me Again", systemImage: "bell") }
            .tint(Theme.Swipe.remind)
    }

    private func snoozeButton(_ item: ReminderSnapshot) -> some View {
        Button { snooze(item) } label: { Label("Snooze", systemImage: "moon.zzz") }
            .tint(Theme.Swipe.snooze)
    }

    private func deleteButton(_ item: ReminderSnapshot) -> some View {
        Button(role: .destructive) { delete(item) } label: { Label("Delete", systemImage: "trash") }
            .tint(Theme.Swipe.delete)
    }

    private func deleteItemButton(_ item: ItemSnapshot) -> some View {
        Button(role: .destructive) { deleteItem(item) } label: { Label("Delete", systemImage: "trash") }
            .tint(Theme.Swipe.delete)
    }

    @ViewBuilder
    private func upcomingMenu(_ item: ReminderSnapshot) -> some View {
        Button { tickOff(item) } label: { Label("Done", systemImage: "checkmark.circle") }
        Button { changeTime(item) } label: { Label("Change Time\u{2026}", systemImage: "clock.arrow.circlepath") }
        Button { copy(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
        MoveToMenu(current: item.category, allowsNone: true) { moveReminder(item, to: $0) }
        Divider()
        Button(role: .destructive) { delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder
    private func earlierMenu(_ item: ReminderSnapshot) -> some View {
        if Self.canSnooze(item) {
            Button { snooze(item) } label: { Label("Snooze \(LibraryStore.snoozeMinutes) Min", systemImage: "moon.zzz") }
        }
        Button { remindAgain(item) } label: { Label("Remind Me Again\u{2026}", systemImage: "bell") }
        if Self.canReopen(item) {
            Button { reopen(item) } label: { Label("Not Done", systemImage: "arrow.uturn.backward") }
        }
        Button { copy(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
        MoveToMenu(current: item.category, allowsNone: true) { moveReminder(item, to: $0) }
        Divider()
        Button(role: .destructive) { delete(item) } label: { Label("Delete", systemImage: "trash") }
    }

    /// Done · Copy · Move To ▸ · Remind Me · Delete.
    @ViewBuilder
    private func itemMenu(_ item: ItemSnapshot) -> some View {
        Button { tickItem(item.id) } label: { Label("Done", systemImage: "checkmark.circle") }
        Button { copyItem(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
        MoveToMenu(current: item.category) { moveItem(item, to: $0) }
        Button { remindItem(item) } label: { Label("Remind Me\u{2026}", systemImage: "bell") }
        Divider()
        Button(role: .destructive) { deleteItem(item) } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder
    private func gotMenu(_ item: ItemSnapshot) -> some View {
        Button { bringBack(item.id) } label: { Label("Not Done", systemImage: "arrow.uturn.backward") }
        Button { copyItem(item) } label: { Label("Copy", systemImage: "doc.on.doc") }
        MoveToMenu(current: item.category) { moveItem(item, to: $0) }
        Divider()
        Button(role: .destructive) { deleteItem(item) } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Permission

    /// Reads where notification permission stands. Never asks: that waits for the first reminder (`ReminderComposer`).
    private func checkNotifications() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

// MARK: Rows

/// One reminder to come: the ring (tap it to tick off), what it's for, how it was set, and the live countdown. A tap
/// elsewhere opens it: all of its title, the line ReGlass will say, and Change Time · Done.
private struct UpcomingRow: View {
    let reminder: ReGlassReminder
    let ticked: Bool
    let expanded: Bool
    let toggle: () -> Void
    let tick: () -> Void
    let changeTime: () -> Void
    let copy: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// As `ReminderRing`'s, so the opened part lines up under the title.
    @ScaledMetric(relativeTo: .body) private var ringSize: CGFloat = 30
    /// A finger is on the row (not its ring): the card sinks, as a note's does.
    @State private var pressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = reminder.due.timeIntervalSince(context.date)
                // Accessibility sizes: the countdown goes under the title, as a note's time does, so the title keeps
                // the row's width instead of squeezing beside a large fixed-size clock.
                let stacked = typeSize.isAccessibilitySize
                HStack(alignment: stacked ? .top : .center, spacing: 10) {
                    ReminderRing(left: left, total: reminder.due.timeIntervalSince(reminder.created),
                                 ticked: ticked, action: tick)
                    // Everything but the ring opens the row; the ring is a button of its own.
                    Button(action: toggle) {
                        HStack(alignment: stacked ? .top : .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ReminderSpeech.displayTitle(reminder.title))
                                    .font(.headline)
                                    .foregroundStyle(Theme.ink.opacity(ticked ? 0.6 : 1))
                                    .strikethrough(ticked, color: Theme.textTertiary)
                                    .lineLimit(expanded ? nil : (typeSize.isAccessibilitySize ? 4 : 2))
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 6) {
                                    Image(systemName: reminder.source.markSymbol)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                    Text(subtitle(left: left))
                                        .font(.caption)
                                        .monospacedDigit()
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                if stacked {
                                    Countdown(due: reminder.due, left: left, stacked: true)
                                        .padding(.top, 2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if !stacked {
                                Countdown(due: reminder.due, left: left)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressReportingStyle(pressed: $pressed))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(reminder.title), \(spokenWhen(left: left))")
                .accessibilityHint(expanded ? "Hides its choices" : "Shows all of it, and its choices")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { toggle() }
                .accessibilityAction(named: "Change Time") { changeTime() }
                .accessibilityAction(named: "Copy") { copy() }
            }
            if expanded {
                ReminderDetails(announcement: reminder.announcement, facts: facts,
                                indent: max(44, ringSize + 12) + 10) {
                    Button(action: changeTime) {
                        Label("Change Time", systemImage: "clock.arrow.circlepath")
                    }
                    .buttonStyle(CompactPillStyle())
                    Button(action: tick) {
                        Label {
                            Text("Done")
                        } icon: {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(CompactPillStyle())
                }
                .transition(.libraryDissolve(reduceMotion: reduceMotion))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: toggle)
        .contentSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .modifier(CardSink(pressed: pressed))
    }

    /// Within the hour the countdown says how long; this says when. Beyond it, the other way round.
    private func subtitle(left: TimeInterval) -> String {
        if left <= 0 { return "Due now" }
        if left < 3600 { return "at \(reminder.due.formatted(date: .omitted, time: .shortened))" }
        return libraryTimeUntil(left)
    }

    private func spokenWhen(left: TimeInterval) -> String {
        if left <= 0 { return "due now" }
        return "\(libraryTimeUntil(left)), \(reminder.due.libraryDayTime). \(reminder.source.madeHow)"
    }

    /// "Wed 28 Oct, 18:00 · Said to your glasses"
    private var facts: String {
        let when = reminder.due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        return "\(when) · \(reminder.source.madeHow)"
    }
}

/// The ring around the tick: a copper arc for the time still to go, draining toward the due moment, on a faint track.
/// Tapped, it closes into a filled copper disc with a check that springs in, and one copper ring spreads from it and
/// fades, as a list item's circle does.
private struct ReminderRing: View {
    let left: TimeInterval
    let total: TimeInterval
    let ticked: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 30

    /// The share of the time still to go, from 1 when it was set to 0 when it's due.
    private var share: Double {
        guard total > 1 else { return left > 0 ? 1 : 0 }
        return min(1, max(0, left / total))
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Theme.track, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: ticked ? 1 : share)
                    .stroke(Theme.accentGradient, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Each second's step glides into the next, so the arc drains smoothly.
                    .animation(reduceMotion || ticked ? nil : .linear(duration: 1), value: share)
                // The disc and check grow in; under Reduce Motion they only fade.
                Circle()
                    .fill(Theme.accentFill)
                    .padding(3)
                    .scaleEffect(ticked || reduceMotion ? 1 : 0.3)
                    .opacity(ticked ? 1 : 0)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .scaleEffect(ticked || reduceMotion ? 1 : 0.4)
                    .opacity(ticked ? 1 : 0)
            }
            .padding(1.25)
            .frame(width: size, height: size)
            .modifier(TickBurst(checked: ticked))
            .frame(width: max(44, size + 12), height: max(44, size + 12))
            .contentShape(Circle())
        }
        .buttonStyle(SoftPressStyle())
        .disabled(ticked)
        .accessibilityLabel("Tick Off")
    }
}

/// The live part of a row: "04:59" counting down within the hour (rolling digits), else the time with its day
/// under it ("18:00", "Today"). "Now" once it's due and ReGlass is delivering it. Beside the title it's right-aligned at
/// its own size; `stacked` (under the title, at accessibility sizes) it's left-aligned.
private struct Countdown: View {
    let due: Date
    let left: TimeInterval
    var stacked = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: stacked ? .leading : .trailing, spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(soon ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.ink))
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: value)
            Text(caption)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)
    }

    /// The last minute, in copper light.
    private var soon: Bool { left < 60 }

    private var value: String {
        guard left > 0 else { return "Now" }
        guard left < 3600 else { return due.formatted(date: .omitted, time: .shortened) }
        let seconds = Int(left.rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var caption: String {
        if left <= 0 { return "due" }
        if left < 3600 { return "left" }
        return due.libraryDay
    }
}

/// One that went off or was ticked off, quieter: a bell (went off) or a green check (ticked off), what it was for,
/// and when. A tap opens it: all of its title, the line ReGlass says, and Remind Me Again (· Snooze 10 Min, for one that
/// went off within the hour; · Not Done, for one ticked off whose time is still ahead).
private struct EarlierRow: View {
    let reminder: ReGlassReminder
    let expanded: Bool
    let canReopen: Bool
    let canSnooze: Bool
    let toggle: () -> Void
    let remindAgain: () -> Void
    let snooze: () -> Void
    let reopen: () -> Void
    let copy: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    /// A finger is on the row: the card sinks, as a note's does.
    @State private var pressed = false

    /// Ticked off before it went off.
    private var tickedOff: Bool { reminder.fired == nil && reminder.completed != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Image(systemName: tickedOff ? "checkmark.circle.fill" : "bell.fill")
                        .font(.body)
                        .foregroundStyle(tickedOff ? AnyShapeStyle(Theme.good) : AnyShapeStyle(Theme.accent))
                        .opacity(tickedOff ? 1 : 0.8)
                        .frame(width: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ReminderSpeech.displayTitle(reminder.title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink.opacity(0.78))
                            .strikethrough(tickedOff, color: Theme.textTertiary)
                            .lineLimit(expanded ? nil : (typeSize.isAccessibilitySize ? 4 : 2))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(when)
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressReportingStyle(pressed: $pressed))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(reminder.title), \(when)")
            .accessibilityHint(expanded ? "Hides its choices" : "Shows all of it, and its choices")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
            .accessibilityActions {
                if canSnooze { Button("Snooze \(LibraryStore.snoozeMinutes) Minutes", action: snooze) }
                if canReopen { Button("Not Done", action: reopen) }
                Button("Copy", action: copy)
            }
            if expanded {
                ReminderDetails(announcement: reminder.announcement, facts: facts, indent: 54) {
                    if canSnooze {
                        Button(action: snooze) {
                            Label {
                                Text("Snooze \(LibraryStore.snoozeMinutes) Min")
                            } icon: {
                                Image(systemName: "moon.zzz").foregroundStyle(Theme.accent)
                            }
                        }
                        .buttonStyle(CompactPillStyle())
                    }
                    Button(action: remindAgain) {
                        Label {
                            Text("Remind Me Again")
                        } icon: {
                            Image(systemName: "bell").foregroundStyle(Theme.accent)
                        }
                    }
                    .buttonStyle(CompactPillStyle())
                    if canReopen {
                        Button(action: reopen) {
                            Label("Not Done", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(CompactPillStyle())
                    }
                }
                .transition(.libraryDissolve(reduceMotion: reduceMotion))
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .padding(.vertical, 9)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture(perform: toggle)
        .contentSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .modifier(CardSink(pressed: pressed))
    }

    private var when: String {
        if let fired = reminder.fired {
            return "Went off \(fired.libraryDayTime)" + (reminder.completed != nil ? " · ticked off" : "")
        }
        if let completed = reminder.completed {
            return "Ticked off \(completed.libraryDayTime)"
        }
        return reminder.due.libraryDayTime
    }

    /// How it was made, and for one ticked off early when it was due ("Was due Tomorrow 09:00 · Said to your glasses").
    private var facts: String {
        tickedOff ? "Was due \(reminder.due.libraryDayTime) · \(reminder.source.madeHow)" : reminder.source.madeHow
    }
}

/// What a tapped row opens to, under its title: the line ReGlass says when it's due, a line of facts, and the row's
/// choices as compact pills that hug their labels (stacked when large text leaves no room side by side).
private struct ReminderDetails<Pills: View>: View {
    let announcement: String?
    let facts: String
    /// Lines it up under the row's title.
    let indent: CGFloat
    @ViewBuilder let pills: Pills

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let announcement {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "waveform")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text("\u{201C}\(announcement)\u{201D}")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("ReGlass says: \(announcement)")
            }
            Text(facts)
                .font(.caption)
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { pills }
                VStack(alignment: .leading, spacing: 8) { pills }
            }
        }
        .padding(.leading, indent)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Every reminder has gone off or been ticked off (in `category`, under its chip).
private struct NothingComingUp: View {
    var category: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.body)
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(category.map { "Nothing coming up in \($0). Add one below." }
                 ?? "Nothing coming up. Say “Hey Meta, remind me…”, or set one below.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Notifications were turned down: one small warning row, with the way to iPhone Settings.
private struct NotificationsOffRow: View {
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "bell.slash.fill")
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text("iPhone alerts are off, so reminders can only play on your glasses.")
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Settings", action: openSettings)
                .buttonStyle(CompactPillStyle())
                .accessibilityHint("Opens ReGlass's notification settings")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.warning.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.warning.opacity(0.3), lineWidth: 1))
    }
}
