import SwiftUI

/// Weather's options, as rows inside the connector screen's Options section: location access (with the step up to
/// Always for the pocket), the home city used when ReGlass can't tell where you are, and the forecast credit.
struct WeatherSettingsView: View {
    @ObservedObject private var location = LocationService.shared
    @ObservedObject private var home = HomeCityStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var askingLocation = false

    var body: some View {
        locationRow
            .assistantAnimation(location.access, reduceMotion: reduceMotion)
            .assistantAnimation(askingLocation, reduceMotion: reduceMotion)
        HomeCityRow()
        creditRow
    }

    // MARK: Location

    private var locationRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            InfoRow(title: "Location", value: location.access.label, systemImage: "location")
            Group {
                if askingLocation {
                    AssistantStatusLine(tone: .working, text: "Waiting for your answer…")
                } else {
                    AssistantStatusLine(tone: hint.tone, text: hint.text)
                }
            }
            .transition(.opacity)
            if let action = locationAction, !askingLocation {
                PillRow {
                    Button {
                        askingLocation = true
                        Task {
                            await location.setUp()
                            ConnectorRegistry.shared.refresh()
                            askingLocation = false
                        }
                    } label: {
                        Label(action, systemImage: location.access == .whileUsing ? "location.fill" : "location")
                    }
                    .buttonStyle(CompactPillStyle(kind: location.access == .notAsked ? .prominent : .glass))
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    private var hint: (tone: AssistantStatusLine.Tone, text: String) {
        switch location.access {
        case .always:
            return (.good, "Works with your iPhone locked in your pocket.")
        case .whileUsing:
            return (.info, "Works while ReGlass is open. Choose Always so ReGlass also knows where you are with your iPhone locked; until then it uses where you last were, or your home city.")
        case .notAsked:
            return (.info, "Allow location so ReGlass answers for where you are. Always works best: most questions come while your iPhone is locked.")
        case .denied:
            return (.quiet, "Location is off for ReGlass, so it uses your home city. Turn it on in iPhone Settings, ideally Always.")
        case .restricted:
            return (.quiet, "Location isn't allowed on this iPhone, so ReGlass uses your home city.")
        }
    }

    private var locationAction: String? {
        switch location.access {
        case .notAsked: return "Allow Location"
        case .whileUsing: return "Allow Always"
        case .denied, .restricted: return "Open iPhone Settings"
        case .always: return nil
        }
    }

    // MARK: Credit

    private var creditRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if WeatherSources.usesAppleWeather { AppleWeatherCredit() }
            if WeatherSources.usesOpenMeteo, let url = URL(string: "https://open-meteo.com/") {
                Link(destination: url) {
                    Label("Weather Data by Open-Meteo.com", systemImage: "arrow.up.right.square")
                        .font(.footnote)
                }
                .tint(Theme.accent)
            }
        }
        .padding(.vertical, 2)
    }
}

/// The home city: shown, set, changed or removed in place. Typing a town looks it up once and saves the match.
private struct HomeCityRow: View {
    private enum Mode: Equatable {
        case idle, editing
    }

    @ObservedObject private var home = HomeCityStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24

    @State private var mode: Mode = .idle
    @State private var draft = ""
    @State private var state: LookupState = .idle
    @State private var saved = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Group {
                switch mode {
                case .idle: idle
                case .editing: editor
                }
            }
            .padding(.leading, typeSize.isAccessibilitySize ? 0 : iconColumn + 12)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
        }
        .padding(.vertical, 6)
        .assistantAnimation(mode, reduceMotion: reduceMotion)
        .assistantAnimation(state, reduceMotion: reduceMotion)
        .assistantAnimation(home.city, reduceMotion: reduceMotion)
        .sensoryFeedback(.success, trigger: saved)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            RowSymbol(name: "house")
            Text("Home city")
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 12)
            Text(home.city?.shortName ?? "Not set")
                .font(.callout)
                .foregroundStyle(home.city == nil ? Theme.textTertiary : Theme.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .contentTransition(.opacity)
        }
        .accessibilityElement(children: .combine)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .finished = state { state.statusLine }
            Text(home.city.map { "ReGlass uses \($0.name) when it can't tell where you are." }
                 ?? "ReGlass uses it when it can't tell where you are, for example with location off.")
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PillRow {
                if home.city == nil {
                    Button { begin() } label: { Label("Set Home City", systemImage: "plus") }
                        .buttonStyle(CompactPillStyle(kind: .prominent))
                } else {
                    Button("Change") { begin() }
                        .buttonStyle(CompactPillStyle())
                    Button("Remove") {
                        home.remove()
                        state = .idle
                        ConnectorRegistry.shared.refresh()
                    }
                    .buttonStyle(CompactPillStyle(kind: .destructive))
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Town or city", text: $draft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .textContentType(.addressCity)
                .focused($fieldFocused)
                .submitLabel(.done)
                .onSubmit(save)
                .padding(.horizontal, 14)
                .frame(minHeight: 50)
                .fieldSurface(focused: fieldFocused)
                .animation(.easeOut(duration: 0.2), value: fieldFocused)
                .disabled(state.isBusy)
            if state == .idle {
                Text("Add the country if the name is common, like Cambridge, UK.")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                state.statusLine
            }
            PillRow {
                Button("Save", action: save)
                    .buttonStyle(CompactPillStyle(kind: .prominent))
                    .disabled(cleanedDraft.isEmpty || state.isBusy)
                Button("Cancel") { end() }
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .onChange(of: draft) { _, _ in if !state.isBusy { state = .idle } }
    }

    private var cleanedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func begin() {
        draft = ""
        state = .idle
        mode = .editing
        fieldFocused = true
    }

    private func end() {
        fieldFocused = false
        mode = .idle
    }

    private func save() {
        let text = cleanedDraft
        guard !text.isEmpty, !state.isBusy else { return }
        state = .working("Looking up \(text)…")
        Task {
            do {
                let place = try await PlaceResolver.shared.place(named: text)
                home.save(place)
                ConnectorRegistry.shared.refresh()
                state = .finished("Saved \(place.name).", success: true)
                saved += 1
                end()
            } catch PlaceResolver.Failure.notFound {
                state = .finished("Couldn't find that place. Try adding the country.", success: false)
            } catch {
                state = .finished("Couldn't look it up just now. Check the connection and try again.", success: false)
            }
        }
    }
}
