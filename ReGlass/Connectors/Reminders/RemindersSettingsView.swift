import SwiftUI

/// The Lists connector's row inside its screen's Options section: one line on where the lists live now. Nothing to
/// choose: the lists are ReGlass's own, and Apple Reminders isn't used or copied from.
struct RemindersSettingsView: View {
    var body: some View {
        AssistantStatusLine(tone: .info,
                            text: "Your lists live in ReGlass, in the Reminders tab, sorted into Shopping, To-do and the rest. Apple Reminders stays as it is.")
            .padding(.vertical, 4)
    }
}
