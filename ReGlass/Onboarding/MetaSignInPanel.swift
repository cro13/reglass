import ReGlassKit
import SwiftUI
import UIKit

/// One Meta sign-in on screen: the latest screen Meta sent, and whether Meta's part is over.
@MainActor
final class SignInFlow: ObservableObject {
    let signIn: MetaSignIn
    @Published private(set) var screen: MetaSignIn.Screen?
    /// Meta accepted the code (or the flow ended); ReGlass is finishing the login. Input is over.
    @Published private(set) var finishing = false
    /// Whether the last change of Meta screen moved forward (a newer screen) or back (an earlier one).
    @Published private(set) var forward = true

    init(_ signIn: MetaSignIn) {
        self.signIn = signIn
        signIn.onScreen = { [weak self] screen in
            guard let self else { return }
            if let shown = self.screen?.id, shown != screen.id { self.forward = screen.id > shown }
            self.screen = screen
        }
        signIn.onFinish = { [weak self] in self?.finishing = true }
    }

    func start() { signIn.start() }

    /// The page's back button. Closes Meta's dialog, runs Meta's own back, or from Meta's first screen ends the
    /// sign-in. Returns false when there is nothing on screen yet, so the caller can cancel instead.
    @discardableResult
    func back() -> Bool {
        guard let screen else { return false }
        guard !finishing, !screen.isBusy else { return true }   // Meta is answering: wait
        if screen.dialog != nil { signIn.dismissDialog() }
        else if let back = screen.back { signIn.perform(back) }
        else { signIn.goBack() }
        return true
    }
}

/// Meta's email-code sign-in, drawn right on the onboarding's sign-in page in ReGlass's style. Meta decides every
/// screen (email, account choice, code, resend, errors); this renders them and sends taps and typing back.
/// Meta's screens change in place: the emblem morphs to the new step, the old screen fades back and the new one's
/// pieces rise in one after another. Hidden while the app is inactive or the screen is recorded.
struct MetaSignInPanel: View {
    @ObservedObject var flow: SignInFlow
    let cancel: () -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var captured = UIScreen.main.isCaptured
    /// The account row just tapped. It shows progress (and the others dim) while Meta answers.
    @State private var chosen: RowRef?

