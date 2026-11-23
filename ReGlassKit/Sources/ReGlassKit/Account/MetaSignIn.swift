import Foundation

/// One Meta sign-in conversation. Meta drives every screen (account picker, email entry, code entry, resend,
/// errors) through its server-driven "Bloks" UI; ReGlass renders the `Screen` this hands it and sends the user's
/// actions back. There are no password fields, no reads of other apps' credentials, no cookies, and nothing goes
/// anywhere but Meta's fixed HTTPS endpoints.
///
/// Drive it from the main actor: set `onScreen`, call `start()`, then forward the user's taps and edits. Screens
/// are delivered to `onScreen` on the main actor. The outcome (cached login or failure) surfaces through the
/// `MetaAccount` that created this, as a `status` change — the app observes that, not this object.
@MainActor
public final class MetaSignIn {
    private let session: BloksSession
    private var started = false

    /// Called on the main actor whenever the screen to show changes.
    public var onScreen: ((Screen) -> Void)?

    /// Called once, on the main actor, when Meta's part is over (code accepted, failed, or cancelled). The result
    /// itself arrives as a `MetaAccount` status change; this only tells the screen to stop taking input.
    public var onFinish: (() -> Void)?

    /// The terminal result, consumed by `MetaAccount`.
    var onOutcome: ((BloksSession.Outcome) -> Void)?

    private let next: String

    init(client: BloksClient, next: String, deviceID: String) {
        self.next = next
        session = BloksSession(client: client, deviceID: deviceID)
        session.onScreen = { [weak self] screen in self?.onScreen?(screen) }
        session.onOutcome = { [weak self] outcome in
            self?.onFinish?()
            self?.onOutcome?(outcome)
        }
    }

    /// Begins the conversation. Call once, after setting `onScreen`.
    public func start() {
        guard !started else { return }
        started = true
        session.start(next: next)
    }

    /// Invoke a tappable action: a button, a tappable paragraph span, or a field's submit/focus/blur action.
    public func perform(_ action: Action) { session.invoke(action.event) }

    /// Report the current text of a field. `revision` must increase on each local edit so a server-side edit that
    /// arrived in between is not clobbered.
    public func setText(_ field: Field, _ text: String, revision: UInt64) {
        session.setText(field.input, text, revision: revision)
    }

    /// Go back one screen (or let the current screen's own back handler run). Closes the flow from the first screen.
    public func goBack() { session.back() }

    public func dismissDialog() { session.dismissDialog() }

    public func choose(_ button: Dialog.Button) { session.chooseDialog(button.index) }

    /// Abandon the conversation. Drops typed input and transient server state, and cancels pending work.
    public func cancel() { session.close() }
}

// MARK: Screen model

public extension MetaSignIn {
    /// An opaque handle to a server-side event. Hand it back through `perform(_:)`.
    struct Action {
        let event: BloksEvent
    }

    /// Stable identity of a text field within a screen, for focus handling and `.id(_:)` in SwiftUI.
    struct FieldID: Hashable {
        let node: ObjectIdentifier
    }

    /// Which system keyboard a field expects.
    enum Keyboard: Sendable { case `default`, email, number }

    /// A run of text inside a paragraph. `action` is set when the run is a tappable link.
    struct Span {
        public let text: String
        public let isError: Bool
        public let action: Action?
        public var isTappable: Bool { action != nil }
    }

    struct Paragraph {
        public let text: String
        public let isError: Bool
        public let spans: [Span]
    }

    struct Field {
        public let id: FieldID
        public let label: String
        public let placeholder: String
        public let text: String
        public let editRevision: UInt64
        public let keyboard: Keyboard
        public let isOneTimeCode: Bool
        /// A maximum character count, or nil for no limit.
        public let maxLength: Int?
        public let isEnabled: Bool
        public let submit: Action?
        public let onFocus: Action?
        public let onBlur: Action?

        let input: BloksInput

