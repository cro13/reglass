import ReGlassKit
import SwiftUI

@main
struct ReGlassApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var glasses = GlassesController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(glasses)
                .modelContainer(ChatHistory.shared.container)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                glasses.sceneBecameActive()
            }
        }
    }
}

/// iOS can relaunch ReGlass in the background to hand back a Bluetooth connection (state restoration); that arrives
/// here before any screen exists, so Bluetooth and the live connection start from this point.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let restoring = (launchOptions?[.bluetoothCentrals] as? [String])?.contains(GlassesBluetooth.restoreIdentifier) == true
        let glasses = GlassesController.shared
        AppLifecycle.start()   // how the last run ended, and whether iOS woke ReGlass or it was opened
        // Only when iOS is restoring ReGlass or permission was already given: otherwise the first Bluetooth call
        // would show the permission prompt before onboarding asks for it.
        if restoring || GlassesBluetooth.isAuthorized {
            GlassesBluetooth.start()
        }
        if restoring { glasses.log.add("Relaunched by iOS to restore the Bluetooth connection") }
        glasses.connectIfReady()
        SpeechSettings.shared.start()   // speech recognition: local place names and the ElevenLabs key's status
        ReminderScheduler.shared.start()   // reminders go off on time even if the glasses never connect this run
        #if REGLASS_ICLOUD
        // iCloud sync (docs/ICLOUD.md): CloudKit tells ReGlass about notes and reminders changed on another device with
        // silent pushes, which may wake it in the background. The library opens now, so it can take them in.
        _ = LibraryStore.shared
        application.registerForRemoteNotifications()
        #endif
        return true
    }

    #if REGLASS_ICLOUD
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        GlassesController.shared.log.add("iCloud: registered for change notifications")
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        GlassesController.shared.log.add("iCloud: couldn't register for change notifications (error \((error as NSError).code))")
    }
    #endif

    func applicationWillTerminate(_ application: UIApplication) {
        AppLifecycle.closing()
    }
}
