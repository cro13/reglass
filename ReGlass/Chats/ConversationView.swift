import SwiftData
import SwiftUI
import UIKit

/// One conversation as it happened: what you said, what ReGlass did about it, and what the glasses said back, on a
/// quiet rail of markers rather than messenger bubbles. Updates live while the conversation is still going, and the
/// bar at the bottom goes on with it by typing, for when talking to the glasses isn't an option.
///
/// Opened from Search, it starts at the step that matched (`reveal`) and lights the search's words copper throughout.
struct ConversationView: View {
    @Query private var matches: [Conversation]
    @Environment(\.dismiss) private var dismiss
    private let reveal: UUID?
    private let terms: SearchTerms

    init(id: UUID, reveal: UUID? = nil, query: String = "") {
        _matches = Query(filter: #Predicate<Conversation> { $0.id == id && $0.deletedAt == nil })
        self.reveal = reveal
        terms = SearchTerms(query)
    }

    var body: some View {
        ZStack {
            ReGlassBackdrop()
            // Empty only for the moment between deleting it and the screen closing.
            if let conversation = matches.first {
                Transcript(conversation: conversation, reveal: reveal, terms: terms)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let conversation = matches.first {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = Self.plainText(conversation)
                            LibraryToast.shared.show("Copied", symbol: "doc.on.doc")
                        } label: {
                            Label("Copy Conversation", systemImage: "doc.on.doc")
                        }
                        Button(role: .destructive) { delete(conversation) } label: {
                            Label("Delete Conversation", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .tint(Theme.ink)   // ink like the system back button beside it
                    .accessibilityLabel("More")
                }
            }
        }
    }

    /// Closes the conversation and leaves the deleting to the banner, as a swipe in Chats does: gone from the list at
    /// once, into Recently Deleted once something else happens, unless Undo is tapped. No question first: it can be
    /// put back.
    private func delete(_ conversation: Conversation) {
        let id = conversation.id
        dismiss()
        LibraryToast.shared.delete(id, text: "Chat deleted") {
            guard let conversation = ChatHistory.shared.conversation(id) else { return }
            ChatHistory.shared.delete(conversation)
        }
    }

    /// The conversation as text, for the pasteboard.
    static func plainText(_ conversation: Conversation) -> String {
        let start = conversation.startedAt
        var lines = ["\(start.chatDay), \(start.formatted(date: .omitted, time: .shortened)) · \(conversation.trigger.startedLabel)", ""]
        for entry in conversation.orderedEntries {
            switch entry.kind {
            case .user: lines.append("You: " + entry.text)
            case .other: lines.append("Them: " + entry.text)
            case .reply: lines.append("Glasses: " + entry.text)
            case .action:
                lines.append("• \(entry.text) (\(entry.status.label))" + (entry.detail.map { ": " + $0 } ?? ""))
            }
        }
        return lines.joined(separator: "\n")
    }
}

private struct Transcript: View {
    let conversation: Conversation
    /// The step to open at (from Search).
    let reveal: UUID?
    /// Search's words, lit copper.
    let terms: SearchTerms
    @ObservedObject private var assistant = AssistantController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How many entries were there when the screen opened: those arrive one after another, later ones at once.
    @State private var openedWith: Int?
    /// When ReGlass's answer to a reply typed here last finished: the chat's own reply row that replaces it within a
    /// moment takes its place without an entrance, so the same words don't fade out and back in.
    @State private var pendingEnded: Date?
    @FocusState private var composing: Bool

    /// ReGlass's answer to a reply typed here, while it comes and until the chat has it.
    private var pending: AssistantController.ChatReply? {
        assistant.chatReply.flatMap { $0.chat == conversation.id ? $0 : nil }
    }

    var body: some View {
        let entries = conversation.orderedEntries
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .entrance(0)
                        .padding(.bottom, 28)
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        let isLast = index == entries.count - 1
                        EntryRow(entry: entry,
                                 terms: terms,
                                 isLast: isLast && pending == nil,
                                 startsTurn: index > 0 && entry.kind.startsExchange,
                                 railContinues: isLast ? pending != nil : !entries[index + 1].kind.startsExchange)
                            .id(entry.id)
                            .modifier(EntryEntrance(index: entranceIndex(index, entry, opened: openedWith ?? entries.count)))
                            .transition(takesOver(index, entry, opened: openedWith ?? entries.count) ? .identity : .opacity)
                    }
                    if let pending {
                        PendingReplyRow(reply: pending)
                            .id(Self.pendingID)
                            // In from below; out at once, as the saved reply with the same words takes its place.
                            .transition(.asymmetric(insertion: reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)),
                                                    removal: .identity))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85),
                           value: entries.map(\.id))
                .assistantAnimation(pending?.id, reduceMotion: reduceMotion)
                .assistantAnimation(pending?.sentences.count, reduceMotion: reduceMotion)
            }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ChatComposer(purpose: .reply(conversation.id), composing: $composing)
                    // "Copied" (from the ⋯ menu) rises just above the bar, as it does over a note.
                    .overlay(alignment: .top) {
                        LibraryToastView()
                            .alignmentGuide(.top) { d in d[.bottom] }
                    }
            }
            .onAppear {
                guard openedWith == nil else { return }
                openedWith = entries.count
                // From Search: bring the step that matched to the middle once the screen has slid in.
                if let reveal, entries.contains(where: { $0.id == reveal }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) {
                            proxy.scrollTo(reveal, anchor: .center)
                        }
                    }
                }
            }
            // A live conversation: keep the newest step in view, and the end of it while you type.
            .onChange(of: entries.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: pending?.sentences.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: pending?.id) { old, new in if old != nil, new == nil { pendingEnded = .now } }
            .onChange(of: composing) { _, now in if now { scrollToEnd(proxy, delay: 0.3) } }
        }
    }

    private static let pendingID = "pending-reply"

    /// The entrance beat for the entry at `index`: the ones there on opening arrive one after another, later ones
    /// arrive on the first beat, and the reply that takes over from the pending answer has none.
    private func entranceIndex(_ index: Int, _ entry: ChatEntry, opened: Int) -> Int? {
        if index < opened { return min(index + 1, 8) }
        return takesOver(index, entry, opened: opened) ? nil : 0
    }

    /// The saved reply to a reply typed here, replacing the pending answer that showed the same words.
    private func takesOver(_ index: Int, _ entry: ChatEntry, opened: Int) -> Bool {
        guard index >= opened, entry.kind == .reply else { return false }
        if pending != nil { return true }
        guard let pendingEnded else { return false }
        return Date.now.timeIntervalSince(pendingEnded) < 2
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, delay: Double = 0) {
        // After the keyboard has come up (`delay`), so the end lands above it.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) {
                if pending != nil {
                    proxy.scrollTo(Self.pendingID, anchor: .bottom)
                } else if let last = conversation.orderedEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(conversation.startedAt.chatDay)
                .displayFont(.title)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: conversation.trigger.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityHidden(true)
                Text("\(conversation.startedAt.formatted(date: .omitted, time: .shortened)) · \(conversation.trigger.startedLabel)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An entry's entrance (`entrance(_:distance:enabled:)`), or none for nil. The same modifier either way, so an
/// entry that came in quietly never replays an entrance later.
private struct EntryEntrance: ViewModifier {
    let index: Int?

    func body(content: Content) -> some View {
        content.entrance(index ?? 0, distance: 10, enabled: index != nil)
    }
}

/// One step on the rail: a small round marker (you, the glasses, or what ReGlass did), the words beside it, and a
/// hairline running down to the next step. Each exchange has its own rail, so a new one reads as a new group.
private struct EntryRow: View {
    let entry: ChatEntry
    /// Search's words, lit copper (none: plain).
    var terms = SearchTerms("")
    let isLast: Bool
    /// The user speaks again: a little more room above, so exchanges read as groups.
    let startsTurn: Bool
    /// The next step belongs to the same exchange.
    let railContinues: Bool
    @ScaledMetric(relativeTo: .body) private var marker: CGFloat = 32

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Marker(entry: entry, size: marker)
                // Centre the marker on the first line of text.
                .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + marker * 0.14 }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, isLast ? 0 : 24)
        }
        .padding(.top, startsTurn ? 14 : 0)
        .background(alignment: .topLeading) {
            if railContinues {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(width: 1)
                    .padding(.top, marker + 6 + (startsTurn ? 14 : 0))
                    .padding(.bottom, 6)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, marker / 2 - 0.5)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var content: some View {
        switch entry.kind {
        case .user, .other:
            VStack(alignment: .leading, spacing: 4) {
                caption(entry.kind == .other ? "Them" : "You")
                Text(terms.highlight(entry.text))
                    .font(.title3)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .reply:
            VStack(alignment: .leading, spacing: 4) {
                caption("Glasses")
                Text(terms.highlight(entry.text))
                    .font(.body)
                    .foregroundStyle(Theme.ink.opacity(0.9))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .action:
            // What ReGlass did is the connective tissue between what was said and what the glasses answered, not a third
            // voice: quiet Body Small in Text Secondary, with how it went at the end of the same line where that fits,
            // otherwise on a line of its own under it.
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        actionTitle
                        Spacer(minLength: 0)
                        ActionStatusLabel(status: entry.status)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        actionTitle
                        ActionStatusLabel(status: entry.status)
                    }
                }
                if let detail = entry.detail, !detail.isEmpty {
                    Text(terms.highlight(detail))
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var actionTitle: some View {
        Text(terms.highlight(entry.text))
            .font(.subheadline)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.textTertiary)
    }

    private var accessibilityText: String {
        switch entry.kind {
        case .user: return "You said: " + entry.text
        case .other: return "They said: " + entry.text
        case .reply: return "Glasses replied: " + entry.text
        case .action:
            return [entry.text, entry.detail, entry.status.label].compactMap { $0 }.joined(separator: ". ")
        }
    }
}

/// ReGlass's answer to a reply typed here, as it comes: the arc spinner until the first sentence, then the words, with
/// a line saying whether it's being read aloud. The chat's own reply row takes its place once the answer is in.
private struct PendingReplyRow: View {
    let reply: AssistantController.ChatReply
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var marker: CGFloat = 32

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: "eyeglasses")
                .font(.system(size: marker * 0.4, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: marker, height: marker)
                .contentSurface(in: Circle())
                .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + marker * 0.14 }
                .accessibilityHidden(true)
            // Spaced like the saved reply row (`EntryRow`), so nothing shifts when that row takes over.
            VStack(alignment: .leading, spacing: 4) {
                Text("Glasses")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textTertiary)
                if reply.sentences.isEmpty {
                    AssistantStatusLine(tone: .working, text: "Thinking…")
                        .transition(.opacity)
                } else {
                    // Each new sentence fades in; the ones already there hold still.
                    StreamingText(sentences: reply.sentences)
                        .font(.body)
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                Group {
                    if reply.speaking {
                        Label("Reading it to you", systemImage: "waveform")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
                            .transition(.opacity)
                    } else if !reply.readAloud {
                        Text("Text only, so your iPhone stays quiet.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .assistantAnimation(reply.speaking, reduceMotion: reduceMotion)
        .assistantAnimation(reply.sentences.isEmpty, reduceMotion: reduceMotion)
        .accessibilityElement(children: .combine)
    }
}

/// You in ink; the glasses and what ReGlass did in copper.
private struct Marker: View {
    let entry: ChatEntry
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .imageScale(.medium)
            .foregroundStyle(entry.kind.startsExchange ? AnyShapeStyle(Theme.ink) : AnyShapeStyle(Theme.accent))
            .frame(width: size, height: size)
            .contentSurface(in: Circle())
            .accessibilityHidden(true)
    }

    private var symbol: String {
        switch entry.kind {
        case .user: return "person.fill"
        case .other: return "person.wave.2.fill"
        case .reply: return "eyeglasses"
        // An action with no kind of its own shows how it went: a check once done.
        case .action: return entry.actionKind == .other && entry.status == .done ? "checkmark" : entry.actionKind.symbol
        }
    }
}

/// Where an action got to, always in words, with the signal colour only on the symbol beside them.
private struct ActionStatusLabel: View {
    let status: ChatActionStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if status == .running {
                    ArcSpinner(size: 13, lineWidth: 1.5)
                        .transition(.opacity)
                } else {
                    // The spinner gives way to the outcome, which pops in once ("In progress" → "Done").
                    Image(systemName: symbol)
                        .foregroundStyle(color)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                }
            }
            Text(status.label)
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.opacity)
        }
        .font(.caption.weight(.medium))
        .animation(reduceMotion ? Theme.Motion.fade : .spring(response: 0.35, dampingFraction: 0.6), value: status)
    }

    private var symbol: String {
        switch status {
        case .running, .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        case .interrupted: return "exclamationmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .running: return Theme.accent
        case .done: return Theme.good
        case .failed: return Theme.critical
        case .cancelled: return Theme.textTertiary
        case .interrupted: return Theme.warning
        }
    }
}
