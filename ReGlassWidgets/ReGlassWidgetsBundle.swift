import SwiftUI
import WidgetKit

// ReGlass's widget extension. It holds the Live Activity AlarmKit shows for ReGlass's alarms (the snooze countdown
// on the Lock Screen and in the Dynamic Island; AlarmKit needs it for any countdown, or iOS "may unexpectedly dismiss
// alarms and fail to alert").

@main
struct ReGlassWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ReGlassAlarmLiveActivity()
    }
}
