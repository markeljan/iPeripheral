@preconcurrency import AVFoundation
import Foundation
import Speech
import TonyLink

/// The phone's microphones → on-device speech-to-text (SpeechAnalyzer, iOS 26+). Reports every transcript update;
/// deciding what is a command is `Listener`'s job. Voice processing is on, so the phone's own TTS is mostly cancelled.
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
        mic.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            if let b = Self.convert(buffer, with: converter, to: format) { cont.yield(AnalyzerInput(buffer: b)) }
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
