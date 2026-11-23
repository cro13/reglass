import AVFoundation
import Foundation

/// ReGlass's audio session for the assistant.
///
/// - **Keep-alive:** while the assistant is usable and the glasses are linked, a silent, mixable playback loop keeps
///   ReGlass running in the background, so a wake word with the iPhone locked still reaches it. It never takes the
///   microphone: the wearer's voice arrives over the glasses' own link.
/// - **Ducking:** while the voice speaks (through the glasses' link or the iPhone's audio route), the session switches
///   from mixing to ducking, so music dips, then back. iOS only lifts a duck when the session is deactivated, so each
///   switch briefly deactivates and reactivates it, never while ReGlass's own player is running.
/// - **Holds:** an announcement keeps the loop on while it plays, even without glasses.
/// - **Recording hold** (the real-time interpreter, ReGlass/Interpreter/): the iPhone's built-in microphone, with the
///   session switched to play-and-record until the hold ends. Still mixable, the keep-alive keeps running, and
///   never a Bluetooth headset microphone: no `.allowBluetooth` (HFP would put the glasses into call mode and stop
///   their music). `.allowBluetoothA2DP` keeps the glasses' music output where it is; A2DP carries no microphone, so
///   iOS records from the iPhone. While it holds, the duck isn't switched (that needs a deactivation, which would stop
///   the microphone): the interpreter keeps music dipped for its whole session.
///
/// **ReGlass must never become the Now Playing app.** The glasses' touchpad taps likely arrive as standard Bluetooth
/// media commands, which iOS sends to the Now Playing app (Music, or another music app). If the silent loop made ReGlass the Now
/// Playing app, those taps would come here instead of the music. So the session is always mixable
/// (`.mixWithOthers`, plus `.duckOthers` only while the voice speaks), and ReGlass never sets `MPNowPlayingInfoCenter`
/// info, never registers `MPRemoteCommandCenter` handlers and never calls `beginReceivingRemoteControlEvents`.
@MainActor
final class AssistantAudio {
    private let log: (String) -> Void
    private var keepAliveWanted = false
    /// `keepAliveOnSpeaker(_:)`: the glasses' 6-channel microphone is open, so the loop plays on the iPhone's speaker.
    private var speakerWanted = false
    /// The session is the speaker keep-alive's (play-and-record with no Bluetooth output).
    private var onSpeaker = false
    /// iOS refused the speaker session: the loop stays on the normal session until `keepAliveOnSpeaker(false)`.
    private var speakerRefused = false
    private var holds = 0
    private var ducks = 0
    private var ducking = false
    private var active = false
    /// Recording hold (the real-time interpreter).
    private var recordings = 0
    private var recording = false
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    /// Between an interruption's start and end (a call, Siri): the loop can't play, so the watchdog waits.
    private var interrupted = false
    /// Checks every 30 s that the loop still plays, since nothing else would notice it stopping.
    private var watchdog: Task<Void, Never>?
    private var reportedStopped = false

