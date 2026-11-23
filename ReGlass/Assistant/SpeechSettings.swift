import CoreLocation
import Foundation
import ReGlassAssistant
import UIKit

/// The voice and speech recognition settings, and what ReGlass knows about the ElevenLabs key's speech to text, for
/// Settings → Assistant → Voice and speech and the Keys screen. The voices and recognizers themselves, and the lists of
/// them, are in ReGlassAssistant (`VoiceProvider`, `SpeechProvider`).
@MainActor
final class SpeechSettings: ObservableObject {
    static let shared = SpeechSettings()

    /// The voice that speaks the replies (`VoiceSettings.provider`), from the next reply.
    @Published var voice: VoiceProvider {
        didSet {
            guard voice != oldValue else { return }
            VoiceSettings.provider = voice
            AssistantController.shared.resetVoiceTest()
        }
    }
    /// ElevenLabs' voice ID as saved (letters and digits only); empty when none is set.
    @Published private(set) var elevenLabsVoiceID: String
    /// The recognizer that writes down what the wearer says (`SpeechRecognition.choice`), from the next request.
    @Published var choice: SpeechProvider {
        didSet {
            guard choice != oldValue else { return }
            SpeechRecognition.choice = choice
            if choice == .elevenLabs { Task { await checkIfNeeded() } }
        }
    }
    @Published private(set) var status: SpeechRecognition.CloudStatus
    @Published private(set) var checking = false

    static let keyCannotTranscribe = "Your ElevenLabs key can't transcribe yet. Turn on Speech to Text for it at elevenlabs.io."
    static let termsNotAccepted = "ElevenLabs needs you to accept its speech to text terms once. Open Speech to Text at elevenlabs.io."

    private var lastCheck: Date?
    private var started = false
    private var activeObserver: NSObjectProtocol?

    private init() {
        voice = VoiceSettings.provider
        elevenLabsVoiceID = VoiceSettings.elevenLabsVoiceID
        choice = SpeechRecognition.choice
        status = SpeechRecognition.cloudStatus
    }

    /// Saves a pasted or typed voice ID (anything but letters and digits is dropped).
    func setElevenLabsVoiceID(_ value: String) {
        VoiceSettings.elevenLabsVoiceID = value
        let saved = VoiceSettings.elevenLabsVoiceID
        guard saved != elevenLabsVoiceID else { return }
        elevenLabsVoiceID = saved
        AssistantController.shared.resetVoiceTest()
    }

    /// Once at launch: hands ReGlassAssistant the local place names and follows the key's status.
    func start() {
        guard !started else { return }
        started = true
        SpeechRecognition.setKeytermProvider { LocalPlaceWords.current }
        SpeechRecognition.setStatusObserver { status in
            Task { @MainActor in SpeechSettings.shared.status = status }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LocalPlaceWords.refreshIfStale() }
        }
        // Not during launch itself: the place names can wait a few seconds.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            LocalPlaceWords.refreshIfStale()
        }
    }

    /// Beside "Voice and speech" in Settings: "iPhone", the cloud providers chosen, or what's left to do.
    var summary: String {
        if voice.missing != nil || choice.missing != nil || (choice == .elevenLabs && keyProblem != nil) {
            return "Finish setup"
        }
        switch (voice == .iPhone, choice == .iPhone) {
        case (true, true): return "iPhone"
        case (false, true): return voice.title
        case (true, false): return choice.title
        case (false, false): return voice.id == choice.id ? voice.title : "\(voice.title), \(choice.title)"
        }
    }

    /// The sentence for a key problem only the owner can fix, if there is one.
    var keyProblem: String? {
        switch status {
        case .keyCannotTranscribe: return Self.keyCannotTranscribe
        case .termsNotAccepted: return Self.termsNotAccepted
        default: return nil
        }
    }

    /// Asks ElevenLabs about the key when the answer could change what's shown: ElevenLabs chosen, not known to work
    /// yet, and not asked in the last 15 s.
    func checkIfNeeded() async {
        guard choice == .elevenLabs, status != .works, !checking else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < 15 { return }
        await check()
    }

    func check() async {
        guard !checking else { return }
        checking = true
        lastCheck = Date()
        if let result = await SpeechRecognition.checkKey() { status = result }
        checking = false
    }

    /// The ElevenLabs key was saved, replaced or removed.
    func keyChanged() {
        SpeechRecognition.keyChanged()
        status = SpeechRecognition.cloudStatus
        lastCheck = nil
        Task { await checkIfNeeded() }
    }
}

