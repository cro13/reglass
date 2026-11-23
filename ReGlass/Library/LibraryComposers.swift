import SwiftUI

// The bars at the bottom of the home's Notes and Reminders pages: the same glass bar as Chats' "Ask ReGlass", one field
// and one round button. Notes' bar saves straight into ReGlass's library (`LibraryStore`) as typed; Reminders' bar hands
// the words to the assistant, which sets, moves, adds or answers in its own words. Both follow the page's open chip:
// a note typed with Ideas open goes in Ideas, and with Shopping open the Reminders bar says "Add to Shopping…".

// MARK: Note

/// "Write a note": the words, and the button that keeps them. The new note springs in at the top of the list, in the
/// category whose chip is open.
struct NoteComposer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    /// The chip open on Notes (nil: All): the note goes in it.
    var category: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var saved = 0

    private var canSave: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(category.map { "Write a note in \($0)" } ?? "Write a note", text: $draft, axis: .vertical)
                .lineLimit(1...6)
                .focused(focused)
                .padding(.leading, 16)
                .padding(.vertical, 11)
                .frame(minHeight: 44)
            ComposerButton(ready: canSave, label: "Save Note", action: save)
                .disabled(!canSave)
        }
        .padding(4)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: saved)
    }

    /// Keeps the words as typed, in the open chip's category; ReGlass then writes the note's title (`NoteTitler`).
    private func save() {
        guard canSave, let note = LibraryStore.shared.addNote(text: draft, category: category, source: .typed) else { return }
        draft = ""
        focused.wrappedValue = false
        saved += 1
        NoteTitler.shared.makeTitle(for: note.id)
    }
}

// MARK: Reminder

/// "Remind me…": one line in your own words ("check the food in 6 minutes", "call mum tomorrow at nine"), handed to
/// ReGlass's assistant, which sets the reminder with the same tools as "Hey Meta, remind me…". ReGlass doesn't read the
/// time itself. Its answer shows on a line above the field: "Okay, in 6 minutes: check the food." fades after a few
/// seconds; a question back ("When should I remind you?") stays, with the keyboard up, and the next line answers it.
/// With a chip open it's "Add to Shopping…": the line goes to the assistant with that category, so "eggs and two
/// lemons" lands on Shopping as two things. Without a Claude key the field says so instead of sending. The first
/// reminder set here is when ReGlass asks to send notifications.
struct ReminderComposer: View {
    @Binding var draft: String
    var focused: FocusState<Bool>.Binding
    /// Reminders is the page showing: a question back takes the keyboard only then, never from another tab.
    var active = true
    /// The chip open on Reminders (nil: All).
    var category: String? = nil
    @ObservedObject private var assistant = AssistantController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sent = 0

    private var request: AssistantController.ReminderRequest? { assistant.reminderRequest }
    private var working: Bool { request?.status == .working }