    var body: some View {
        withReactions(layout)
            .overlay { dialogLayer }
            .overlay {
                if scenePhase != .active || captured { privacyCover }
            }
            .privacySensitive()
            // Meta's screens change in place: each new one, and Meta's dialog opening or closing, is a new screen to
            // VoiceOver.
            .announcesScreenChange(on: pageKey)
            .announcesScreenChange(on: dialogShown)
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                captured = UIScreen.main.isCaptured
            }
            .onDisappear { AvatarLoader.forget() }
    }

    private var layout: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    ReGlassEmblem(symbol: emblem, working: working, size: 68)
                        .padding(.vertical, -8)
                        .entrance(0, distance: 8)
                    ZStack(alignment: .top) {
                        page
                            .id(pageKey)
                            .transition(pageTransition)
                    }
                    .animation(pageAnimation, value: pageKey)
                }
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 0) {
                Label("Your email and code go straight to Meta", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                Button("Cancel", action: cancel)
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
        }
    }

    /// Resets the tapped row when Meta answers, and marks the key moments with haptics: a new Meta screen, an
    /// account picked, an error or a question from Meta, and the finish.
    private func withReactions<V: View>(_ view: V) -> some View {
        view
            .onChange(of: pageKey) { _, _ in chosen = nil }
            .onChange(of: isBusy) { _, busy in if !busy { chosen = nil } }
            .sensoryFeedback(.impact(weight: .light), trigger: screenID) { (old: MetaSignIn.ScreenID?, new: MetaSignIn.ScreenID?) in
                old != nil && new != nil && old != new
            }
            .sensoryFeedback(.selection, trigger: chosen) { (_: RowRef?, new: RowRef?) in new != nil }
            .sensoryFeedback(.error, trigger: errorCount) { (old: Int, new: Int) in new > old }
            .sensoryFeedback(.warning, trigger: dialogShown) { (_: Bool, shown: Bool) in shown }
            .sensoryFeedback(.success, trigger: flow.finishing) { (_: Bool, now: Bool) in now }
    }

    private var isBusy: Bool { flow.screen?.isBusy ?? false }
    private var screenID: MetaSignIn.ScreenID? { flow.screen?.id }
    private var dialogShown: Bool { !flow.finishing && flow.screen?.dialog != nil }

    // MARK: Pages

    /// One page per Meta screen (and per kind of step, should a screen change what it asks in place).
    private enum PageKey: Hashable {
        case waiting, finishing
        case screen(MetaSignIn.ScreenID, MetaSignIn.Kind)
    }

    private var pageKey: PageKey {
        if flow.finishing { return .finishing }
        guard let screen = flow.screen, screen.kind != .loading else { return .waiting }
        return .screen(screen.id, screen.kind)
    }

    /// A crossfade in place, as the onboarding's pages change: the new page settles up from 98 % (its pieces then
    /// rise in), the old one fades back quickly. No sideways drift, so Meta's steps never read as a wizard's slides.
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.98))
                .animation(.spring(response: 0.5, dampingFraction: 0.88).delay(0.06)),
            removal: AnyTransition.opacity.combined(with: .scale(scale: 0.96)).animation(.easeOut(duration: 0.18)))
    }

    private var pageAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.88)
    }

    @ViewBuilder private var page: some View {
        VStack(spacing: 18) {
            if flow.finishing {
                waiting("Finishing sign-in…")
            } else if let screen = flow.screen {
                content(screen)
            } else {
                waiting("Opening Meta sign-in…")
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isBusy)
    }

    /// The emblem follows the step: an envelope for the email, a lock for the code, two people for the account
    /// choice, a key for keeping the login, a seal when it's done.
    private var emblem: String {
        if flow.finishing { return "checkmark.seal" }
        switch flow.screen?.kind {
        case .email?: return "envelope"
        case .code?: return "lock"
        case .chooseAccount?: return "person.2"
        case .saveLogin?: return "key"
        default: return "person.crop.circle"
        }
    }

    private var working: Bool {
        guard !flow.finishing, let screen = flow.screen else { return true }
        return screen.isBusy || screen.isLoading
    }

    private var errorCount: Int {
        flow.screen?.items.reduce(0) { count, item in
            if case .paragraph(let paragraph) = item, paragraph.isError { return count + 1 }
            return count
        } ?? 0
    }

    @ViewBuilder private func content(_ screen: MetaSignIn.Screen) -> some View {
        let blocks = Block.group(screen.items)
        ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
            blockView(block, screen: screen)
                .entrance(index + 1)
        }
        // A tapped account row shows its own progress, so the general line stays out of the way then.
        if (screen.isBusy && chosen == nil) || screen.isLoading {
            waiting("Waiting for Meta…")
                .transition(.opacity)
        }
        if screen.items.isEmpty && !screen.isBusy && !screen.isLoading {
            Notice(text: "Meta sent a step ReGlass can't show yet. Cancel and try again in a moment.", tint: Theme.warning)
                .entrance(1)
        }
        if let message = screen.message, !message.isEmpty {
            Notice(text: message, tint: Theme.warning)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
        }
    }

    @ViewBuilder private func blockView(_ block: Block, screen: MetaSignIn.Screen) -> some View {
        switch block.content {
        case .item(let item):
            itemView(item, screen: screen)
        case .accounts(let rows):
            AccountList(rows: rows, busy: screen.isBusy,
                        chosen: chosen?.block == block.id ? chosen?.index : nil) { index, row in
                chosen = RowRef(block: block.id, index: index)
                flow.signIn.perform(row.action)
            }
        }
    }

    @ViewBuilder private func itemView(_ item: MetaSignIn.Item, screen: MetaSignIn.Screen) -> some View {
        switch item {
        case .heading(let text):
            Text(text)
                .displayFont(.title)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let paragraph):
            if paragraph.spans.contains(where: \.isTappable) {
                VStack(spacing: 6) {
                    ForEach(Array(paragraph.spans.enumerated()), id: \.offset) { _, span in
                        if let action = span.action {
                            Button(span.text) { flow.signIn.perform(action) }
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(minHeight: 44)
                                .disabled(screen.isBusy)
                        } else {
                            Text(span.text)
                                .foregroundStyle(span.isError ? Theme.critical : Theme.textSecondary)
                        }
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            } else {
                Text(paragraph.text)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(paragraph.isError ? Theme.critical : Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
        case .field(let field):
            SignInField(field: field, signIn: flow.signIn, busy: screen.isBusy,
                        focusRequested: screen.focusedField == field.id, dismissals: screen.keyboardDismissals)
                .id(field.id)
        case .button(let button):
            if button.isPrimary {
                Button(button.label) { flow.signIn.perform(button.action) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!button.isEnabled || screen.isBusy)
            } else {
                Button(button.label) { flow.signIn.perform(button.action) }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(!button.isEnabled || screen.isBusy)
            }
        }
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 10) {
            ArcSpinner()
            Text(text)
                .foregroundStyle(Theme.textSecondary)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: Dialogs and privacy

    /// Meta's dialog: a Liquid Glass card that springs up over a dimmed page. It floats over the content, so it stays
    /// Liquid Glass where the page's own cards are quiet content surfaces.
    private var dialogLayer: some View {
        let dialog: MetaSignIn.Dialog? = flow.finishing ? nil : flow.screen?.dialog
        return ZStack {
            if let dialog {
                Theme.scrim
                    .ignoresSafeArea()
                    .transition(.opacity)
                dialogCard(dialog)
                    // Only the dialog for VoiceOver while it's up, as with a system alert.
                    .accessibilityAddTraits(.isModal)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.4, dampingFraction: 0.8), value: dialog != nil)
    }

    private func dialogCard(_ dialog: MetaSignIn.Dialog) -> some View {
        VStack(spacing: 14) {
            if let title = dialog.title {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = dialog.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                if dialog.buttons.isEmpty {
                    Button("OK") { flow.signIn.dismissDialog() }.buttonStyle(SecondaryButtonStyle())
                }
                ForEach(Array(dialog.buttons.enumerated()), id: \.offset) { _, button in
                    Button(button.label) { flow.signIn.choose(button) }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .padding(.top, 4)
        }
        .padding(18)
        .frame(maxWidth: 380)
        .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(28)
    }

    private var privacyCover: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            Text(captured ? "Stop screen recording to continue signing in." : "Sign-in hidden")
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: Grouping

/// Which row of which account list was tapped.
private struct RowRef: Equatable {
    let block: BlockID
    let index: Int
}

/// A stable identity for each piece of a screen, so a piece that appears later (an error, a resend link) rises in
/// on its own while the rest stay put.
private enum BlockID: Hashable {
    case heading(String), paragraph(String), field(MetaSignIn.FieldID), button(String, Int), accounts(Int)
}

/// Meta's items, with consecutive account choices gathered into one list.
private struct Block: Identifiable {
    enum Content {
        case item(MetaSignIn.Item)
        case accounts([MetaSignIn.Button])
    }

    let id: BlockID
    let content: Content

    static func group(_ items: [MetaSignIn.Item]) -> [Block] {
        var blocks: [Block] = []
        var rows: [MetaSignIn.Button] = []
        var repeats: [String: Int] = [:]
        func closeRows() {
            guard !rows.isEmpty else { return }
            blocks.append(Block(id: .accounts(blocks.count), content: .accounts(rows)))
            rows = []
        }
        for item in items {
            if case .button(let button) = item, button.isAccountChoice {
                rows.append(button)
                continue
            }
            closeRows()
            let id: BlockID
            switch item {
            case .heading(let text): id = .heading(text)
            case .paragraph(let paragraph): id = .paragraph(paragraph.text)
            case .field(let field): id = .field(field.id)
            case .button(let button):
                let seen = repeats[button.label, default: 0]
                repeats[button.label] = seen + 1
                id = .button(button.label, seen)
            }
            blocks.append(Block(id: id, content: .item(item)))
        }
        closeRows()
        return blocks
    }
}

// MARK: Account choice

/// Meta's account choices as one list on a content surface (it's content, so not Liquid Glass): avatar, name,
/// detail, chevron. The tapped row swaps its chevron
/// for progress and the others dim until Meta answers.
private struct AccountList: View {
    let rows: [MetaSignIn.Button]
    let busy: Bool
    let chosen: Int?
    let choose: (Int, MetaSignIn.Button) -> Void
    @ScaledMetric(relativeTo: .headline) private var avatar: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 16 + avatar + 14)
                }
                AccountRow(row: row, order: index, mode: mode(index, row)) { choose(index, row) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func mode(_ index: Int, _ row: MetaSignIn.Button) -> AccountRow.Mode {
        if busy, let chosen { return chosen == index ? .chosen : .dimmed }
        if busy || !row.isEnabled { return .waiting }
        return .ready
    }
}

private struct AccountRow: View {
    enum Mode { case ready, waiting, chosen, dimmed }

    let row: MetaSignIn.Button
    let order: Int
    let mode: Mode
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                AccountAvatar(url: row.avatarURL, name: row.title, order: order)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                ZStack {
                    if mode == .chosen {
                        ArcSpinner(size: 20)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .transition(.opacity)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 70)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .disabled(mode != .ready)
        .opacity(mode == .dimmed ? 0.35 : mode == .waiting ? 0.6 : 1)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: mode)
        .accessibilityHint("Signs in with this account")
        .accessibilityValue(mode == .chosen ? "Signing in" : "")
    }
}

/// A row highlight and a small give under the finger.
private struct RowPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.track : Color.clear)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// The account's picture, springing in once it has loaded. Until then, or when Meta sent none (or one from
/// elsewhere than Meta's own hosts), the name's initial or a person glyph.
private struct AccountAvatar: View {
    let url: URL?
    let name: String
    let order: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .headline) private var diameter: CGFloat = 46
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(Theme.track)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
            } else {
                placeholder
                    .transition(.opacity)
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
        .task(id: url) { await load() }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var placeholder: some View {
        if let initial = name.first(where: \.isLetter).map({ String($0).uppercased() }) {
            Text(initial)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.accent)
        } else {
            Image(systemName: "person.fill")
                .font(.title3)
                .foregroundStyle(Theme.accent)
        }
    }

    private func load() async {
        guard let url, let loaded = await AvatarLoader.image(for: url), !Task.isCancelled else { return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.25)
                                   : .spring(response: 0.5, dampingFraction: 0.6).delay(0.12 * Double(order))) {
            image = loaded
        }
    }
}

