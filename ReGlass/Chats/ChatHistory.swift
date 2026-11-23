import Foundation
import SwiftData

/// The history of conversations through the glasses, and the one way to write to it.
///
/// The voice layer records a conversation as it happens, through handles:
///
///     let history = ChatHistory.shared
///     let chat = history.beginConversation(trigger: .heyMeta)
///     history.addUserTranscript("Set a timer for ten minutes and play something calm", to: chat)
///     let timer = history.startAction(.timer, title: "Setting a timer for 10 minutes", in: chat)
///     history.finishAction(timer, title: "Timer set for 10 minutes")
///     let music = history.startAction(.music, title: "Playing “Slow Mornings”", in: chat)
///     history.failAction(music, detail: "The music service didn't answer.")
///     history.addAssistantReply("The lights are off. I couldn't start the music.", to: chat)
///     history.endConversation(chat)
///
/// A conversation can hold any number of exchanges: keep adding transcripts, actions and replies to the same handle
/// until `endConversation`. Every call saves straight away. A handle whose conversation the user has deleted is
/// ignored, so the voice layer never has to check. Deleting doesn't erase: a deleted conversation waits in Recently
/// Deleted for `keepDeletedDays` (`deletedAt`), out of Chats and Search, until it's put back or its time is up. Anything still open when ReGlass stops is closed at the next
/// launch, and running actions are marked `interrupted`.
///
/// Private by design: the store lives only on this iPhone (no iCloud), its files are protected until the iPhone has
/// been unlocked once after a restart, and nothing here writes what was said to the activity log. No AI or network
/// code lives here.
@MainActor
final class ChatHistory {
    static let shared = ChatHistory()

    struct ConversationHandle: Hashable, Sendable {
        let id: UUID
    }

    struct ActionHandle: Hashable, Sendable {
        let id: UUID
        let conversation: UUID
    }

    let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let log: (String) -> Void

    /// Application Support/ReGlass/Chats. Files created inside take the folder's protection class.
    static let directory = Storage.directory.appendingPathComponent("Chats", isDirectory: true)

