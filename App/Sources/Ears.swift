@preconcurrency import AVFoundation
import Foundation
@preconcurrency import SoundAnalysis
import Speech
import TonyLink

/// The phone's microphones → on-device speech-to-text (SpeechAnalyzer, iOS 26+). Reports every transcript update;
/// deciding what is a command is `Listener`'s job. Voice processing is on, so the phone's own TTS is mostly cancelled.
/// The same audio also goes to Apple's built-in sound classifier (~300 sounds) for `onSound` events.
@available(iOS 26, *)
final class Ears: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case denied, unsupportedLocale, noFormat
        var description: String {
            switch self {
            case .denied: "microphone permission denied"
            case .unsupportedLocale: "on-device speech recognition doesn't support this language"
            case .noFormat: "no audio format for the speech model"
            }
        }
    }

    /// (text, isFinal). Called on an arbitrary task.
    var onText: (@Sendable (String, Bool) -> Void)?
    /// (sound label, confidence) for the sounds worth telling the robot about. Called on the sound queue.
    var onSound: (@Sendable (String, Double) -> Void)?

    /// Sounds reported as events. Speech, music and silence are left out: they are constant and not events.
    static let soundsOfInterest: Set<String> = [
        "clapping", "finger_snapping", "applause", "cheering", "laughter", "baby_laughter", "shout", "yell",
        "screaming", "crying_sobbing", "baby_crying", "whistling", "door_bell", "knock", "door_slam", "dog_bark",
        "dog_growl", "cat_meow", "smoke_detector", "alarm_clock", "siren", "police_siren", "ambulance_siren",
        "fire_engine_siren", "glass_breaking", "telephone_bell_ringing", "ringtone", "thump_thud", "boom",
        "gunshot_gunfire", "fireworks", "basketball_bounce", "beep",
    ]
    private let soundQueue = DispatchQueue(label: "sounds")
    private var sounds: SNAudioStreamAnalyzer?
    private var soundObserver: SoundObserver?

    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private(set) var running = false
    private var vocabulary: [String] = []

    /// Bias recognition toward these words and phrases (skill names aren't all everyday English). Kept for `start`
    /// if the analyzer isn't running yet.
    func setVocabulary(_ words: [String]) async {
        vocabulary = words
        let ctx = AnalysisContext()
        ctx.contextualStrings[.general] = Array(Set(Listener.baseVocabulary + words))
        try? await analyzer?.setContext(ctx)
    }

    func start() async throws {
        guard !running else { return }
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.denied }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw Failure.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()  // one-time model download
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw Failure.noFormat
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        input = cont

        let onText = onText
        results = Task {
            do {
                for try await r in transcriber.results {
                    onText?(String(r.text.characters), r.isFinal)
                }
            } catch {
                NSLog("ears: results ended: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        await setVocabulary(vocabulary)

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let mic = engine.inputNode
        try? mic.setVoiceProcessingEnabled(true)  // echo cancellation: don't transcribe our own voice
        let micFormat = mic.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: micFormat, to: format) else { throw Failure.noFormat }
        let sounds = SNAudioStreamAnalyzer(format: micFormat)
        if let req = try? SNClassifySoundRequest(classifierIdentifier: .version1), let onSound {
            req.windowDuration = CMTime(seconds: 1, preferredTimescale: 48_000)
            req.overlapFactor = 0.5
            let obs = SoundObserver(onSound)
            try? sounds.add(req, withObserver: obs)
            soundObserver = obs
        }
        self.sounds = sounds
        let soundQueue = soundQueue
        mic.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, when in
            if let b = Self.convert(buffer, with: converter, to: format) { cont.yield(AnalyzerInput(buffer: b)) }
            soundQueue.async { sounds.analyze(buffer, atAudioFramePosition: when.sampleTime) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        results?.cancel()
        running = false
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with c: AVAudioConverter, to f: AVAudioFormat)
        -> AVAudioPCMBuffer?
    {
        if buffer.format == f { return buffer }
        let ratio = f.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
        var error: NSError?
        c.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}

/// Turns sound-classifier results into `onSound` calls: confident (> 0.7), interesting, at most every 3 s per sound.
@available(iOS 26, *)
private final class SoundObserver: NSObject, SNResultsObserving, @unchecked Sendable {
    private let report: @Sendable (String, Double) -> Void
    private var last: [String: Date] = [:]

    init(_ report: @escaping @Sendable (String, Double) -> Void) { self.report = report }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult, let top = r.classifications.first, top.confidence > 0.7,
            Ears.soundsOfInterest.contains(top.identifier)
        else { return }
        let now = Date()
        if let t = last[top.identifier], now.timeIntervalSince(t) < 3 { return }
        last[top.identifier] = now
        report(top.identifier, (top.confidence * 100).rounded() / 100)
    }
}