        init(_ input: BloksInput, label: String) {
            self.input = input
            self.id = FieldID(node: ObjectIdentifier(input.node))
            self.label = label
            self.placeholder = input.hint
            self.text = input.text
            self.editRevision = input.editRevision
            self.maxLength = input.maxLength > 0 ? input.maxLength : nil
            self.isEnabled = input.enabled
            self.submit = input.onSubmit.map(Action.init)
            self.onFocus = input.onFocus.map(Action.init)
            self.onBlur = input.onBlur.map(Action.init)

            let words = (label + " " + input.hint).lowercased()
            let oneTimeCode = input.keyboard == "passcode" || words.contains("code") || input.secret
            self.isOneTimeCode = oneTimeCode
            if oneTimeCode || ["number", "numeric", "number-pad"].contains(input.keyboard ?? "") {
                self.keyboard = .number
            } else if input.keyboard?.contains("email") == true || (label + input.hint).lowercased().contains("email") {
                self.keyboard = .email
            } else {
                self.keyboard = .default
            }
        }
    }

    /// Something to tap. Usually a button; on Meta's account picker, a row for one account.
    struct Button {
        /// The button's text joined and formatted for display.
        public let label: String
        public let isPrimary: Bool
        public let isEnabled: Bool
        public let action: Action
        /// A row's first line (an account's name, email or username).
        public let title: String
        /// The row's other texts (such as which app the account belongs to), or nil.
        public let subtitle: String?
        /// The pictures inside the row, avatar first: HTTPS on Meta's own hosts only (`isMetaImageURL`), never
        /// icon-size glyphs. Load them without cookies or a disk cache, and never log them.
        public let imageURLs: [URL]
        /// Meta drew this as a choice of account: a row with a picture, or a name on the account picker.
        public let isAccountChoice: Bool

        public var avatarURL: URL? { imageURLs.first }

        /// HTTPS on fbcdn.net, cdninstagram.com, facebook.com or instagram.com (or a subdomain), default port, no
        /// credentials. Anything else gets a placeholder instead.
        public static func isMetaImageURL(_ url: URL) -> Bool {
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443,
                  let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
            return ["fbcdn.net", "cdninstagram.com", "facebook.com", "instagram.com"].contains { host == $0 || host.hasSuffix("." + $0) }
        }
    }

    enum Item {
        case heading(String)
        case paragraph(Paragraph)
        case field(Field)
        case button(Button)
    }

    struct Dialog {
        public struct Button {
            public let label: String
            let index: Int
        }
        public let title: String?
        public let message: String?
        public let buttons: [Button]
    }

    /// Identity of one Meta screen in this conversation. A screen opened later compares greater, so a smaller id
    /// than the last one means the user went back.
    struct ScreenID: Hashable, Comparable, Sendable {
        let serial: Int
        public static func < (a: ScreenID, b: ScreenID) -> Bool { a.serial < b.serial }
    }

    /// What a screen asks of the user, for choosing its picture and motion. Content first, Meta's screen name second.
    enum Kind: Hashable, Sendable {
        /// Nothing to show yet.
        case loading
        /// An email (or other account name) field.
        case email
        /// The code Meta emailed.
        case code
        /// Pick one of several accounts.
        case chooseAccount
        /// Offer to keep the login.
        case saveLogin
        case other
    }

    /// The whole screen to render. Rebuilt from scratch on every change.
    struct Screen {
        /// Which Meta screen this is. Stays the same while the screen updates in place (typing, errors, busy).
        public var id: ScreenID
        public var kind: Kind
        public var items: [Item]
        /// The current screen's own back action, if it provides one. Otherwise call `goBack()`.
        public var back: Action?
        /// Whether a back/cancel affordance should be offered.
        public var canGoBack: Bool
        /// A request to Meta is in flight.
        public var isBusy: Bool
        /// The screen has no content yet (opening, or waiting on a component).
        public var isLoading: Bool
        public var dialog: Dialog?
        /// A transient server message (toast), if any.
        public var message: String?
        /// The field Meta asked to focus, if any.
        public var focusedField: FieldID?
        /// Increments each time Meta asks to dismiss the keyboard.
        public var keyboardDismissals: Int
    }
}
