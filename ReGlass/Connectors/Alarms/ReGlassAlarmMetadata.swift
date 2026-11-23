import ActivityKit
import AlarmKit
import AppIntents
import SwiftUI
import UIKit

// Shared by ReGlass and its widget extension (ReGlassWidgets): both targets compile this file (see project.yml). The
// Live Activity decodes each alarm's attributes with `ReGlassAlarmMetadata`; if the two targets disagreed about the
// type, the Lock Screen countdown would show blank, with no error.

/// What an alarm carries for its Live Activity. ReGlass makes two kinds: alarms (`AlarmService`) and the countdowns of
/// reminders due within the hour (`ReminderScheduler`).
struct ReGlassAlarmMetadata: AlarmMetadata {
    /// What the alarm is for ("gym"), as the owner said it; nil for a plain alarm.
    var label: String?
    /// A reminder's countdown: what it's for ("Check on the food"). Nil for an alarm. Optional, so alarms set before
    /// it existed still decode.
    var reminderTitle: String?

    /// A reminder's countdown rather than an alarm.
    var isReminder: Bool { reminderTitle != nil }
}

/// The ReGlass look for alarms, outside the app's Theme (the widget extension can't see it): the same warm paper and
/// copper. The Lock Screen follows Light and Dark with the dynamic tokens below (the same values as `Theme`); the Dynamic
/// Island is always dark, so there they resolve to their dark tones by themselves.
enum ReGlassAlarmLook {
    /// The icon's copper (#C96442), fixed, for what AlarmKit draws itself (the alert's Snooze words, the alarm's tint)
    /// and the Island's keyline: 5.4:1 on black and 3.9:1 on white, so it holds on either.
    static let accent = Color(red: 0xC9 / 255, green: 0x64 / 255, blue: 0x42 / 255)
    /// The same fixed copper, for AlarmKit's tint and the Island's keyline.
    static let accentFill = accent
    /// Copper for text and glyphs on the Lock Screen and in the Island (#9A582D; dark #D08C5E).
    static let accentText = dynamic(0x9A582D, 0xD08C5E)
    /// Copper for rings and bars (#AC6232; dark #CB7F4D).
    static let fill = dynamic(0xAC6232, 0xCB7F4D)
    /// The paper behind the Lock Screen's activity (#F4F2EC; dark #1F1E1C).
    static let canvas = dynamic(0xF4F2EC, 0x1F1E1C)
    /// Titles (#1F1E1C; dark #EDEBE4).
    static let ink = dynamic(0x1F1E1C, 0xEDEBE4)
    /// The line under a title (#5E5B54; dark #B8B4AA).
    static let secondary = dynamic(0x5E5B54, 0xB8B4AA)
    /// The faint track under a ring, and the Stop button's fill: ink at 10 % (dark 16 %).
    static let track = dynamic(0x1F1E1C, 0xEDEBE4, alpha: (0.10, 0.16))
    /// The canvas behind the Lock Screen activity, fixed for `colorScheme` (`activityBackgroundTint` takes a fixed
    /// colour more reliably than a dynamic one).
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0x1F / 255, green: 0x1E / 255, blue: 0x1C / 255)
                        : Color(red: 0xF4 / 255, green: 0xF2 / 255, blue: 0xEC / 255)
    }
    /// The system's own buttons on the Lock Screen activity, in `accentText`'s tone for `colorScheme`, fixed.
    static func actionText(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0xE0 / 255, green: 0x8A / 255, blue: 0x6C / 255)
                        : Color(red: 0xA9 / 255, green: 0x50 / 255, blue: 0x3A / 255)
    }
    @available(*, deprecated, renamed: "canvas", message: "The navy is gone: use ReGlassAlarmLook.canvas.")
    static var navy: Color { canvas }
    /// Snooze length, like the Clock app.
    static let snoozeMinutes = 9

    /// Light and dark as 0xRRGGBB, with an alpha for each.
    private static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: (CGFloat, CGFloat) = (1, 1)) -> Color {
        func color(_ rgb: UInt32, _ alpha: CGFloat) -> UIColor {
            UIColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255,
                    blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
        }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? color(dark, alpha.1) : color(light, alpha.0)
        })
    }
}

/// The Stop button on a snoozed alarm's Live Activity. Runs in ReGlass's process (iOS wakes it if needed): stops the
/// alarm, so a one-off is done and a repeating one waits for its next day.
struct StopReGlassAlarmIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop alarm"
    static let isDiscoverable = false

    @Parameter(title: "Alarm")
    var alarmID: String

    init() {}

    init(alarmID: UUID) {
        self.alarmID = alarmID.uuidString
    }

    func perform() async throws -> some IntentResult {
        if let id = UUID(uuidString: alarmID) {
            try? AlarmManager.shared.stop(id: id)
        }
        return .result()
    }
}