/// Fetches the pictures on Meta's account picker: HTTPS from Meta's own hosts only (checked again after any
/// redirect), with no cookies, credentials or disk cache, held in memory only while the sign-in is on screen.
/// Addresses and pictures are never logged.
enum AvatarLoader {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: configuration)
    }()

    private static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 12
        return cache
    }()

    static func image(for url: URL) async -> UIImage? {
        guard MetaSignIn.Button.isMetaImageURL(url) else { return nil }
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let landed = http.url, MetaSignIn.Button.isMetaImageURL(landed),
              data.count <= 5_000_000,
              let full = UIImage(data: data), full.size.width > 0, full.size.height > 0
        else { return nil }
        // Enough pixels for the largest text size; the full picture is not kept.
        let scale = min(1, 210 / min(full.size.width, full.size.height))
        let target = CGSize(width: full.size.width * scale, height: full.size.height * scale)
        let image = await full.byPreparingThumbnail(ofSize: target) ?? full
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    static func forget() { memory.removeAllObjects() }
}

/// One text field. Keeps its own text and an edit revision, so a change from Meta that arrives mid-typing is
/// applied only when it is newer than the last local edit.
private struct SignInField: View {
    let field: MetaSignIn.Field
    let signIn: MetaSignIn
    let busy: Bool
    let focusRequested: Bool
    let dismissals: Int