    private var canSend: Bool {
        assistant.hasAnthropicKey && !working && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let request {
                answerLine(request)
                    .id(request.id)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            } else if focused.wrappedValue && draft.isEmpty {
                hint
                    .transition(.opacity)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused(focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .disabled(!assistant.hasAnthropicKey)
                    .padding(.leading, 16)
                    .padding(.vertical, 11)
                    .frame(minHeight: 44)
                ComposerButton(ready: canSend, working: working,
                               label: category.map { "Add to \($0)" } ?? "Set Reminder", action: send)
                    .disabled(!canSend)
            }
        }
        .padding(4)
        .glassSurface(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.84), value: request)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.84),
                   value: focused.wrappedValue)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.7), trigger: sent)
        .sensoryFeedback(trigger: request?.status) { _, status in
            switch status {
            case .done(changed: true)?: return .success
            case .failed?: return .warning
            default: return nil
            }
        }
        .onChange(of: request?.status) { _, status in settled(status) }
        .onChange(of: draft) { _, words in
            // Typing something new takes a finished answer away; an open question stays until it's answered.
            if !words.isEmpty, case .done(changed: true)? = request?.status { assistant.clearReminderRequest() }
            if !words.isEmpty, case .failed? = request?.status { assistant.clearReminderRequest() }
        }
        .onAppear { assistant.refreshKeys() }
    }

    private var placeholder: String {
        if assistant.keysLocked { return "Unlock your iPhone to set reminders" }
        guard assistant.hasAnthropicKey else { return "Add your Claude key to set reminders" }
        if let category { return "Add to \(category)\u{2026}" }
        return "Remind me to\u{2026}"
    }

    /// Before the first word: what to type.
    private var hint: some View {
        HStack(spacing: 7) {
            (category.map { Image(category: $0) } ?? Image(systemName: "bell"))
                .foregroundStyle(Theme.textTertiary)
            Text(hintText)
                .foregroundStyle(Theme.textTertiary)
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var hintText: String {
        guard let category else { return "What and when, like \u{201C}check the food in 6 minutes\u{201D}" }
        if LibraryCategory.same(category, LibraryCategory.shopping) {
            return "What to buy, like \u{201C}eggs and two lemons\u{201D}"
        }
        return "Something to do, or a reminder with a time"
    }

    /// What ReGlass is doing with the line, or what it answered: a check when it set or changed something (done is a
    /// checkmark), a speech bubble when it only replied.
    private func answerLine(_ request: AssistantController.ReminderRequest) -> some View {
        let reply = request.reply.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch request.status {
            case .working:
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.accentFill)
                Text("\u{201C}\(request.request)\u{201D}")
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            case .done(let changed):
                Image(systemName: changed ? "checkmark.circle" : "bubble.left.fill")
                    .foregroundStyle(Theme.accent)
                Text(reply.isEmpty ? (changed ? "Done." : "ReGlass didn\u{2019}t answer. Try saying when, too.") : reply)
                    .foregroundStyle(changed ? Theme.textSecondary : Theme.ink)
                    .lineLimit(4)
            case .failed(let why):
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Theme.warning)
                Text(why)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
    }

    private func send() {
        guard canSend else { return }
        assistant.askAboutReminders(draft, category: category)
        draft = ""
        sent += 1
    }

    /// Set: the keyboard goes down so the new reminder can be seen arriving, and the line fades a few seconds later.
    /// Failed: the words come back into the field, so nothing typed is lost. A question keeps the keyboard up.
    private func settled(_ status: AssistantController.ReminderRequest.Status?) {
        guard let status, let request else { return }
        let reply = request.reply.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if case .failed(let why) = status {
            AccessibilityNotification.Announcement(why).post()
        } else if status != .working, !reply.isEmpty {
            AccessibilityNotification.Announcement(reply).post()
        }
        switch status {
        case .done(changed: true):
            focused.wrappedValue = false
            askForAlertsOnce()
            let id = request.id
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if assistant.reminderRequest?.id == id { assistant.clearReminderRequest() }
            }
        case .done(changed: false):
            if active { focused.wrappedValue = true }
        case .failed:
            if draft.isEmpty { draft = request.request }
        case .working:
            break
        }
    }
}

extension ReminderComposer {
    /// Notification permission, asked in context: right after a reminder has been set (not an item added to a list),
    /// so the alert's question has an obvious answer. The scheduler asks only once, and only with ReGlass on screen.
    fileprivate func askForAlertsOnce() {
        guard !LibraryStore.shared.upcomingReminders().isEmpty else { return }
        Task { await ReminderScheduler.shared.requestNotificationPermission() }
    }
}

// MARK: Pieces

/// The round button at the end of a bar: a copper disc with a dark arrow once there's something to send, a faint
/// one before, and a small spinner while ReGlass works on what was sent. Same as Chats' send button. It sinks under the
/// finger and springs back (a dim under Reduce Motion).
private struct ComposerButton: View {
    let ready: Bool
    var working = false
    let label: String
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                if working {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.accentFill)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ready ? Theme.onAccent : Theme.textTertiary)
                }
            }
            .frame(width: 36, height: 36)
            .background {
                Circle().fill(ready ? AnyShapeStyle(Theme.accentFill) : AnyShapeStyle(Theme.track))
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(SoftPressStyle())
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7), value: ready)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7), value: working)
        .accessibilityLabel(working ? "Setting It" : label)
    }
}
