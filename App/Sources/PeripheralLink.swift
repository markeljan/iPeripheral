import AVFoundation
import Foundation
import Observation
import TonyLink
import UIKit

/// The app's whole job: stay connected to the bridge, answer its requests with the phone's senses, show a face.
@MainActor @Observable
final class PeripheralLink {
    enum Phase: Equatable {
        case searching
        case connecting(String)
        case needsCode(error: String?)
        case connected(String)
    }

    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let fallbackURL = URL(string: "ws://tonypi.local:8766/")!

    private(set) var phase: Phase = .searching
    private(set) var robot: RobotState?
    private(set) var lastHeard: String?
    private(set) var lastSaid: String?
    private(set) var requestsServed = 0
    private(set) var lastError: String?
    private var faceOverride: (face: Face, until: Date)?
    private var agentFace: Face = .idle

    /// Set in the debug overlay when Bonjour can't find the bridge (e.g. ws://192.0.2.1:8766/).
    var manualURL: String {
        get { UserDefaults.standard.string(forKey: "bridgeURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "bridgeURL") }
    }

    private let camera = Camera()
    private let voice = Voice()
    private var conn: LinkConnection?
    private var loop: Task<Void, Never>?

    var face: Face {
        if let o = faceOverride, o.until > Date() { return o.face }
        guard case .connected = phase else { return .offline }
        if voice.speaking { return .speaking }
        if robot?.asleep == true { return .asleep }
        return agentFace
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { await run() }
        Task { try? await camera.start() }
    }

    // ---- connection loop ----------------------------------------------------------------------------------------

    private func run() async {
        while !Task.isCancelled {
            phase = .searching
            let url: URL
            if let manual = URL(string: manualURL), manual.scheme == "ws" {
                url = manual
            } else {
                url = await BridgeBrowser.find(timeout: 4) ?? Self.fallbackURL
            }
            phase = .connecting(url.absoluteString)
            await session(url)
            conn = nil
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func session(_ url: URL) async {
        let c = LinkConnection(url: url)
        conn = c
        c.open()
        let device = UIDevice.current.name
        do {
            if let token = Keychain.token {
                try await c.send(.hello(token: token, device: device, app: Self.appVersion))
            } else {
                try await c.send(.pairRequest(device: device))
            }
            let status = Task { await statusLoop(c) }
            defer { status.cancel() }
            for try await msg in c.messages() {
                await handle(msg, on: c, url: url)
            }
        } catch {
            lastError = "\(error.localizedDescription)"
        }
        c.close()
    }

    private func handle(_ msg: Incoming, on c: LinkConnection, url: URL) async {
        switch msg {
        case .welcome(_, _, let token):
            if let token { Keychain.token = token }
            phase = .connected(url.host() ?? url.absoluteString)
            lastError = nil
        case .pairCodeSent:
            phase = .needsCode(error: nil)
        case .error(let e, let triesLeft):
            lastError = e
            if e == "bad token" { Keychain.token = nil }  // paired with a reset bridge: pair again
            if case .needsCode = phase, triesLeft != nil { phase = .needsCode(error: e) }
        case .robotState(let s):
            robot = s
        case .robotEvent(let ev):
            if ev["event"]?.string == "warn" { faceOverride = (.warn, Date().addingTimeInterval(5)) }
        case .agentEvent(let ev):
            agentEvent(ev)
        case .request(let rid, let op, let args):
            requestsServed += 1
            await answer(rid: rid, op: op, args: args, on: c)
        case .unknown:
            break
        }
    }

    private func agentEvent(_ ev: JSONValue) {
        switch ev["type"]?.string {
        case "heard":
            lastHeard = ev["text"]?.string
            agentFace = .thinking
        case "say":
            lastSaid = ev["text"]?.string
            agentFace = .idle
        case "done":
            agentFace = .idle
        default:
            break
        }
    }

    // ---- requests from the bridge -------------------------------------------------------------------------------

    private func answer(rid: Int, op: String, args: [String: JSONValue], on c: LinkConnection) async {
        do {
            switch op {
            case "snapshot":
                let maxSide = args["max_side"]?.int ?? 1280
                let quality = args["quality"]?.double ?? 0.7
                let cam = camera
                let shot = try await Task.detached { try cam.snapshot(maxSide: maxSide, quality: quality) }.value
                let header = Outgoing.reply(
                    rid: rid, ok: true,
                    fields: [
                        "mime": "image/jpeg", "width": .number(Double(shot.width)),
                        "height": .number(Double(shot.height)),
                        "frame_age_s": .number((shot.age * 1000).rounded() / 1000), "lens": "back_wide",
                    ]
                ).object
                try await c.send(BinaryFrame(header: header, payload: shot.jpeg))
            case "say":
                voice.say(args["text"]?.string ?? "")
                try await c.send(.reply(rid: rid, ok: true))
            case "face":
                guard let f = args["face"]?.string.flatMap(Face.init(rawValue:)) else {
                    throw LinkError("unknown face; one of \(Face.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                faceOverride = (f, Date().addingTimeInterval(args["seconds"]?.double ?? 5))
                try await c.send(.reply(rid: rid, ok: true))
            case "status":
                try await c.send(.reply(rid: rid, ok: true, fields: Self.phoneStatus(cameraOn: camera.running).object))
            default:
                throw LinkError("unknown op \(op)")
            }
        } catch {
            try? await c.send(.reply(rid: rid, ok: false, error: "\(error)"))
        }
    }

    private func statusLoop(_ c: LinkConnection) async {
        while !Task.isCancelled {
            try? await c.send(.status(Self.phoneStatus(cameraOn: camera.running)))
            try? await Task.sleep(for: .seconds(5))
        }
    }

    static func phoneStatus(cameraOn: Bool) -> PhoneStatus {
        let d = UIDevice.current
        let thermal =
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: "nominal"
            case .fair: "fair"
            case .serious: "serious"
            case .critical: "critical"
            @unknown default: "unknown"
            }
        return PhoneStatus(
            battery: d.batteryLevel >= 0 ? Double(d.batteryLevel) : nil,
            charging: d.batteryState == .charging || d.batteryState == .full,
            thermal: thermal, caps: cameraOn ? ["camera", "say", "face"] : ["say", "face"])
    }

    // ---- user actions -------------------------------------------------------------------------------------------

    /// Tap on the face: stop the body. Sent before anything else, never waits on the UI.
    func stop() {
        guard let conn, case .connected = phase else { return }
        Task { try? await conn.send(.stop) }
        faceOverride = (.sad, Date().addingTimeInterval(1.5))
    }

    func pair(code: String) {
        guard let conn else { return }
        Task { try? await conn.send(.pairConfirm(code: code)) }
    }

    func forgetPairing() {
        Keychain.token = nil
        conn?.close()
    }

    func reconnect() { conn?.close() }
}

struct LinkError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Phone speaker TTS for `say` requests.
@MainActor @Observable
final class Voice: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private(set) var speaking = false

    override init() {
        super.init()
        synth.delegate = self
    }

    func say(_ text: String) {
        guard !text.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
        synth.speak(AVSpeechUtterance(string: text))
        speaking = true
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = self.synth.isSpeaking }
    }
}
