import SwiftData
import SwiftUI
import UIKit

/// The Chats page of the home (`LibraryHome`): the glasses, small, at the top (or the card that sets them up, while
/// there are none), then every conversation had through them, newest first and grouped by day. A list (not a
/// scroll stack) so a conversation has Mail's row actions: swipe right to copy it or be reminded about it, swipe left
/// to delete it (with Undo), or press and hold for all three. A deleted chat waits in Recently Deleted for 30 days,
/// behind a row at the end of the list while there's something in it. The home draws the backdrop, the wordmark and
/// switcher above, and the bar for typing to ReGlass below.
struct ChatsView: View {
    @Binding var path: [AppRoute]
    @EnvironmentObject private var glasses: GlassesController
    @ObservedObject private var toast = LibraryToast.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(filter: #Predicate<Conversation> { $0.deletedAt == nil }, sort: \Conversation.updatedAt, order: .reverse)
    private var conversations: [Conversation]
    /// What waits in Recently Deleted, for the row at the end.
    @Query(filter: #Predicate<Conversation> { $0.deletedAt != nil }) private var deleted: [Conversation]

    var body: some View {
        // A conversation just deleted leaves at once; Undo brings it back.
        let shown = conversations.filter { !toast.hidden.contains($0.id) }
        List {
            if let paired = glasses.paired {
                Button { path.append(.glasses) } label: {
                    GlassesCard(paired: paired, live: glasses.live)
                }
                .buttonStyle(CardPressStyle())
                .entrance(2)
                .chatListRow(top: 10, bottom: 6)
                if glasses.showsFirmwareBanner, let offer = glasses.firmwareOffer {
                    FirmwareUpdateBanner(update: offer,
                                         open: { path.append(.firmware) },
                                         later: { withAnimation(Theme.Motion.inline) { glasses.hideFirmwareBanner() } })
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .chatListRow(top: 6, bottom: 6)
                }
            } else {
                // Setup put off (Not Now) or the glasses forgotten: the way to set them up, in their place.
                ConnectGlassesCard()
                    .entrance(2)
                    .chatListRow(top: 10, bottom: 6)
            }
            if shown.isEmpty {
                EmptyChats()
                    .entrance(firstEntrance)
                    .chatListRow(top: 40, bottom: 20)
            } else {
                ForEach(Self.days(shown)) { day in
                    DayHeader(title: day.day.chatDay)
                        .chatListRow(top: 20, bottom: 6)
                    ForEach(day.conversations) { conversation in
                        Button { path.append(.conversation(conversation.id)) } label: {
                            ConversationRow(conversation: conversation)
                        }
                        .buttonStyle(CardPressStyle())
                        .cardRowActions(copy: { copy(conversation) },
                                        remind: { remind(conversation) },
                                        delete: { delete(conversation) })
                        .modifier(FirstRowsEntrance(index: entranceIndex(conversation)))
                        .chatListRow(top: 5, bottom: 5)
                    }
                }
            }
            let waiting = deleted.filter { !toast.hidden.contains($0.id) }.count
            if waiting > 0 {
                RecentlyDeletedRow(count: waiting) { path.append(.recentlyDeleted(.chats)) }
                    .transition(.opacity)
                    .chatListRow(top: 14, bottom: 5)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .contentMargins(.bottom, 12, for: .scrollContent)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy(duration: 0.35), value: shown.map(\.id))
        .refreshable {
            glasses.refresh()
        }
    }

    // MARK: Row actions

    /// The whole conversation on the pasteboard, as plain text.
    private func copy(_ conversation: Conversation) {
        UIPasteboard.general.string = Self.plainText(conversation)
        LibraryToast.shared.show("Copied", symbol: "doc.on.doc")
    }

    /// Reminders, with the bar started on the conversation's title, for the owner to say when.
    private func remind(_ conversation: Conversation) {
        let title = Self.title(of: conversation, conversation.orderedEntries)
        ReminderBar.start("Remind me about \u{201C}\(ReminderBar.short(title))\u{201D} ")
    }

    /// Gone from the list now, deleted for real once the banner's Undo has passed. Looked up again by then, as it may
    /// already be gone (Settings' Delete all).
    private func delete(_ conversation: Conversation) {
        let id = conversation.id
        LibraryToast.shared.delete(id, text: "Chat deleted") {
            guard let conversation = ChatHistory.shared.conversation(id) else { return }
            ChatHistory.shared.delete(conversation)
        }
    }

    // MARK: Reading a conversation

    /// What a row calls the conversation: its title, else the first thing ReGlass did.
    static func title(of conversation: Conversation, _ entries: [ChatEntry]) -> String {
        if !conversation.title.isEmpty { return conversation.title }
        return entries.first { $0.kind == .action }?.text ?? "Conversation"
    }

    /// The conversation as plain text, oldest first: "You: …", "ReGlass: …", "Them: …" for the other person in an
    /// interpreted conversation, and "• …" for what ReGlass did (with how it ended, when it didn't simply finish).
    static func plainText(_ conversation: Conversation) -> String {
        var lines: [String] = []
        for entry in conversation.orderedEntries {
            switch entry.kind {
            case .user: lines.append("You: " + entry.text)
            case .reply: lines.append("ReGlass: " + entry.text)
            case .other: lines.append("Them: " + entry.text)
            case .action: lines.append("• " + entry.text + (entry.status == .done ? "" : " (\(entry.status.label))"))
            }
        }
        return lines.isEmpty ? title(of: conversation, []) : lines.joined(separator: "\n")
    }

    // MARK: Grouping

    /// Consecutive conversations on the same calendar day (by their last activity, as they're sorted).
    private static func days(_ conversations: [Conversation]) -> [ChatDay] {
        let calendar = Calendar.current
        var groups: [ChatDay] = []
        for conversation in conversations {
            let day = calendar.startOfDay(for: conversation.updatedAt)
            if groups.last?.day == day {
                groups[groups.count - 1].conversations.append(conversation)
            } else {
                groups.append(ChatDay(day: day, conversations: [conversation]))
            }
        }
        return groups
    }

    /// The first rows arrive one after another, after the home's header, the switcher and the glasses card. Nil for
    /// the rest. Counted over every conversation, deleted-but-undoable ones too, so a delete doesn't
    /// replay a row's entrance as it moves up.
    private func entranceIndex(_ conversation: Conversation) -> Int? {
        conversations.prefix(6).firstIndex(of: conversation).map { $0 + firstEntrance }
    }

    /// The entrance beat of whatever comes after the cards at the top.
    private var firstEntrance: Int { 3 }
}

private struct ChatDay: Identifiable {
    let day: Date
    var conversations: [Conversation]
    var id: Date { day }
}

// MARK: Rows

/// One conversation: what it was about, when, the start of the last reply, and small copper glyphs for what ReGlass did.
private struct ConversationRow: View {
    let conversation: Conversation
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let entries = conversation.orderedEntries
        let stacked = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 6) {
            if stacked {
                titleText(entries).lineLimit(3)
                timeText
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    titleText(entries).lineLimit(1)
                    Spacer(minLength: 0)
                    timeText
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Text(snippet(entries))
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(stacked ? 2 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ActionGlyphs(kinds: actionKinds(entries))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(entries))
        .accessibilityAddTraits(.isButton)
    }

    private func titleText(_ entries: [ChatEntry]) -> some View {
        Text(ChatsView.title(of: conversation, entries))
            .font(.headline)
            .foregroundStyle(Theme.ink)
    }

    private var timeText: some View {
        Text(conversation.updatedAt.formatted(date: .omitted, time: .shortened))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(Theme.textTertiary)
    }

    /// The last thing the glasses said, else the last thing ReGlass did.
    private func snippet(_ entries: [ChatEntry]) -> String {
        if let reply = entries.last(where: { $0.kind == .reply }) { return Self.oneLine(reply.text) }
        if let action = entries.last(where: { $0.kind == .action }) { return action.text }
        return conversation.endedAt == nil ? "In progress" : "No reply"
    }

    private func actionKinds(_ entries: [ChatEntry]) -> [ChatActionKind] {
        var kinds: [ChatActionKind] = []
        for entry in entries where entry.kind == .action && !kinds.contains(entry.actionKind) {
            kinds.append(entry.actionKind)
        }
        return kinds
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    private func accessibilityText(_ entries: [ChatEntry]) -> String {
        var parts = [ChatsView.title(of: conversation, entries), snippet(entries)]
        let kinds = actionKinds(entries)
        if !kinds.isEmpty { parts.append("Actions: " + kinds.map(\.spokenName).joined(separator: ", ")) }
        parts.append(conversation.updatedAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: ". ")
    }
}

/// Up to three quiet symbols for what ReGlass did, then "+2" for the rest. Decoration: rows say it in words for
/// VoiceOver, so they stay Text Secondary and leave copper to what's tappable or live.
private struct ActionGlyphs: View {
    let kinds: [ChatActionKind]

    var body: some View {
        if !kinds.isEmpty {
            HStack(spacing: 7) {
                ForEach(kinds.prefix(3), id: \.self) { kind in
                    Image(systemName: kind.symbol)
                        .font(.footnote.weight(.semibold))
                        .imageScale(.medium)
                        .foregroundStyle(Theme.textSecondary)
                }
                if kinds.count > 3 {
                    Text("+\(kinds.count - 3)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .fixedSize()
            .accessibilityHidden(true)
        }
    }
}

private struct DayHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Before the first conversation. Says only what will happen, not what ReGlass can't do yet.
private struct EmptyChats: View {
    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Ellipse()
                    .fill(Theme.halo)
                    .frame(width: 120, height: 70)
                    .blur(radius: 30)
                    .opacity(0.4)
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            .frame(height: 80)
            .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("No conversations yet")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("Your conversations through your glasses show up here. You can also type to ReGlass below.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 290)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Pieces

/// A card you press: sinks a little and springs back, like the pills. A dim instead under Reduce Motion.
struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.pressFeedback(configuration.isPressed, scale: 0.98)
    }
}

/// Mail's row actions on a card in a home list (a chat, a note): swipe right for Copy and Remind Me, swipe left to
/// Delete (a full swipe deletes straight away), and the same three on a press and hold, the card lifting in its own
/// rounded shape. VoiceOver offers the swipe actions as the row's actions. iOS's own swipe colours (`Theme.Swipe`):
/// Copy blue, Remind Me orange, Delete red. No haptics of their own: the banner taps lightly as it says "Copied" or offers Undo,
/// and the switcher ticks as Reminders opens.
struct CardRowActions: ViewModifier {
    let copy: () -> Void
    let remind: () -> Void
    let delete: () -> Void
    /// The card's corner radius, for the lifted preview.
    var cornerRadius: CGFloat = 20

    func body(content: Content) -> some View {
        content
            // Copy at the edge, Remind Me beside the card. No full swipe this side: it only reveals the two.
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
            .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contextMenu {
                Button(action: copy) { Label("Copy", systemImage: "doc.on.doc") }
                Button(action: remind) { Label("Remind Me", systemImage: "bell") }
                Divider()
                Button(role: .destructive, action: delete) { Label("Delete", systemImage: "trash") }
            }
    }
}

extension View {
    /// See `CardRowActions`.
    func cardRowActions(copy: @escaping () -> Void, remind: @escaping () -> Void, delete: @escaping () -> Void,
                        cornerRadius: CGFloat = 20) -> some View {
        modifier(CardRowActions(copy: copy, remind: remind, delete: delete, cornerRadius: cornerRadius))
    }
}

/// The entrance for the rows on screen when the list opens; rows scrolled to later just appear.
private struct FirstRowsEntrance: ViewModifier {
    let index: Int?

    func body(content: Content) -> some View {
        if let index { content.entrance(index) } else { content }
    }
}

private extension View {
    /// A list row that is only its content: no system background, separator or default insets.
    func chatListRow(top: CGFloat, bottom: CGFloat) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 20, bottom: bottom, trailing: 20))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

extension Date {
    /// "Today", "Yesterday", then "Monday 26 October" (with the year once it isn't this year).
    var chatDay: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        let style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        return calendar.isDate(self, equalTo: .now, toGranularity: .year) ? formatted(style) : formatted(style.year())
    }
}
