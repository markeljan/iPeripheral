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
    /// Mounted: on Tony, his senses and face. Companion: on a stand (or in a hand), watching Tony from outside, so a
    /// brain can see its own body move: track him, stream and record what he does, hear commands from across the room.
    enum Mode: String, CaseIterable, Sendable {
        case mounted, companion
    }

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
    /// Where the eyes look: the person in front of the screen (front camera), smoothed. Nil = wander.
    private(set) var gaze: CGPoint?
    private(set) var llmState = "idle"
    /// Launch with `-mode companion`, or switch in the debug overlay or with the bridge's `mode` request.
    private(set) var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .mounted
    /// What the tracker follows (companion mode: usually Tony), updated at 10 Hz; and whether frames are streaming.
    private(set) var tracked: Senses.Detection?
    private(set) var streaming = false
    /// The companion screen's camera view, a few frames a second.
    private(set) var preview: UIImage?
    private var trackTarget: String?
    private var trackLoopRunning = false
    private var streamTask: Task<Void, Never>?
    private var faceOverride: (face: Face, until: Date)?
    private var agentFace: Face = .idle

    /// Set in the debug overlay when Bonjour can't find the bridge (e.g. ws://192.0.2.1:8766/).
    var manualURL: String {
        get { UserDefaults.standard.string(forKey: "bridgeURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "bridgeURL") }
    }

    private let senses = Senses()
    private let voice = Voice()
    private let model = LocalModel()
    private let motion = Motion()
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
        motion.onEvent = { [weak self] e in
            Task { @MainActor in self?.motionEvent(e) }
        }
        motion.start()
        Task { await gazeLoop() }
        Task { await thermalLoop() }
        Task { await previewLoop() }
        Task {  // compile llama.cpp's Metal shaders while nobody is waiting (only if the text model is on the phone)
            try? await Task.sleep(for: .seconds(20))
            if ProcessInfo.processInfo.thermalState.rawValue <= ProcessInfo.ThermalState.fair.rawValue,
                let m = ModelSpec.named("lfm3-1.7b")
            {
                model.warmUp(m)
            }
        }
    }

    /// Thermal governor. Serious: drop front-camera face tracking (the eyes wander instead). Critical: also refuse
    /// on-device model runs (in runModel). Back to normal once the phone cools to fair.
    private func thermalLoop() async {
        applyThermal()
        for await _ in NotificationCenter.default.notifications(named: ProcessInfo.thermalStateDidChangeNotification) {
            applyThermal()
        }
    }

    /// Set by the `face_tracking` request: nil = automatic (thermal governor), true/false = forced (testing).
    private var faceTrackingOverride: Bool?

    private func applyThermal() {
        let t = ProcessInfo.processInfo.thermalState
        if let forced = faceTrackingOverride {
            senses.setFaceTracking(forced)
        } else if mode == .companion {
            senses.setFaceTracking(false)  // no face on the screen to aim
        } else if t == .serious || t == .critical {
            senses.setFaceTracking(false)
        } else if t == .nominal || t == .fair {
            senses.setFaceTracking(true)
        }
        log.info("thermal \(t.rawValue): face tracking \(self.senses.faceTracking)")
    }

    /// 15 Hz: ease the eyes toward the viewer's face (or back to wandering when nobody has been seen for a second).
    private func gazeLoop() async {
        var lastSeen = Date.distantPast
        while !Task.isCancelled {
            if let target = senses.viewerGaze() {
                let g = gaze ?? .zero
                gaze = CGPoint(x: g.x + (target.x - g.x) * 0.3, y: g.y + (target.y - g.y) * 0.3)
                lastSeen = Date()
            } else if Date().timeIntervalSince(lastSeen) > 1.5 {
                gaze = nil  // hold the last look through short tracking gaps, then wander
            }
            try? await Task.sleep(for: .milliseconds(66))
        }
    }

    private func motionEvent(_ e: Motion.Event) {
        guard mode == .mounted else { return }  // the phone's own falls say nothing about Tony's when it isn't on him
        if e.kind == "fall" || e.kind == "impact" { faceOverride = (.sad, Date().addingTimeInterval(3)) }
        let t = motion.tilt
        send(.event(kind: e.kind, fields: ["value": .number(e.value), "tilt_deg": .number(t.deg.rounded())]))
    }

    private func send(_ m: Outgoing) {
        guard let conn, case .connected = phase else { return }
        Task { try? await conn.send(m) }
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
            let poses = Task { await poseLoop(c) }
            defer {
                status.cancel()
                poses.cancel()
            }
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
            Task { await answer(rid: rid, op: op, args: args, on: c) }  // a slow one (llm) mustn't block the rest
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
                let kinds = Set(args["kinds"]?.array?.compactMap(\.string) ?? Senses.defaultKinds)
                let r = try await off { try $0.detect(kinds: kinds) }
                let objects = r.objects.map(Self.json)
                try await c.send(
                    .reply(rid: rid, ok: true, fields: ["objects": .array(objects), "age_s": .number(ms(r.age))]))
            case "ground":
                guard mode == .mounted else { throw LinkError("companion mode: the phone isn't on Tony") }
                let g = try await off { try $0.ground() }
                let lanes: [JSONValue] = g.lanes.map { l in
                    [
                        "lane": .string(l.name), "clear_m": l.clearM.map { .number($0) } ?? .null,
                        "edge_m": l.edgeM.map { .number($0) } ?? .null, "drop_m": l.dropM.map { .number($0) } ?? .null,
                        "obstacle_m": l.obstacleM.map { .number($0) } ?? .null,
                    ]
                }
                try await c.send(
                    .reply(
                        rid: rid, ok: true,
                        fields: [
                            "surface_below_m": g.surfaceBelowM.map { .number($0) } ?? .null, "lanes": .array(lanes),
                            "age_s": .number(ms(g.age)),
                        ]))
            case "face_tracking":
                switch args["mode"]?.string {
                case "on": faceTrackingOverride = true
                case "off": faceTrackingOverride = false
                default: faceTrackingOverride = nil
                }
                applyThermal()
                try await c.send(.reply(rid: rid, ok: true, fields: gazeStatus()))
            case "gaze":
                try await c.send(.reply(rid: rid, ok: true, fields: gazeStatus()))
            case "motion":
                let t = motion.tilt
                try await c.send(
                    .reply(
                        rid: rid, ok: true,
                        fields: [
                            "tilt_deg": .number(t.deg.rounded()), "roll_deg": .number(t.rollDeg.rounded()),
                            "fallen": .bool(t.fallen),
                        ]))
            case "llm":
                try await c.send(.reply(rid: rid, ok: true, fields: try await runModel(args)))
            case "locate":
                try await c.send(.reply(rid: rid, ok: true, fields: try await locate(args)))
            case "models":
                try await c.send(.reply(rid: rid, ok: true, fields: modelsStatus()))
            case "model_download":
                guard let m = args["model"]?.string.flatMap(ModelSpec.named) else {
                    throw LinkError("unknown model; one of \(ModelSpec.all.map(\.id).joined(separator: ", "))")
                }
                model.download(m)
                try await c.send(.reply(rid: rid, ok: true, fields: modelsStatus()))
            case "model_unload":
                model.unload()
                try await c.send(.reply(rid: rid, ok: true))
            case "say":
                voice.say(args["text"]?.string ?? "")
                try await c.send(.reply(rid: rid, ok: true))
            case "face":
                guard let f = args["face"]?.string.flatMap(Face.init(rawValue:)) else {
                    throw LinkError("unknown face; one of \(Face.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                faceOverride = (f, Date().addingTimeInterval(args["seconds"]?.double ?? 5))
                try await c.send(.reply(rid: rid, ok: true))
            case "mode":
                if let m = args["mode"]?.string {
                    guard let new = Mode(rawValue: m) else { throw LinkError("mode is mounted or companion") }
                    setMode(new)
                }
                try await c.send(.reply(rid: rid, ok: true, fields: status().object))
            case "track":
                try await c.send(.reply(rid: rid, ok: true, fields: try await track(args)))
            case "stream":
                let fps = min(10, max(0, args["fps"]?.double ?? 5))
                streamTask?.cancel()
                streamTask = nil
                streaming = fps > 0
                if fps > 0 {
                    let side = min(1280, max(240, args["max_side"]?.int ?? 640))
                    let quality = min(0.9, max(0.3, args["quality"]?.double ?? 0.6))
                    streamTask = Task { await streamLoop(c, fps: fps, maxSide: side, quality: quality) }
                }
                try await c.send(.reply(rid: rid, ok: true, fields: ["fps": .number(fps)]))
            case "status":
                try await c.send(.reply(rid: rid, ok: true, fields: status().object))
            default:
                throw LinkError("unknown op \(op)")
            }
        } catch {
            try? await c.send(.reply(rid: rid, ok: false, error: "\(error)"))
        }
    }

    private func gazeStatus() -> [String: JSONValue] {
        let point: (CGPoint?) -> JSONValue = { p in
            p.map { ["x": .number(cm($0.x)), "y": .number(cm($0.y))] } ?? .null
        }
        let s = senses.takeFaceStats()
        return [
            "frames": .number(Double(s.frames)), "frames_with_face": .number(Double(s.anchors)),
            "frames_tracked": .number(Double(s.tracked)),
            "last_seen_s": s.lastSeenAgo.map { .number(ms($0)) } ?? .null,
            "face_tracking": .bool(senses.faceTracking),
            "mode": .string(faceTrackingOverride.map { $0 ? "on" : "off" } ?? "auto"),
            "viewer": point(senses.viewerGaze()), "eyes": point(gaze),
        ]
    }

    // ---- companion mode: mode, tracking, streaming ------------------------------------------------------------

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
        log.info("mode: \(m.rawValue, privacy: .public)")
        applyThermal()
        send(.status(status()))
    }

    /// Start following something: `box` [x, y, w, h] seeds the tracker directly; otherwise LFM3-VL finds `target`
    /// first (a few seconds). `stop: true` ends it. The tracker re-finds a lost target with the vision model.
    private func track(_ args: [String: JSONValue]) async throws -> [String: JSONValue] {
        if args["stop"]?.bool == true {
            senses.stopTracking()
            trackTarget = nil
            tracked = nil
            return ["tracking": false]
        }
        let target = args["target"]?.string ?? "the small humanoid robot"
        if let b = args["box"]?.array?.compactMap(\.double), b.count == 4 {
            senses.startTracking(label: target, x: b[0], y: b[1], w: b[2], h: b[3])
            trackTarget = args["refind"]?.bool == false ? nil : target
        } else {
            guard let d = try await find(target) else { throw LinkError("couldn't see \(target)") }
            senses.startTracking(label: target, x: d.x, y: d.y, w: d.w, h: d.h)
            trackTarget = target
        }
        if !trackLoopRunning { Task { await trackLoop() } }
        tracked = nil
        for _ in 0..<20 where tracked == nil {  // wait for the first tracker step, so the reply has a fresh box
            try? await Task.sleep(for: .milliseconds(100))
        }
        return ["tracking": true, "tracked": tracked.map(Self.trackedJSON) ?? .null]
    }

    /// The biggest box LFM3-VL draws for `target`.
    private func find(_ target: String) async throws -> Senses.Detection? {
        try await locateBoxes(target, side: 768, thinking: false).placed.max { $0.w * $0.h < $1.w * $1.h }
    }

    /// 10 Hz tracker steps. Lost for 2 s (confidence < 0.3): ask the vision model again, at most every 10 s.
    private func trackLoop() async {
        trackLoopRunning = true
        defer { trackLoopRunning = false }
        var lastGood = Date()
        var lastRefind = Date.distantPast
        while senses.tracking, !Task.isCancelled {
            if let d = try? await off({ try $0.trackStep() }) {
                tracked = d
                if d.confidence >= Self.trackLost { lastGood = Date() }
            }
            if let target = trackTarget, Date().timeIntervalSince(lastGood) > 2,
                Date().timeIntervalSince(lastRefind) > 10, llmState == "idle"
            {
                lastRefind = Date()
                if let d = try? await find(target), senses.tracking {
                    senses.startTracking(label: target, x: d.x, y: d.y, w: d.w, h: d.h)
                    lastGood = Date()
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        tracked = nil
    }

    static let trackLost = 0.3

    private static func trackedJSON(_ d: Senses.Detection) -> JSONValue {
        guard case .object(var o) = json(d) else { return .null }
        o["lost"] = .bool(d.confidence < trackLost)
        return .object(o)
    }

    /// Pushes JPEG frames (binary `frame` messages: what was tracked and where the phone was, with each picture)
    /// until the bridge says `stream` fps 0 or the connection ends. The bridge records them as episodes.
    private func streamLoop(_ c: LinkConnection, fps: Double, maxSide: Int, quality: Double) async {
        var seq = 0
        let period = 1 / fps
        while !Task.isCancelled, conn === c {
            let start = Date()
            if let shot = try? await off({ try $0.snapshot(maxSide: maxSide, quality: quality) }) {
                var header: [String: JSONValue] = [
                    "type": "frame", "seq": .number(Double(seq)),
                    "t": .number(ms(Date().timeIntervalSince1970 - shot.age)),
                    "width": .number(Double(shot.width)), "height": .number(Double(shot.height)),
                    "tracked": tracked.map(Self.trackedJSON) ?? .null,
                ]
                if let p = try? senses.pose() {
                    header["pose"] = [
                        "x": .number(cm(p.x)), "y": .number(cm(p.y)), "z": .number(cm(p.z)),
                        "yaw_deg": .number((p.yawDeg * 10).rounded() / 10), "tracking": .string(p.tracking),
                    ]
                }
                do {
                    try await c.send(BinaryFrame(header: header, payload: shot.jpeg))
                } catch {
                    break
                }
                seq += 1
            }
            try? await Task.sleep(for: .seconds(max(0.01, period - Date().timeIntervalSince(start))))
        }
        if !Task.isCancelled { streaming = false }
    }

    /// The companion screen shows what the camera sees (4 fps); nothing to draw in mounted mode, where it's a face.
    private func previewLoop() async {
        while !Task.isCancelled {
            if mode == .companion, senses.running, UIApplication.shared.applicationState == .active,
                let shot = try? await off({ try $0.snapshot(maxSide: 480, quality: 0.5) })
            {
                preview = UIImage(data: shot.jpeg)
            } else if mode == .mounted {
                preview = nil
            }
            try? await Task.sleep(for: .milliseconds(mode == .companion ? 250 : 1000))
        }
    }

    // ---- on-device model -------------------------------------------------------------------------------------

    private func runModel(_ args: [String: JSONValue]) async throws -> [String: JSONValue] {
        let useImage = args["image"]?.bool ?? false
        let id = args["model"]?.string ?? (useImage ? "lfm3-vl-2b" : "lfm3-1.7b")
        guard let spec = ModelSpec.named(id) else {
            throw LinkError("unknown model; one of \(ModelSpec.all.map(\.id).joined(separator: ", "))")
        }
        guard ProcessInfo.processInfo.thermalState != .critical else { throw LocalModel.Failure.tooHot }
        var messages: [LocalModel.Message] = (args["messages"]?.array ?? []).compactMap { m in
            guard let role = m["role"]?.string, let content = m["content"]?.string else { return nil }
            return (role, content)
        }
        if messages.isEmpty {
            guard let prompt = args["prompt"]?.string, !prompt.isEmpty else { throw LinkError("prompt is required") }
            if let system = args["system"]?.string, !system.isEmpty { messages.append(("system", system)) }
            messages.append(("user", prompt))
        }
        var image: (rgb: [UInt8], width: Int, height: Int)?
        if useImage {
            guard spec.vision else { throw LinkError("\(id) has no vision; use lfm3-vl-2b") }
            let side = min(1024, max(256, args["image_side"]?.int ?? 512))  // smaller = fewer image tokens = faster
            let f = try await off { try $0.capture(maxSide: side) }
            image = (f.rgb, f.width, f.height)
        }
        var options = LocalModel.Options()
        options.maxTokens = min(2048, max(1, args["max_tokens"]?.int ?? 256))
        options.thinking = args["thinking"]?.bool ?? false
        options.gpu = args["backend"]?.string != "cpu"
        llmState = "running \(id)"
        defer { llmState = "idle" }
        let face = agentFace
        agentFace = .thinking
        defer { agentFace = face }
        let out = try await model.generate(
            model: spec, messages: messages, image: image, options: options)
        log.info(
            "llm \(id, privacy: .public): \(out.promptTokens) + \(out.generatedTokens) tokens, \(Int(out.decodeTokensPerSecond)) tok/s"
        )
        return [
            "text": .string(out.text), "thinking": out.thinking.map { .string($0) } ?? .null,
            "model": .string(out.model), "backend": .string(out.backend),
            "prompt_tokens": .number(Double(out.promptTokens)),
            "generated_tokens": .number(Double(out.generatedTokens)),
            "prefill_tok_s": .number(out.prefillTokensPerSecond.rounded()),
            "decode_tok_s": .number((out.decodeTokensPerSecond * 10).rounded() / 10),
            "load_s": .number(ms(out.loadSeconds)), "total_s": .number(ms(out.totalSeconds)),
        ]
    }

    /// Open-vocabulary detection: LFM3-VL-2B finds whatever `target` describes ("the red mug", "my keys") and returns
    /// boxes, which are then placed in the world from the same frame's depth and pose. Seconds, not milliseconds:
    /// for finding something once, not for tracking it.
    private func locate(_ args: [String: JSONValue]) async throws -> [String: JSONValue] {
        guard let target = args["target"]?.string, !target.isEmpty else { throw LinkError("target is required") }
        let side = min(1024, max(256, args["image_side"]?.int ?? 768))  // grounding likes detail
        let (placed, out) = try await locateBoxes(target, side: side, thinking: args["thinking"]?.bool ?? false)
        return [
            "target": .string(target), "objects": .array(placed.map(Self.json)), "raw": .string(out.text),
            "prompt_tokens": .number(Double(out.promptTokens)), "total_s": .number(ms(out.totalSeconds)),
        ]
    }

    private func locateBoxes(_ target: String, side: Int, thinking: Bool) async throws -> (
        placed: [Senses.Detection], out: LocalModel.Output
    ) {
        guard let spec = ModelSpec.named("lfm3-vl-2b") else { throw LinkError("no vision model") }
        guard ProcessInfo.processInfo.thermalState != .critical else { throw LocalModel.Failure.tooHot }
        let frame = try await off { try $0.capture(maxSide: side) }
        // The box format is LFM3-VL's own (Liquid's grounding docs): [xmin, ymin, xmax, ymax] on a 0-1000 grid.
        let system = """
            When asked for bounding boxes for objects, return a valid JSON array. Each item is \
            {"bbox_2d": [xmin, ymin, xmax, ymax], "label": "..."} with integer coordinates normalized to [0, 1000]. \
            Return [] if none are visible.
            """
        var options = LocalModel.Options()
        options.maxTokens = 400
        options.thinking = thinking
        llmState = "locating"
        defer { llmState = "idle" }
        let out = try await model.generate(
            model: spec, messages: [("system", system), ("user", "Provide bounding boxes for \(target).")],
            image: (frame.rgb, frame.width, frame.height), options: options)
        let boxes = Grounding.parse(out.text).map { ($0.label, $0.x, $0.y, $0.w, $0.h) }
        return (senses.place(boxes, in: frame), out)
    }

    private static func json(_ d: Senses.Detection) -> JSONValue {
        var o: [String: JSONValue] = [
            "kind": .string(d.kind), "x": .number(cm(d.x)), "y": .number(cm(d.y)), "w": .number(cm(d.w)),
            "h": .number(cm(d.h)), "confidence": .number(cm(d.confidence)), "m": d.metres.map { .number($0) } ?? .null,
            "bearing_deg": .number(d.bearingDeg.rounded()), "elevation_deg": .number(d.elevationDeg.rounded()),
        ]
        if let l = d.label { o["label"] = .string(l) }
        if let w = d.world {
            o["world"] = [.number(cm(Double(w.x))), .number(cm(Double(w.y))), .number(cm(Double(w.z)))]
        }
        return .object(o)
    }

    private func modelsStatus() -> [String: JSONValue] {
        let dl = model.downloads.snapshot()
        let models: [JSONValue] = ModelSpec.all.map { m in
            var o: [String: JSONValue] = [
                "id": .string(m.id), "file": .string(m.file), "vision": .bool(m.vision),
                "downloaded": .bool(LocalModel.isDownloaded(m)), "loaded": .bool(model.loaded == m.id),
                "size_mb": .number(Double((m.bytes + m.mmprojBytes) / 1_000_000)),
            ]
            let files = [m.file] + (m.mmproj.map { [$0] } ?? [])
            let parts = files.compactMap { dl[$0] }
            if !parts.isEmpty {
                let got = parts.map(\.received).reduce(0, +)
                let want = parts.map(\.expected).reduce(0, +)
                o["downloading"] = .number(want > 0 ? (Double(got) / Double(want) * 100).rounded() : 0)
                if let e = parts.compactMap(\.error).first { o["error"] = .string(e) }
            }
            return .object(o)
        }
        return ["models": .array(models), "runtime": "llama.cpp b11988 (Metal)"]
    }

    /// Runs a Senses query off the main actor (image encoding and Vision take tens of ms).
    private func off<T: Sendable>(_ body: @escaping @Sendable (Senses) throws -> T) async throws -> T {
        let s = senses
        return try await Task.detached { try body(s) }.value
    }

    /// 10 Hz pose stream, so the bridge answers phone_pose instantly and can follow a turn or walk closely.
    private func poseLoop(_ c: LinkConnection) async {
        while !Task.isCancelled {
            if case .connected = phase, let p = try? senses.pose() {
                try? await c.send(
                    .pose(fields: [
                        "x": .number(cm(p.x)), "y": .number(cm(p.y)), "z": .number(cm(p.z)),
                        "yaw_deg": .number((p.yawDeg * 10).rounded() / 10), "pitch_deg": .number(p.pitchDeg.rounded()),
                        "tracking": .string(p.tracking),
                    ]))
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func statusLoop(_ c: LinkConnection) async {
        while !Task.isCancelled {
            try? await c.send(.status(status()))
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            guard await c.ping(timeout: 5) else {
                lastError = "bridge stopped answering"
                c.close()
                return
            }
        }
    }

    private func status() -> PhoneStatus {
        Self.phoneStatus(cameraOn: senses.running, listening: earsState == "listening", mode: mode)
    }

    static func phoneStatus(cameraOn: Bool, listening: Bool = false, mode: Mode = .mounted) -> PhoneStatus {
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
            caps: (cameraOn ? ["camera", "pose", "detect", "track", "stream"] : [])
                + (cameraOn && Senses.hasLiDAR ? (mode == .mounted ? ["depth", "ground"] : ["depth"]) : [])
                + (Senses.hasObjectModel ? ["objects"] : []) + (listening ? ["voice", "sounds"] : [])
                + (LocalModel.available ? ["llm"] : []) + (mode == .mounted ? ["motion", "say", "face"] : ["say"]),
            mode: mode.rawValue)
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
        e.onSound = { [weak self] label, confidence in
            Task { @MainActor in
                self?.send(.event(kind: "sound", fields: ["label": .string(label), "confidence": .number(confidence)]))
            }
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
