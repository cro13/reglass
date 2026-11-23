import AVFoundation
import Foundation
import ReGlassAssistant

/// The iPhone's microphone for the real-time interpreter: `AVAudioEngine`'s input, converted to 16 kHz mono Int16
/// (what Scribe takes), handed on in order on a queue of its own.
///
/// The audio session must already be in its recording hold (`AssistantController.beginInterpreterMicrophone()`:
/// play-and-record, the built-in microphone, never a Bluetooth headset microphone). When the route or format changes
/// (AirPods connecting, say), iOS stops the engine; it's started again on the new input, and if that fails `onStop`
/// says why. Nothing here logs.
final class InterpreterMicrophone: @unchecked Sendable {
    enum Problem: Error {
        case noInput
        case noConverter
    }

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "reglass.interpreter.microphone", qos: .userInitiated)
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var onAudio: (@Sendable ([Int16]) -> Void)?
    private var onStop: (@Sendable (String) -> Void)?
    private var observer: NSObjectProtocol?
    private var running = false

    /// Starts listening. Throws iOS's own error (its code goes to the log), or a `Problem`.
    func start(onAudio: @escaping @Sendable ([Int16]) -> Void, onStop: @escaping @Sendable (String) -> Void) throws {
        lock.withLock {
            self.onAudio = onAudio
            self.onStop = onStop
        }
        try startEngine()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                          queue: nil) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        lock.withLock {
            running = false
            onAudio = nil
            onStop = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: Private

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Problem.noInput }
        guard let converter = AVAudioConverter(from: format, to: PCM.micFormat) else { throw Problem.noConverter }
        converter.downmix = true
        lock.withLock {
            self.converter = converter
            running = true
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.convert(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { running = false }
            throw error
        }
    }

    /// One buffer of the input, at its own rate, into 16 kHz mono Int16. The converter keeps its state between
    /// buffers (`.noDataNow`), so the resampling has no seams.
    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard let converter = lock.withLock({ running ? self.converter : nil }), buffer.frameLength > 0 else { return }
        let ratio = PCM.micRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: PCM.micFormat, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        let deliver = lock.withLock { onAudio }
        queue.async { deliver?(samples) }
    }

    private func configurationChanged() {
        queue.async { [weak self] in
            guard let self, self.lock.withLock({ self.running }) else { return }
            self.engine.stop()
            do {
                try self.startEngine()
            } catch {
                let stop = self.lock.withLock { self.onStop }
                stop?("it couldn't restart after a route change (\(Self.code(error)))")
            }
        }
    }

    /// iOS's error code, with its four letters when it has them ('!rec' is "can't start recording").
    static func code(_ error: Error) -> String {
        if let problem = error as? Problem { return problem == .noInput ? "no input" : "no converter" }
        let code = (error as NSError).code
        let bytes = withUnsafeBytes(of: UInt32(truncatingIfNeeded: code).bigEndian, Array.init)
        let letters = bytes.allSatisfy { (0x20...0x7E).contains($0) } ? String(bytes: bytes, encoding: .ascii) : nil
        return letters.map { "\(code) '\($0)'" } ?? "\(code)"
    }
}
