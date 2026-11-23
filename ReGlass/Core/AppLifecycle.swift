import Foundation
import os
import UIKit

/// Why ReGlass stopped answering with the phone locked, written to the activity log.
///
/// iOS ends a background app without warning when it needs memory; then nothing is listening when the glasses
/// wake. ReGlassKit's subscription to the glasses' PSM notifications lets iOS relaunch ReGlass straight away, and
/// these lines show whether that happened:
/// - each launch: opened on screen, or woken in the background by iOS;
/// - how the previous process ended: closed (swiped away), or ended without warning, with when it was last seen
///   and its memory then;
/// - memory on entering the background and every 5 minutes (iOS ends apps by this footprint).
@MainActor
enum AppLifecycle {
    private static let aliveKey = "reglass.lifecycle.alive"
    private static let closedKey = "reglass.lifecycle.closed"
    private static var started = false
    private static var shownSinceLaunch = false

    /// From `didFinishLaunching`, once.
    static func start() {
        guard !started else { return }
        started = true
        reportPrevious()
        watchLaunch()
        startHeartbeat()
    }

    /// From `applicationWillTerminate`: iOS calls it when the person swipes away a ReGlass that runs in the background.
    /// iOS doesn't relaunch a swiped-away app for Bluetooth, so ReGlass stays off until it's opened again.
    static func closing() {
        let at = Date().formatted(date: .omitted, time: .standard)
        UserDefaults.standard.set("closed at \(at) (swiped away, or iOS closed ReGlass with notice)", forKey: closedKey)
        UserDefaults.standard.removeObject(forKey: aliveKey)
        UserDefaults.standard.synchronize()
        log("Lifecycle: closing; the glasses won't reach ReGlass until it's opened again")
    }

    // MARK: Private

    private static func reportPrevious() {
        let defaults = UserDefaults.standard
        if let closed = defaults.string(forKey: closedKey) {
            log("Lifecycle: previous run \(closed)")
        } else if let alive = defaults.string(forKey: aliveKey) {
            log("Lifecycle: previous run ended without warning (iOS freeing memory, a crash or a restart); \(alive)")
        }
        defaults.removeObject(forKey: closedKey)
        defaults.removeObject(forKey: aliveKey)
        defaults.synchronize()   // an unwarned end a few seconds later mustn't bring the old notes back
    }

    /// Opened on screen, or woken by iOS (ReGlass has no background launch but Bluetooth). Logged once: on first
    /// becoming active, or after 5 s without it. In a SwiftUI app the launch state reads `.background` even when
    /// opened on screen, so this waits instead.
    private static func watchLaunch() {
        let launched = Date()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated {
                guard !shownSinceLaunch else { return }
                shownSinceLaunch = true
                log("Lifecycle: opened on screen " + String(format: "%.1f s after launch", Date().timeIntervalSince(launched)))
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !shownSinceLaunch else { return }
            shownSinceLaunch = true
            log("Lifecycle: woken in the background by iOS; \(memory())")
        }
    }

    /// Every minute, the alive note for the next launch; every 5 minutes and on entering the background, a log line.
    private static func startHeartbeat() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil,
                                               queue: .main) { _ in
            MainActor.assumeIsolated { log("Lifecycle: in the background; \(memory())") }
        }
        Task { @MainActor in
            var minute = 0
            while !Task.isCancelled {
                let line = "last seen \(Date().formatted(date: .omitted, time: .standard)) (\(state())); \(memory())"
                UserDefaults.standard.set(line, forKey: aliveKey)
                UserDefaults.standard.synchronize()   // kept even if the process ends without warning
                if minute > 0, minute % 5 == 0 { log("Lifecycle: \(line)") }
                minute += 1
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private static func state() -> String {
        switch UIApplication.shared.applicationState {
        case .active: return "on screen"
        case .inactive: return "inactive"
        default: return "background"
        }
    }

    /// What iOS counts against ReGlass (the footprint it ends apps by) and how much more ReGlass may use.
    static func memory() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let used = result == KERN_SUCCESS ? "\(info.phys_footprint / 1_048_576) MB" : "unknown"
        return "memory used \(used), \(os_proc_available_memory() / 1_048_576) MB more allowed"
    }

    private static func log(_ text: String) {
        GlassesController.shared.log.add(text)
    }
}