    /// `log` gets only states and error types, never what was said. Defaults to ReGlass's activity log.
    init(log activity: ActivityLog? = nil) {
        let activity = activity ?? GlassesController.shared.log
        let log: (String) -> Void = { activity.add($0) }
        self.log = log
        let schema = Schema([Conversation.self, ChatEntry.self])
        do {
            try ChatHistory.prepareDirectory()
            let configuration = ModelConfiguration("Chats", schema: schema,
                                                   url: ChatHistory.directory.appendingPathComponent("Chats.store"),
                                                   cloudKitDatabase: .none)
            container = try ModelContainer(for: schema, configurations: configuration)
            ChatHistory.protectFiles()
        } catch {
            // ReGlass still opens; conversations just don't outlive this launch.
            log("Chat history couldn't open its store, so this session's conversations won't be kept (\(type(of: error)))")
            // `.none` here too: with an iCloud capability the default (`.automatic`) would try to sync, and CloudKit
            // refuses the models' `.unique` ids.
            container = try! ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true,
                                                                                            cloudKitDatabase: .none))
        }
        closeLeftovers()
        // Once `shared` exists: the log line it writes publishes to SwiftUI, which mustn't happen mid-update.
        Task { @MainActor [weak self] in self?.purgeDeleted() }
    }

    // MARK: Recording

    /// Opens a new conversation. Its title comes from the first transcript unless `setTitle` gives one.
    @discardableResult
    func beginConversation(trigger: ChatTrigger, at date: Date = .now) -> ConversationHandle {
        let conversation = Conversation(trigger: trigger, startedAt: date)
        context.insert(conversation)
        save()
        return ConversationHandle(id: conversation.id)
    }

    /// What the user said, as transcribed.
    func addUserTranscript(_ text: String, to chat: ConversationHandle, at date: Date = .now) {
        guard let conversation = find(chat) else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        append(.user, text: text, to: conversation, at: date)
        if conversation.title.isEmpty { conversation.title = Self.title(from: text) }
        save()
    }

    /// What someone other than the user said, as transcribed (the live interpreter's other person).
    func addOtherTranscript(_ text: String, to chat: ConversationHandle, at date: Date = .now) {
        guard let conversation = find(chat) else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        append(.other, text: text, to: conversation, at: date)
        save()
    }

    /// Something ReGlass is doing about it. Returns a handle to finish, fail or cancel it with.
    /// `title` reads as what happens ("Searching the web for …"); `finishAction` can replace it with the outcome.
    @discardableResult
    func startAction(_ kind: ChatActionKind, title: String, detail: String? = nil,
                     in chat: ConversationHandle, at date: Date = .now) -> ActionHandle {
        let id = UUID()
        guard let conversation = find(chat) else { return ActionHandle(id: id, conversation: chat.id) }
        let entry = append(.action, text: title, to: conversation, at: date, id: id)
        entry.actionKindRaw = kind.rawValue
        entry.detail = detail
        entry.statusRaw = ChatActionStatus.running.rawValue
        save()
        return ActionHandle(id: id, conversation: chat.id)
    }

    /// The action worked. Optionally a final title ("Played “Slow Mornings” on Tidal") and detail.
    func finishAction(_ action: ActionHandle, title: String? = nil, detail: String? = nil, at date: Date = .now) {
        settle(action, .done, title: title, detail: detail, at: date)
    }

    /// The action didn't work. `detail` says why, in plain words.
    func failAction(_ action: ActionHandle, title: String? = nil, detail: String? = nil, at date: Date = .now) {
        settle(action, .failed, title: title, detail: detail, at: date)
    }

    /// The action was stopped before it finished (the user changed their mind, or the conversation moved on).
    func cancelAction(_ action: ActionHandle, title: String? = nil, detail: String? = nil, at date: Date = .now) {
        settle(action, .cancelled, title: title, detail: detail, at: date)
    }

    /// What the glasses said back.
    func addAssistantReply(_ text: String, to chat: ConversationHandle, at date: Date = .now) {
        guard let conversation = find(chat) else { return }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        append(.reply, text: text, to: conversation, at: date)
        save()
    }

    /// Replaces the title taken from the first transcript, e.g. with a summary.
    func setTitle(_ title: String, for chat: ConversationHandle) {
        guard let conversation = find(chat) else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        conversation.title = Self.title(from: title)
        save()
    }

    /// The conversation is over. Actions still running are marked cancelled.
    func endConversation(_ chat: ConversationHandle, at date: Date = .now) {
        guard let conversation = find(chat), conversation.endedAt == nil else { return }
        for entry in conversation.entries where entry.kind == .action && entry.status == .running {
            entry.statusRaw = ChatActionStatus.cancelled.rawValue
            entry.finishedAt = date
        }
        conversation.endedAt = date
        save()
    }

    /// A conversation the user goes on with (a reply typed in Chats): open again, so a recorder can add to it until
    /// `endConversation` closes it once more. Nil when it's been deleted.
    func reopenConversation(_ id: UUID) -> ConversationHandle? {
        let chat = ConversationHandle(id: id)
        guard let conversation = find(chat) else { return nil }
        conversation.endedAt = nil
        save()
        return chat
    }

    /// The stored conversation, to read (a typed reply's note for Claude). Nil when it's been deleted.
    func conversation(_ id: UUID) -> Conversation? {
        find(ConversationHandle(id: id))
    }

    // MARK: Deleting

    /// How long a deleted conversation waits in Recently Deleted before it's erased (as the library's).
    nonisolated static let keepDeletedDays = LibraryStore.keepDeletedDays

    /// Into Recently Deleted (`restore` puts it back).
    func delete(_ conversation: Conversation, at date: Date = .now) {
        guard conversation.deletedAt == nil else { return }
        conversation.deletedAt = date
        save()
    }

    /// Settings' "Delete all conversations": every one into Recently Deleted, whose Delete All erases them.
    func deleteAll(at date: Date = .now) {
        let all = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.deletedAt == nil }))) ?? []
        for conversation in all { conversation.deletedAt = date }
        save()
        log("Moved all conversations to Recently Deleted")
    }

    /// Deleted conversations, most recently deleted first.
    func deletedConversations() -> [Conversation] {
        let descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.deletedAt != nil },
                                                       sortBy: [SortDescriptor(\.deletedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Out of Recently Deleted, back in Chats where it was. One deleted while it was still going missed its end (writes
    /// to a deleted conversation are dropped), so it's closed as `closeLeftovers` would, rather than reading "In
    /// progress".
    @discardableResult
    func restore(_ ids: [UUID]) -> Int {
        let deleted = ids.compactMap { findAny($0) }.filter { $0.deletedAt != nil }
        guard !deleted.isEmpty else { return 0 }
        for conversation in deleted {
            conversation.deletedAt = nil
            guard conversation.endedAt == nil else { continue }
            conversation.endedAt = conversation.updatedAt
            for entry in conversation.entries where entry.status == .running {
                entry.statusRaw = ChatActionStatus.interrupted.rawValue
            }
        }
        save()
        return deleted.count
    }

    /// Erased for good, with everything said in them, from Recently Deleted. Only ones already deleted.
    func erase(_ ids: [UUID]) {
        let deleted = ids.compactMap { findAny($0) }.filter { $0.deletedAt != nil }
        guard !deleted.isEmpty else { return }
        for conversation in deleted { context.delete(conversation) }
        save()
    }

    /// Erases what has waited in Recently Deleted longer than `keepDeletedDays`. At launch and as Recently Deleted
    /// opens.
    func purgeDeleted(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-TimeInterval(Self.keepDeletedDays) * 86_400)
        let old = deletedConversations().filter { ($0.deletedAt ?? now) < cutoff }
        guard !old.isEmpty else { return }
        for conversation in old { context.delete(conversation) }
        save()
        log("Erased \(old.count) conversation\(old.count == 1 ? "" : "s") deleted over \(Self.keepDeletedDays) days ago")
    }

    // MARK: Private

    /// The conversation, unless it's in Recently Deleted.
    private func find(_ chat: ConversationHandle) -> Conversation? {
        guard let conversation = findAny(chat.id), conversation.deletedAt == nil else { return nil }
        return conversation
    }

    /// The conversation, in Chats or in Recently Deleted.
    private func findAny(_ id: UUID) -> Conversation? {
        var descriptor = FetchDescriptor<Conversation>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func findAction(_ action: ActionHandle) -> ChatEntry? {
        let id = action.id
        var descriptor = FetchDescriptor<ChatEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    @discardableResult
    private func append(_ kind: ChatEntry.Kind, text: String, to conversation: Conversation, at date: Date,
                        id: UUID = UUID()) -> ChatEntry {
        let position = (conversation.entries.map(\.position).max() ?? -1) + 1
        let entry = ChatEntry(id: id, position: position, kind: kind, text: text, createdAt: date)
        context.insert(entry)
        entry.conversation = conversation
        conversation.updatedAt = max(conversation.updatedAt, date)
        return entry
    }

    private func settle(_ action: ActionHandle, _ status: ChatActionStatus, title: String?, detail: String?, at date: Date) {
        guard let entry = findAction(action), entry.status == .running else { return }
        entry.statusRaw = status.rawValue
        entry.finishedAt = date
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { entry.text = title }
        if let detail { entry.detail = detail }
        if let conversation = entry.conversation { conversation.updatedAt = max(conversation.updatedAt, date) }
        save()
    }

    /// ReGlass stopped mid-conversation last time: close what was open so nothing claims to still be running.
    private func closeLeftovers() {
        let running = ChatActionStatus.running.rawValue
        let interrupted = ChatActionStatus.interrupted.rawValue
        let openActions = (try? context.fetch(FetchDescriptor<ChatEntry>(predicate: #Predicate { $0.statusRaw == running }))) ?? []
        for entry in openActions { entry.statusRaw = interrupted }
        let open = (try? context.fetch(FetchDescriptor<Conversation>(predicate: #Predicate { $0.endedAt == nil }))) ?? []
        for conversation in open { conversation.endedAt = conversation.updatedAt }
        if !openActions.isEmpty || !open.isEmpty { save() }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            // Only the error's type: never what was said.
            log("Chat history couldn't be saved (\(type(of: error)))")
        }
    }

    /// The first line of what was said, cut at a word near 60 characters.
    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        guard line.count > 60 else { return line }
        let cut = line.prefix(60)
        var atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        while let last = atWord.last, last.isWhitespace || last.isPunctuation { atWord = atWord.dropLast() }
        return String(atWord) + "…"
    }

    // MARK: File protection

    /// Transcripts and mail can be private, so the store is readable only once the iPhone has been unlocked after a
    /// restart. Not `.complete`: the glasses are used with the iPhone locked in a pocket, and recording must still work.
    private static let protection = FileProtectionType.completeUntilFirstUserAuthentication

    private static func prepareDirectory() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: protection])
        try manager.setAttributes([.protectionKey: protection], ofItemAtPath: directory.path)
    }

    /// The store, its journal and shared memory files. New ones inherit the folder's class; this covers older ones.
    private static func protectFiles() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            try? manager.setAttributes([.protectionKey: protection], ofItemAtPath: file.path)
        }
    }
}