    @State private var value: String
    @State private var revision: UInt64
    @FocusState private var focused: Bool

    init(field: MetaSignIn.Field, signIn: MetaSignIn, busy: Bool, focusRequested: Bool, dismissals: Int) {
        self.field = field
        self.signIn = signIn
        self.busy = busy
        self.focusRequested = focusRequested
        self.dismissals = dismissals
        _value = State(initialValue: field.text)
        _revision = State(initialValue: field.editRevision)
    }

    private var keyboard: UIKeyboardType {
        switch field.keyboard {
        case .number: return .numberPad
        case .email: return .emailAddress
        case .default: return .default
        }
    }

    private var binding: Binding<String> {
        Binding(get: { value }, set: { newValue in
            let limited = String(newValue.prefix(field.maxLength ?? 4096))
            guard limited != value else { return }
            value = limited
            revision &+= 1
            signIn.setText(field, limited, revision: revision)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !field.label.isEmpty {
                Text(field.label).font(.caption.weight(.medium)).foregroundStyle(Theme.textSecondary)
            }
            TextField(field.placeholder.isEmpty ? (field.isOneTimeCode ? "Code from your email" : field.label)
                                                : field.placeholder, text: binding)
                .textContentType(field.isOneTimeCode ? .oneTimeCode : .username)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(field.isOneTimeCode ? .title3.monospacedDigit() : .body)
                .foregroundStyle(Theme.ink)
                .tint(Theme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: 54)   // grows with Dynamic Type instead of clipping the text
                .fieldSurface(focused: focused)
                // The copper edge eases in and out with the keyboard instead of snapping.
                .animation(.easeOut(duration: 0.2), value: focused)
                .focused($focused)
                .disabled(!field.isEnabled || busy)
                .submitLabel(.continue)
                .onSubmit { if let submit = field.submit { signIn.perform(submit) } }
                .accessibilityLabel(field.label.isEmpty ? field.placeholder : field.label)
        }
        .onChange(of: focused) { _, on in if let action = on ? field.onFocus : field.onBlur { signIn.perform(action) } }
        .onChange(of: field.text) { _, newValue in
            if field.editRevision >= revision { value = newValue; revision = field.editRevision }
        }
        .onChange(of: focusRequested) { _, on in if on { focused = true } }
        .onChange(of: dismissals) { _, _ in focused = false }
        .onAppear { if focusRequested { focused = true } }
    }
}
