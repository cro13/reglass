import Foundation
import ReGlassAssistant

/// The ElevenLabs voice as a reminder's own iPhone alert sound, when one is set up (`VoiceSettings`). When the
/// scheduler places a reminder's alert, the voice's line ("Hey, your reminder to check on the food is up.") is
/// recorded once into Library/Sounds, where AlarmKit and notifications both look for a custom sound, so the iPhone
/// rings with that voice even while iOS has ReGlass asleep.
/// An AlarmKit countdown plays it through silent mode and Focus, as the Clock's alarms do; a notification follows
/// the ring switch. Either plays at the iPhone's alarm volume, which apps can't set, so the file starts soft: the
/// line is said quietly, then louder, then as loud as the voice said it (`gains`).
///
/// No ElevenLabs voice or key, no network, or slower than `timeout`: nil, and the alert keeps the system sound. The
/// ElevenLabs voice only, never Apple's voice in its place. Files are named by reminder and line, so a renamed reminder gets a new one;
/// `keepOnly` clears out the rest. The words are in the audio, never in the log.
@MainActor
enum ReminderVoice {
    private static let prefix = "reglass-reminder-"
    /// In every new file's name, so an alert placed after the soft start came in never reuses a file without it.
    private static let version = "soft"
    /// Silence after each time the line is said, so the next one comes after a breath.
    private static let pause: TimeInterval = 2.5
    /// How loud each time the line is said, against the voice's own level: soft, louder, then full, and full once more
    /// when there's room, so an alarm repeating its sound spends longer at full strength.
    private static let ramp: [Float] = [0.2, 0.45, 1]
    private static let mostRounds = 4
    /// iOS plays the system sound instead of a custom one longer than this.
    private static let longest: TimeInterval = 29
    /// Recording takes longer than this: the alert goes out with the system sound.
    nonisolated static let timeout: TimeInterval = 8

    nonisolated private static let voice = ElevenLabsVoice(fallback: nil)

    /// The sound's file name in Library/Sounds, recorded now if it isn't there yet; nil when it can't be.
    static func sound(for line: String, reminder: UUID) async -> String? {
        let name = prefix + reminder.uuidString + "-" + fingerprint(line) + "-" + version + ".wav"
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return name }
        guard VoiceSettings.elevenLabsChosen, let key = try? KeyStore.shared.read(.elevenLabs), !key.isEmpty else { return nil }
        guard let samples = await record(line), !samples.isEmpty, let gains = gains(fitting: samples.count) else {
            log("Reminders: the voice's alert sound couldn't be made; the system sound instead")
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try wav(samples, gains: gains)
                .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return name
        } catch {
            log("Reminders: couldn't save ReGlass's alert sound (\(type(of: error)))")
            return nil
        }
    }

    /// Deletes the reminder sounds not in `names` (their alerts are gone).
    static func keepOnly(_ names: Set<String>) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        for file in files where file.hasPrefix(prefix) && !names.contains(file) {
            try? manager.removeItem(at: directory.appending(path: file, directoryHint: .notDirectory))
        }
    }

    // MARK: Pieces

    private static var directory: URL {
        URL.libraryDirectory.appending(path: "Sounds", directoryHint: .isDirectory)
    }

    /// The voice saying `line`, whole, within `timeout`; nil if it can't.
    private static func record(_ line: String) async -> [Int16]? {
        await withTaskGroup(of: [Int16]?.self) { group in
            group.addTask {
                var samples: [Int16] = []
                do {
                    for try await chunk in voice.speak(line, onRoute: { _ in }) { samples += chunk }
                    return samples
                } catch {
                    return nil
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// How loud each time a line of `count` samples is said, as many times as fit in `longest`: a line too long for
    /// the whole ramp leaves out the softest first, never the full one. Nil when even once doesn't fit.
    private static func gains(fitting count: Int) -> [Float]? {
        let rounds = min(mostRounds, Int(longest / (PCM.replySeconds(count) + pause)))
        guard rounds > 0 else { return nil }
        guard rounds > ramp.count else { return Array(ramp.suffix(rounds)) }
        return ramp + Array(repeating: 1, count: rounds - ramp.count)
    }

    /// 24 kHz mono 16-bit WAV: the line once per gain, at that loudness, each followed by `pause` of silence.
    private static func wav(_ samples: [Int16], gains: [Float]) -> Data {
        let rate = Int(PCM.replyRate)
        let silence = [Int16](repeating: 0, count: Int(pause * PCM.replyRate))
        let all = gains.flatMap { gain in
            samples.map { Int16(max(-32768, min(32767, (Float($0) * gain).rounded()))) } + silence
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let size = UInt32(all.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + size)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(size)
        for sample in all { append(sample) }
        return data
    }

    /// A short, stable name for a line (FNV-1a), so a changed line gets a new file.
    private static func fingerprint(_ line: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in line.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    private static func log(_ line: String) {
        GlassesController.shared.log.add(line)
    }
}
