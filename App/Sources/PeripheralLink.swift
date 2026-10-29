import AVFoundation
import Foundation
import Observation
import TonyLink
import UIKit
import os

private let log = Logger(subsystem: "org.example.iperipheral", category: "link")

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
    /// Give up on a connection attempt that hasn't been answered by then (URLSession would wait 60 s).
    static let handshakeTimeout: Duration = .seconds(8)

    private(set) var phase: Phase = .searching
    private(set) var robot: RobotState?
    private(set) var lastHeard: String?
    private(set) var lastSaid: String?
    private(set) var requestsServed = 0
    private(set) var lastError: String?
    /// What the phone's own ears last transcribed, and whether they are on.
    private(set) var phoneHeard: String?
    private(set) var earsState = "off"
    private var faceOverride: (face: Face, until: Date)?
    private var agentFace: Face = .idle

    /// Set in the debug overlay when Bonjour can't find the bridge (e.g. ws://192.0.2.1:8766/).
    var manualURL: String {
        get { UserDefaults.standard.string(forKey: "bridgeURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "bridgeURL") }
    }

    private let senses = Senses()
    private let voice = Voice()
    private var conn: LinkConnection?
    private var loop: Task<Void, Never>?
    private var ears: AnyObject?
    private var listener = Listener()
    private var awake = false

    var face: Face {
        if let o = faceOverride, o.until > Date() { return o.face }
        guard case .connected = phase else { return .offline }
        if voice.speaking { return .speaking }
        if awake { return .listening }
        if robot?.asleep == true { return .asleep }
        return agentFace
    }

    func start() {
        guard loop == nil else { return }
        #if DEBUG
            // Dev installs: `-devToken <token>` from scripts/dev-bridge.sh --token skips the spoken pairing code.
            if let t = UserDefaults.standard.string(forKey: "devToken"), !t.isEmpty { Keychain.token = t }
        #endif
        loop = Task { await run() }
        senses.start()
        startEars()
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
            log.info("connecting \(url.absoluteString, privacy: .public)")
            await session(url)
            log.info("session ended: \(self.lastError ?? "closed", privacy: .public)")
            conn = nil
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func session(_ url: URL) async {
        let c = LinkConnection(url: url)
        conn = c
        c.open()
        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard let self, !Task.isCancelled, case .connecting = self.phase else { return }
            self.lastError = "no answer from \(url.host() ?? "bridge")"
            c.close()
        }
        defer { watchdog.cancel() }
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
        case .vocabulary(let words):
            listener.setVocabulary(Listener.baseVocabulary + words)
            if #available(iOS 26, *), let e = ears as? Ears { Task { await e.setVocabulary(words) } }
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
                let shot = try await off { try $0.snapshot(maxSide: maxSide, quality: quality) }
                let header = Outgoing.reply(
                    rid: rid, ok: true,
                    fields: [
                        "mime": "image/jpeg", "width": .number(Double(shot.width)),
                        "height": .number(Double(shot.height)),
                        "frame_age_s": .number(ms(shot.age)), "lens": "back_wide",
                    ]
                ).object
                try await c.send(BinaryFrame(header: header, payload: shot.jpeg))
            case "depth":
                var fields: [String: JSONValue] = [:]
                let pts = (args["points"]?.array ?? []).compactMap { p -> (Double, Double)? in
                    guard let a = p.array, a.count == 2, let x = a[0].double, let y = a[1].double else { return nil }
                    return (x, y)
                }
                if !pts.isEmpty {
                    let ds = try await off { try $0.depth(at: pts) }
                    fields["points"] = .array(
                        zip(pts, ds).map { p, d in
                            [
                                "x": .number(p.0), "y": .number(p.1), "m": d.metres.map { .number($0) } ?? .null,
                                "confidence": .number(Double(d.confidence)),
                            ]
                        })
                }
                if let g = args["grid"]?.array, g.count == 2, let cols = g[0].int, let rows = g[1].int,
                    (1...16).contains(cols), (1...16).contains(rows)
                {
                    let grid = try await off { try $0.depthGrid(cols: cols, rows: rows) }
                    fields["grid"] = .array(grid.map { .array($0.map { $0.map { .number($0) } ?? .null }) })
                }
                try await c.send(.reply(rid: rid, ok: true, fields: fields))
            case "pose":
                let p = try await off { try $0.pose() }
                try await c.send(
                    .reply(
                        rid: rid, ok: true,
                        fields: [
                            "x": .number(cm(p.x)), "y": .number(cm(p.y)), "z": .number(cm(p.z)),
                            "yaw_deg": .number(p.yawDeg.rounded()), "pitch_deg": .number(p.pitchDeg.rounded()),
                            "tracking": .string(p.tracking), "age_s": .number(ms(p.age)),
                        ]))
            case "reset_origin":
                senses.resetOrigin()
                try await c.send(.reply(rid: rid, ok: true))
            case "detect":
                let kinds = Set(args["kinds"]?.array?.compactMap(\.string) ?? Senses.detectKinds)
                let r = try await off { try $0.detect(kinds: kinds) }
                let objects: [JSONValue] = r.objects.map { d in
                    [
                        "kind": .string(d.kind), "x": .number(cm(d.x)), "y": .number(cm(d.y)),
                        "w": .number(cm(d.w)), "h": .number(cm(d.h)), "confidence": .number(cm(d.confidence)),
                        "m": d.metres.map { .number($0) } ?? .null,
                    ]
                }
                try await c.send(
                    .reply(rid: rid, ok: true, fields: ["objects": .array(objects), "age_s": .number(ms(r.age))]))
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
                try await c.send(
                    .reply(
                        rid: rid, ok: true,
                        fields: Self.phoneStatus(cameraOn: senses.running, listening: earsState == "listening").object))
            default:
                throw LinkError("unknown op \(op)")
            }
        } catch {
            try? await c.send(.reply(rid: rid, ok: false, error: "\(error)"))
        }
    }

    /// Runs a Senses query off the main actor (image encoding and Vision take tens of ms).
    private func off<T: Sendable>(_ body: @escaping @Sendable (Senses) throws -> T) async throws -> T {
        let s = senses
        return try await Task.detached { try body(s) }.value
    }

    private func statusLoop(_ c: LinkConnection) async {
        while !Task.isCancelled {
            try? await c.send(.status(Self.phoneStatus(cameraOn: senses.running, listening: earsState == "listening")))
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            guard await c.ping(timeout: 5) else {
                lastError = "bridge stopped answering"
                c.close()
                return
            }
        }
    }

    static func phoneStatus(cameraOn: Bool, listening: Bool = false) -> PhoneStatus {
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
            thermal: thermal,
            caps: (cameraOn ? ["camera", "pose", "detect"] + (Senses.hasLiDAR ? ["depth"] : []) : [])
                + (listening ? ["voice"] : []) + ["say", "face"])
    }

    // ---- voice ------------------------------------------------------------------------------------------------

    private func startEars() {
        guard #available(iOS 26, *) else {
            earsState = "needs iOS 26"
            return
        }
        let e = Ears()
        ears = e
        listener.setVocabulary(Listener.baseVocabulary)
        e.onText = { [weak self] text, isFinal in
            Task { @MainActor in self?.heard(text, isFinal: isFinal) }
        }
        earsState = "starting"
        Task {
            do {
                try await e.start()
                earsState = "listening"
            } catch {
                earsState = "failed: \(error)"
            }
        }
    }

    private func heard(_ text: String, isFinal: Bool) {
        if voice.speaking { return }  // don't act on our own voice
        if isFinal {
            phoneHeard = text
            if let conn, case .connected = phase { Task { try? await conn.send(.transcript(text: text)) } }
        }
        switch listener.hear(text, isFinal: isFinal) {
        case .none:
            if isFinal { awake = false }
        case .stop:
            awake = false
            stop()
        case .wake:
            awake = true
        case .command(let cmd):
            awake = false
            agentFace = .thinking
            guard let conn, case .connected = phase else { return }
            Task { try? await conn.send(.command(text: cmd)) }
        }
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

/// Rounding for the wire: centimetres / hundredths, and milliseconds.
private func cm(_ v: Double) -> Double { (v * 100).rounded() / 100 }
private func ms(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

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
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {  // Ears set up record + speaker already; don't break the mic
            try? session.setCategory(.playback, options: [.duckOthers])
        }
        synth.speak(AVSpeechUtterance(string: text))
        speaking = true
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.speaking = self.synth.isSpeaking }
    }
}