    init(log: @escaping (String) -> Void) {
        self.log = log
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                if type == .ended {
                    self.log("Assistant audio: interruption ended; re-arming")
                    self.interrupted = false
                    self.active = false
                    self.player = nil
                    self.apply()
                } else {
                    self.interrupted = true
                    self.log("Assistant audio: interrupted (call, Siri or another app)")
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log("Assistant audio: audio services were reset; re-arming")
                self.active = false
                self.player = nil
                self.apply()
            }
        })
    }

    var isKeepingAlive: Bool { player?.isPlaying == true }

    /// The assistant is usable and the glasses are linked: keep ReGlass alive in the background.
    func setKeepAlive(_ on: Bool) {
        guard keepAliveWanted != on else { return }
        keepAliveWanted = on
        log("Assistant audio: background keep-alive \(on ? "on" : "off")")
        apply()
    }

    /// Moves the silent loop to the iPhone's own speaker while the glasses' 6-channel microphone is open, and back
    /// after. When the glasses are the iPhone's audio output, iOS streams the loop's silence to them over classic
    /// Bluetooth (A2DP) the whole time, and that radio time comes out of the LE link that carries the six
    /// microphones: in tests, 23% of the frames arrived with the loop on the glasses and 100% with it off (the
    /// glasses drop what the link can't carry). The loop can't simply stop: iOS then suspends ReGlass in the
    /// background and nobody reads the microphone. So it plays on a play-and-record session with no Bluetooth
    /// output (`.defaultToSpeaker`, no `.allowBluetoothA2DP`, no HFP); its input is never started. If iOS refuses
    /// that session, the loop stays on the normal one, slower but alive. The recording hold wins over this.
    func keepAliveOnSpeaker(_ on: Bool) {
        guard speakerWanted != on else { return }
        speakerWanted = on
        speakerRefused = false
        if !on, onSpeaker { log("Assistant audio: background keep-alive back on the normal session") }
        apply()
    }

    /// Keeps the session and loop on until `endHold`.
    func beginHold() {
        holds += 1
        apply()
    }

    func endHold() {
        holds = max(0, holds - 1)
        apply()
    }

    /// Dips other audio until the matching `endDucking`.
    func beginDucking() {
        ducks += 1
        apply()
    }

    func endDucking() {
        ducks = max(0, ducks - 1)
        apply()
    }

    // MARK: Recording hold (the real-time interpreter, ReGlass/Interpreter/)

    /// Switches the session to play-and-record with the iPhone's built-in microphone, and dips other audio, until
    /// `endRecording()`. Nil when the iPhone's own microphone is the input; otherwise a log-safe reason, and nothing is
    /// held.
    func beginRecording() -> String? {
        recordings += 1
        ducks += 1
        apply()
        let session = AVAudioSession.sharedInstance()
        guard recording else {
            endRecording()
            return "the audio session couldn't switch to recording"
        }
        let input = session.currentRoute.inputs.first?.portType
        guard let input, input != .bluetoothHFP, input != .carAudio else {
            endRecording()
            return "the input is \(input?.rawValue ?? "missing")"
        }
        log("Assistant audio: recording with \(input == .builtInMic ? "the iPhone's microphone" : input.rawValue)")
        return nil
    }

    /// Ends `beginRecording()`'s hold: back to the plain playback session (the duck lifts with it).
    func endRecording() {
        guard recordings > 0 else { return }
        recordings -= 1
        ducks = max(0, ducks - 1)
        apply()
    }

    /// Re-establishes the session after a return to the foreground.
    func restore() {
        apply()
    }

    // MARK: Private

    private func apply() {
        let session = AVAudioSession.sharedInstance()
        let wantRecord = recordings > 0
        let wantLoop = keepAliveWanted || holds > 0 || wantRecord
        let wantActive = wantLoop || ducks > 0
        let wantSpeaker = speakerWanted && !speakerRefused && !wantRecord
        // Recording hold: the duck stays as it was while recording (switching it would stop the microphone).
        let wantDuck = wantRecord && recording ? ducking : ducks > 0
        guard wantActive else {
            player?.stop()
            player = nil
            if active {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                active = false
                if ducking { log("Assistant audio: other audio back up (session off)") }
                ducking = false
                recording = false
                onSpeaker = false
            }
            return
        }
        do {
            if !active || wantDuck != ducking || wantRecord != recording || wantSpeaker != onSpeaker {
                // Switching between mixing and ducking: let go first, so other apps come back up (or go down).
                let wasPlaying = player?.isPlaying == true
                player?.stop()
                if active { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
                // Always mixable (see above): never a session that would make ReGlass the Now Playing app.
                if wantRecord {
                    // Recording hold: never `.allowBluetooth` (HFP); see above. `.defaultToSpeaker` keeps other apps'
                    // sound on the speaker rather than the earpiece when no headphones are connected.
                    var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker]
                    if wantDuck { options.insert(.duckOthers) }
                    try session.setCategory(.playAndRecord, mode: .default, options: options)
                } else if wantSpeaker {
                    // Speaker keep-alive: play-and-record only to get a session whose output can't be the glasses
                    // (no `.allowBluetoothA2DP`, no HFP). Nothing starts its input.
                    var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker]
                    if wantDuck { options.insert(.duckOthers) }
                    try session.setCategory(.playAndRecord, mode: .default, options: options)
                } else {
                    try session.setCategory(.playback, mode: .default,
                                            options: wantDuck ? [.mixWithOthers, .duckOthers] : [.mixWithOthers])
                }
                recording = false
                onSpeaker = false
                try session.setActive(true)
                active = true
                if wantDuck != ducking {
                    // A dip that never lifts leaves other audio at half volume: say each change.
                    let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")
                    log("Assistant audio: other audio \(wantDuck ? "dipped" : "back up") (\(ducks) asking; output: "
                        + "\(outputs.isEmpty ? "none" : outputs), iPhone volume \(Int((session.outputVolume * 100).rounded()))%)")
                }
                ducking = wantDuck
                if wantSpeaker {
                    onSpeaker = true
                    let outputs = session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: ", ")
                    log("Assistant audio: background keep-alive on the iPhone's speaker for the 6-channel microphone "
                        + "(output: \(outputs.isEmpty ? "none" : outputs))")
                }
                if wantRecord {
                    if let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                        try? session.setPreferredInput(mic)
                    }
                    recording = true
                }
                if wasPlaying, wantLoop { player?.play() }
            }
            if wantLoop {
                if player == nil {
                    player = try AVAudioPlayer(data: Self.silence)
                    player?.numberOfLoops = -1
                }
                if player?.isPlaying != true, player?.play() != true {
                    log("Assistant audio: the background keep-alive didn't start")
                }
                watch()
            } else {
                player?.stop()
                player = nil
            }
        } catch {
            log("Assistant audio: session couldn't be set (\((error as NSError).code))")
            if wantRecord, !recording {
                // Recording hold refused (iOS may not start recording in the background): the caller lets go.
                active = false
            }
            if wantSpeaker, !onSpeaker {
                // Speaker session refused: back to the normal one, so ReGlass stays alive (slower microphone).
                log("Assistant audio: the speaker keep-alive was refused; keeping the normal one")
                speakerRefused = true
                active = false
                apply()
                return
            }
            watch()
        }
    }

    /// While the loop is wanted, restarts it if it stopped without an interruption saying so (if it stays stopped,
    /// iOS suspends ReGlass and the wake word finds nobody). Logs the stop and the recovery once each.
    private func watch() {
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                guard self.keepAliveWanted || self.holds > 0 else {
                    self.watchdog = nil
                    return
                }
                if self.player?.isPlaying == true {
                    if self.reportedStopped {
                        self.reportedStopped = false
                        self.log("Assistant audio: the background keep-alive is running again")
                    }
                    continue
                }
                // Recording hold: the microphone keeps ReGlass running; a restart would stop it.
                guard !self.interrupted, !self.recording else { continue }
                if !self.reportedStopped {
                    self.reportedStopped = true
                    self.log("Assistant audio: the background keep-alive had stopped; restarting it")
                }
                self.active = false
                self.player = nil
                self.apply()
            }
        }
    }

    /// One second of 8 kHz mono silence as WAV, looped.
    private static let silence: Data = {
        let rate = 8_000
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let size = UInt32(rate * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + size)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(size)
        data.append(Data(count: Int(size)))
        return data
    }()
}