/// Names of the towns around the iPhone's last known position, for ElevenLabs to expect ("Versailles", "Boulogne").
///
/// - Worked out in the background with MapKit: the town at the position and at twelve points 3.5 and 8 km around it,
///   plus the weather's home city. It runs a few seconds after launch and whenever ReGlass comes to the foreground,
///   but only when the area has changed (3 km away or 12 hours later), and is kept on this iPhone between launches.
/// - A request only ever reads the cached list (`current`): never a lookup in the turn's path.
/// - Privacy: the names go to ElevenLabs with each request (that's what they're for); the log only gets a count.
enum LocalPlaceWords {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: [String]?
    private static let wordsKey = "reglass.assistant.speechPlaceWords"
    /// Where and when the list was made, rounded to about a kilometre.
    private static let areaKey = "reglass.assistant.speechPlaceArea"
    @MainActor private static var refreshing = false

    /// The list for the next request.
    static var current: [String] {
        lock.withLock {
            if let cached { return cached }
            let stored = UserDefaults.standard.stringArray(forKey: wordsKey) ?? []
            cached = stored
            return stored
        }
    }

    /// Only while ElevenLabs Scribe is the chosen recognizer, the one thing that uses these names: otherwise the
    /// iPhone's location never goes to the geocoder for them.
    @MainActor static func refreshIfStale() {
        guard SpeechRecognition.choice == .elevenLabs, !refreshing, let known = LocationService.shared.lastKnownLocation, known.age < 7 * 86_400 else { return }
        let here = known.location
        if let area = UserDefaults.standard.array(forKey: areaKey) as? [Double], area.count == 3,
           Date().timeIntervalSince1970 - area[2] < 12 * 3_600,
           CLLocation(latitude: area[0], longitude: area[1]).distance(from: here) < 3_000 {
            return
        }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            let started = Date()
            var names: [String] = []
            func add(_ name: String?) {
                guard let name, !name.isEmpty,
                      !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
                names.append(name)
            }
            for point in [here] + ring(around: here, radius: 3_500) + ring(around: here, radius: 8_000) {
                add(await PlaceResolver.shared.place(near: point)?.shortName)
            }
            add(HomeCityStore.shared.city?.shortName)
            guard !names.isEmpty else {
                GlassesController.shared.log.add("Speech: no nearby place names found for ElevenLabs")
                return
            }
            let words = Array(names.prefix(16))
            UserDefaults.standard.set(words, forKey: wordsKey)
            let round = { (value: Double) in (value * 100).rounded() / 100 }
            UserDefaults.standard.set([round(here.coordinate.latitude), round(here.coordinate.longitude),
                                       Date().timeIntervalSince1970], forKey: areaKey)
            lock.withLock { cached = words }
            GlassesController.shared.log.add("Speech: \(names.count) nearby place names ready for ElevenLabs "
                                             + "(\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        }
    }

    /// Six points `radius` metres around `center`.
    private static func ring(around center: CLLocation, radius: Double) -> [CLLocation] {
        let latitude = center.coordinate.latitude
        let longitude = center.coordinate.longitude
        let metresPerDegree = 111_320.0
        return stride(from: 0.0, to: 360.0, by: 60.0).map { degrees in
            let bearing = degrees * .pi / 180
            let north = radius * cos(bearing) / metresPerDegree
            let east = radius * sin(bearing) / (metresPerDegree * max(0.2, cos(latitude * .pi / 180)))
            return CLLocation(latitude: latitude + north, longitude: longitude + east)
        }
    }
}
