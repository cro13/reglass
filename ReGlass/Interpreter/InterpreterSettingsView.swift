import SwiftUI
import UIKit

/// The interpreter's options inside Settings → Connectors → Interpreter: the Real time switch.
struct InterpreterSettingsView: View {
    @ObservedObject private var session = InterpreterSession.shared

    var body: some View {
        InterpreterRealTimeSwitch(session: session)
            .padding(.vertical, 4)
    }
}

/// Real time on or off, with what it means in one line. Turning it on (or showing it on, the first time) asks for the
/// iPhone's microphone, real time's fallback; if iOS says no, a plain line and a way to iPhone Settings.
struct InterpreterRealTimeSwitch: View {
    @ObservedObject var session: InterpreterSession
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(get: { session.realTime }, set: { on in
                Task { await session.setRealTime(on) }
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Real time")
                        .foregroundStyle(Theme.ink)
                    Text(session.realTime
                         ? "ReGlass keeps listening while it talks, and tells you each sentence as it's said. It uses your glasses' microphones, or your iPhone's if it has to."
                         : "ReGlass listens through your glasses, and you take turns with ReGlass.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            .tint(Theme.accentFill)
            .disabled(session.isRunning)
            if session.micDenied {
                AssistantStatusLine(tone: .warning,
                                    text: "ReGlass can't use your iPhone's microphone. Turn on Microphone for ReGlass in iPhone Settings.")
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                PillRow {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    } label: {
                        Label("Open iPhone Settings", systemImage: "gear")
                    }
                    .buttonStyle(CompactPillStyle())
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .assistantAnimation(session.realTime, reduceMotion: reduceMotion)
        .assistantAnimation(session.micDenied, reduceMotion: reduceMotion)
        .sensoryFeedback(.selection, trigger: session.realTime)
        .task { session.refreshMicrophonePermission() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            session.refreshMicrophonePermission()
        }
    }
}
