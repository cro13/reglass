import Foundation
import ReGlassKit

/// Looks for glasses during setup: those iOS already holds (the usual case for Audio glasses) and any advertising.
@MainActor
final class GlassesDiscovery: ObservableObject {
    enum State: Equatable {
        case idle
        case searching
        case bluetoothOff
        case bluetoothDenied
        case failed(String)
    }

    @Published private(set) var found: [FoundGlasses] = []
    @Published private(set) var state: State = .idle
    /// True once a search has run long enough that "nothing found" deserves help text.
    @Published private(set) var searchedAWhile = false

    let finder = GlassesFinder()
    private var task: Task<Void, Never>?
    private var hintTask: Task<Void, Never>?

    func start() {
        stop()
        state = .searching
        searchedAWhile = false
        GlassesBluetooth.start()   // the first use shows iOS's Bluetooth permission prompt
        hintTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled else { return }
            self?.searchedAWhile = true
        }
        let finder = finder
        task = Task { [weak self] in
            do {
                for try await list in finder.scan() {
                    guard let self, !Task.isCancelled else { return }
                    found = list.map(FoundGlasses.init)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                switch error as? ReGlassError {
                case .bluetoothOff?: state = .bluetoothOff
                case .bluetoothDenied?: state = .bluetoothDenied
                case let kitError?: state = .failed(kitError.errorDescription ?? "Bluetooth isn't ready.")
                case nil: state = .failed("Bluetooth isn't ready. Check that it's on, then try again.")
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        hintTask?.cancel()
        hintTask = nil
        if state == .searching { state = .idle }
    }
}
