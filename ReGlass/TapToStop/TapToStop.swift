import Foundation
import ReGlassKit

/// Tap to stop: one tap on the glasses' touchpad stops the assistant mid-answer, or an announcement ReGlass is
/// playing. At any other moment ReGlass ignores taps, so the glasses' own play/pause keeps working exactly as Meta
/// designed it.
///
/// Taps reach ReGlass only when the glasses report them (`GlassesConnection.inputs()`). The glasses' own timers
/// already stop on a tap in their firmware, with no part for ReGlass. Nothing is sent to the glasses here.
///
/// What a tap stops is read at the moment it arrives (a reply speaking, an announcement playing, or nothing), so no
/// state can go stale. The activity log gets kinds, outcomes and timings only.
@MainActor
final class TapToStop {
    static let shared = TapToStop()

    /// What a tap would stop right now.
    enum Context: Equatable {
        case none
        /// The assistant's reply in this voice turn is playing.
        case speaking(AssistantTurnID)
        /// `AssistantController.announce` is playing something.
        case announcing
    }

    /// What ReGlass did with a touch.
    enum Outcome: Equatable {
        case stoppedReply
        case stoppedAnnouncement
        /// A tap with nothing of ReGlass's talking: left to the glasses (play/pause).
        case ignored
        /// A tap during a phone call: the call's business.
        case ignoredOnCall
        /// Not a single tap: ReGlass doesn't use it.
        case notUsed

        var logText: String {
            switch self {
            case .stoppedReply: return "stopped the reply"
            case .stoppedAnnouncement: return "stopped the announcement"
            case .ignored: return "ignored (nothing talking)"
            case .ignoredOnCall: return "ignored (on a call)"
            case .notUsed: return "not used"
            }
        }
    }

    private var inputs: Task<Void, Never>?
    private var generation = 0
    /// The announcement playing now, and how to stop it.
    private var announcement: (token: UUID, stop: () -> Void)?
    private var stoppedAnnouncements: Set<UUID> = []

    private var log: ActivityLog { GlassesController.shared.log }

    private init() {}

    // MARK: The connection

    /// Follows `connection`'s touches until it stops. Called by GlassesController for each live connection.
    func attach(_ connection: GlassesConnection) {
        inputs?.cancel()
        generation += 1
        let mine = generation
        let stream = connection.inputs()
        inputs = Task { [weak self] in
            for await event in stream {
                self?.received(event)
            }
            guard let self, self.generation == mine else { return }
            self.inputs = nil
        }
    }

    /// What a tap would stop right now.
    var context: Context {
        if let turn = AssistantController.shared.speakingTurn { return .speaking(turn) }
        if announcement != nil { return .announcing }
        return .none
    }

    private func received(_ event: GlassesInputEvent) {
        let outcome: Outcome
        if event.kind != .tap {
            outcome = .notUsed
        } else if FollowUps.onACall {
            outcome = .ignoredOnCall
        } else {
            switch context {
            case .speaking(let turn):
                outcome = AssistantController.shared.stopReplyByTap(turn) ? .stoppedReply : .ignored
            case .announcing:
                outcome = stopAnnouncement() ? .stoppedAnnouncement : .ignored
            case .none:
                outcome = .ignored
            }
        }
        log.add("Tap to stop: \(event.kind), \(outcome.logText)")
    }

    // MARK: Announcements

    /// Plays one announcement (`body`) so that a tap can stop it: the tap cancels `body`'s task, which ends the glasses'
    /// stream (or the iPhone's player) at once. Returns `body`'s result and whether a tap stopped it.
    func announcing<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> (result: T, tapped: Bool) {
        let token = UUID()
        let task = Task { @MainActor in await body() }
        announcement = (token, { task.cancel() })
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if announcement?.token == token { announcement = nil }
        return (result, stoppedAnnouncements.remove(token) != nil)
    }

    /// `announcing` for the iPhone's player: a tap stops playback, and that counts as played (seconds until the tap),
    /// not as an error.
    func announcing(onPhone body: @escaping @MainActor () async throws -> TimeInterval) async throws -> TimeInterval {
        let started = Date()
        let (result, tapped) = await announcing { () async -> Result<TimeInterval, Error> in
            do { return .success(try await body()) } catch { return .failure(error) }
        }
        if tapped { return Date().timeIntervalSince(started) }
        return try result.get()
    }

    private func stopAnnouncement() -> Bool {
        guard let current = announcement else { return false }
        announcement = nil
        stoppedAnnouncements.insert(current.token)
        current.stop()
        return true
    }
}
