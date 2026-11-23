import ReGlassAssistant
import SwiftUI

/// The Claude model the assistant answers with, saved in `ClaudeModel.chosen`.
@MainActor
final class ModelSettings: ObservableObject {
    static let shared = ModelSettings()

    @Published var model = ClaudeModel.chosen {
        didSet { ClaudeModel.chosen = model }
    }
}

/// Settings → Assistant → Model: which Claude model writes the answers. A conversation already going keeps its
/// model; the choice applies from the next one. The interpreter and typed notes' titles stay on Claude Haiku 5.5.
struct ModelView: View {
    @ObservedObject private var settings = ModelSettings.shared

    var body: some View {
        ZStack {
            ReGlassBackdrop(intensity: 0.6)
            List {
                Section {
                    ForEach(ClaudeModel.allCases) { model in
                        ProviderChoiceRow(title: model.displayName, subtitle: model.summary, onDevice: false,
                                          selected: settings.model == model) {
                            settings.model = model
                        }
                    }
                } header: {
                    Text("Claude model")
                } footer: {
                    Text("It applies from the next conversation. Anthropic bills each model at its own price, on "
                         + "your key. The live interpreter and the titles of typed notes always use Claude Haiku 5.5, "
                         + "the fastest.")
                }
                .listRowBackground(Theme.card)
            }
            .scrollContentBackground(.hidden)
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sensoryFeedback(.selection, trigger: settings.model)
    }
}

/// Settings → Assistant's row for the Claude model.
struct ModelSettingsRow: View {
    @ObservedObject private var settings = ModelSettings.shared

    var body: some View {
        NavigationLink {
            ModelView()
        } label: {
            InfoRow(title: "Model", value: settings.model.shortName, systemImage: "brain")
        }
    }
}
