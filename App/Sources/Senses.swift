@preconcurrency import ARKit
import CoreImage
import CoreML
import UIKit
import Vision

/// The phone's eyes: one ARKit session gives the camera image, LiDAR depth and the phone's pose together (ARKit
/// owns the back camera, so there is no separate AVCaptureSession). Keeps only the latest frame; every query
/// answers from it, so nothing waits for a shutter. The front (TrueDepth) camera tracks the face of whoever looks at
/// the screen, so Tony's eyes can look back at them.
///
/// Coordinates: `x, y` are normalized 0–1 in the portrait image the snapshot returns, origin top-left. World: metres,
/// y up, origin where tracking started. Angles are degrees; yaw and bearing are positive to the left.
final class Senses: NSObject, ARSessionDelegate, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case unavailable, noFrame, noDepth
        var description: String {
            switch self {
            case .unavailable: "no ARKit camera on this device"
            case .noFrame: "no camera frame yet"
            case .noDepth: "no LiDAR depth yet"
            }
        }
    }

    struct Latest {
        var image: CVPixelBuffer
        var depth: CVPixelBuffer?
        var confidence: CVPixelBuffer?
        var transform: simd_float4x4
        var intrinsics: simd_float3x3
        var resolution: CGSize
        var tracking: String
        var at: Date
    }

    static var supported: Bool { ARWorldTrackingConfiguration.isSupported }
    static var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    private let session = ARSession()
    private let queue = DispatchQueue(label: "senses")
    private let lock = NSLock()
    private var latest: Latest?
    private var viewer: (gaze: CGPoint, at: Date)?
    private let ci = CIContext()
    private(set) var running = false

    /// Front-camera face tracking for the eyes' gaze: the first thing to go when the phone gets hot.
    private(set) var faceTracking = true

    func start() {
        guard Self.supported, !running else { return }
        session.delegate = self
        session.delegateQueue = queue
        session.run(configuration())
        running = true
    }

    /// Cool down (or back up): face tracking costs a second camera. Tracking and the world origin carry on.
    func setFaceTracking(_ on: Bool) {
        guard running, on != faceTracking else { return }
        faceTracking = on
        session.run(configuration())
        if !on { lock.withLock { viewer = nil } }
    }

    private func configuration() -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if Self.hasLiDAR { config.frameSemantics.insert(.smoothedSceneDepth) }
        config.userFaceTrackingEnabled = faceTracking && ARWorldTrackingConfiguration.supportsUserFaceTracking
        // Lowest frame rate at full image size: plenty for a walking robot, and much cooler than 60 fps.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        if let f = formats.filter({ $0.imageResolution.width >= 1920 }).min(by: {
            $0.framesPerSecond < $1.framesPerSecond
        }) {
            config.videoFormat = f
        }
        return config
    }

    /// Start tracking again with the current position as the origin.
    func resetOrigin() {
        guard let config = session.configuration else { return }
        session.run(config, options: [.resetTracking])
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let tracking: String =
            switch frame.camera.trackingState {
            case .normal: "normal"
            case .notAvailable: "not_available"
            case .limited(.initializing): "limited:initializing"
            case .limited(.excessiveMotion): "limited:excessive_motion"
            case .limited(.insufficientFeatures): "limited:insufficient_features"
            case .limited(.relocalizing): "limited:relocalizing"
            case .limited: "limited"
            }
        let depth = frame.smoothedSceneDepth ?? frame.sceneDepth
        let l = Latest(
            image: frame.capturedImage, depth: depth?.depthMap, confidence: depth?.confidenceMap,
            transform: frame.camera.transform, intrinsics: frame.camera.intrinsics,
            resolution: frame.camera.imageResolution, tracking: tracking, at: Date())
        // The face of whoever looks at the screen (front camera), as a gaze direction in screen space.
        var gaze: CGPoint?
        let faces = frame.anchors.compactMap { $0 as? ARFaceAnchor }
        lock.withLock {
            faceAnchored = !faces.isEmpty
            stats.frames += 1
            if !faces.isEmpty { stats.anchors += 1 }
            if faces.contains(where: \.isTracked) { stats.tracked += 1 }
        }
        if let face = faces.first(where: \.isTracked) {
            let p = frame.camera.transform.inverse * face.transform.columns.3
            // Camera space is landscape: camera +y = screen right, camera +x = screen down; the viewer is at +z.
            if p.z > 0.05 { gaze = CGPoint(x: Double(p.y / p.z), y: Double(p.x / p.z)) }
        }
        lock.withLock {
            latest = l
            if let gaze { viewer = (gaze, Date()) }
        }
    }

    private func current() throws -> Latest {
        guard let l = lock.withLock({ latest }) else { throw running ? Failure.noFrame : Failure.unavailable }
        return l
    }

    /// Frames since the last call, how many had a face anchor, and how many had it tracked (diagnostics).
    private var stats = (frames: 0, anchors: 0, tracked: 0)
    func takeFaceStats() -> (frames: Int, anchors: Int, tracked: Int, lastSeenAgo: Double?) {
        lock.withLock {
            defer { stats = (0, 0, 0) }
            return (stats.frames, stats.anchors, stats.tracked, viewer.map { Date().timeIntervalSince($0.at) })
        }
    }

    /// ARKit still has a face anchor (it keeps one, "not tracked", when the face turns or moves off-axis).
    private var faceAnchored = false

    /// Where the person looking at the screen is, roughly -1…1 on each axis (x right, y down): seen in the last second,
    /// or up to 6 s ago while ARKit still holds the face anchor (an off-axis face often drops to "not tracked").
    func viewerGaze() -> CGPoint? {
        lock.withLock {
            guard let v = viewer else { return nil }
            let age = Date().timeIntervalSince(v.at)
            guard age < 1 || (faceAnchored && age < 6) else { return nil }
            return CGPoint(x: max(-1, min(1, v.gaze.x * 1.6)), y: max(-1, min(1, v.gaze.y * 1.6)))
        }
    }

    // ---- images -------------------------------------------------------------------------------------------------

    struct Snapshot {
        let jpeg: Data
        let width: Int
        let height: Int
        let age: Double
    }

    private func portrait(_ l: Latest, maxSide: Int) -> CIImage {
        var image = CIImage(cvPixelBuffer: l.image).oriented(.right)  // sensor is landscape; mounted phone is portrait
        image = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        let side = max(image.extent.width, image.extent.height)
        if side > CGFloat(maxSide) {
            let s = CGFloat(maxSide) / side
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        return image
    }

    /// JPEG of the latest frame, portrait, longest side scaled down to `maxSide`.
    func snapshot(maxSide: Int, quality: Double) throws -> Snapshot {
        let l = try current()
        let image = portrait(l, maxSide: maxSide)
        guard
            let jpeg = ci.jpegRepresentation(
                of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
        else { throw Failure.noFrame }
        return Snapshot(
            jpeg: jpeg, width: Int(image.extent.width.rounded()), height: Int(image.extent.height.rounded()),
            age: Date().timeIntervalSince(l.at))
    }

    // ---- geometry -----------------------------------------------------------------------------------------------

    /// Portrait (x, y) → landscape sensor (sx, sy); the sensor image is the portrait image turned 90° anticlockwise.
    private static func sensor(_ x: Double, _ y: Double) -> (Double, Double) { (y, 1 - x) }

    /// The ray through portrait point (x, y), in world space (unit length), using the camera's intrinsics.
    private static func ray(_ l: Latest, _ x: Double, _ y: Double) -> SIMD3<Float> {
        let (sx, sy) = sensor(x, y)
        let k = l.intrinsics
        let px = Float(sx * l.resolution.width)
        let py = Float(sy * l.resolution.height)
        // ARKit camera space: x right, y up (in sensor orientation), looking down -z. Depth is along -z.
        let cam = SIMD3<Float>((px - k.columns.2.x) / k.columns.0.x, -(py - k.columns.2.y) / k.columns.1.y, -1)
        let r = l.transform
        let world = SIMD3<Float>(
            r.columns.0.x * cam.x + r.columns.1.x * cam.y + r.columns.2.x * cam.z,
            r.columns.0.y * cam.x + r.columns.1.y * cam.y + r.columns.2.y * cam.z,
            r.columns.0.z * cam.x + r.columns.1.z * cam.y + r.columns.2.z * cam.z)
        return simd_normalize(world)
    }

    /// World point at portrait (x, y) given its LiDAR depth (metres along the optical axis).
    private static func worldPoint(_ l: Latest, _ x: Double, _ y: Double, depth: Double) -> SIMD3<Float> {
        let (sx, sy) = sensor(x, y)
        let k = l.intrinsics
        let px = Float(sx * l.resolution.width)
        let py = Float(sy * l.resolution.height)
        let d = Float(depth)
        let cam = SIMD4<Float>(
            (px - k.columns.2.x) / k.columns.0.x * d, -(py - k.columns.2.y) / k.columns.1.y * d, -d, 1)
        let w = l.transform * cam
        return SIMD3(w.x, w.y, w.z)
    }

    /// Horizontal angle from the body's heading to `dir` (positive = left) and elevation above the horizon.
    private static func angles(_ l: Latest, _ dir: SIMD3<Float>) -> (bearing: Double, elevation: Double) {
        let fwd = -simd_make_float3(l.transform.columns.2)
        let f = simd_normalize(SIMD2<Float>(fwd.x, fwd.z))
        let v = SIMD2<Float>(dir.x, dir.z)
        let bearing = atan2(Double(f.y * v.x - f.x * v.y), Double(simd_dot(f, v)))
        let elevation = asin(Double(max(-1, min(1, dir.y))))
        return (bearing * 180 / .pi, elevation * 180 / .pi)
    }

    // ---- depth --------------------------------------------------------------------------------------------------

    /// Metres to whatever is at each point (median of a small patch), nil where depth is missing or low confidence.
    func depth(at points: [(Double, Double)]) throws -> [(metres: Double?, confidence: Int)] {
        let l = try current()
        guard let d = l.depth else { throw Failure.noDepth }
        return DepthMap.read(d, l.confidence) { m in
            points.map { p in
                let (sx, sy) = Self.sensor(p.0, p.1)
                return m.sample(sx, sy, radius: 2)
            }
        }
    }

    /// Nearest distance in each cell of a `cols` × `rows` grid over the portrait image (row 0 = top).
    func depthGrid(cols: Int, rows: Int) throws -> [[Double?]] {
        let l = try current()
        guard let d = l.depth else { throw Failure.noDepth }
        return DepthMap.read(d, l.confidence) { m in
            (0..<rows).map { r in
                (0..<cols).map { c in
                    let x0 = Double(c) / Double(cols)
                    let x1 = Double(c + 1) / Double(cols)
                    let y0 = Double(r) / Double(rows)
                    let y1 = Double(r + 1) / Double(rows)
                    let (sx0, sy1) = Self.sensor(x0, y0)
                    let (sx1, sy0) = Self.sensor(x1, y1)
                    return m.nearest(sx0..<sx1, sy0..<sy1)
                }
            }
        }
    }

    // ---- ground ahead -------------------------------------------------------------------------------------------

    struct Lane: Sendable {
        let name: String
        /// Ground continues at the surface's height out to this distance (metres, horizontal).
        var clearM: Double?
        /// The ground drops away (table edge, stairs down) at this distance, by `dropM`.
        var edgeM: Double?
        var dropM: Double?
        /// Something stands up from the ground at this distance.
        var obstacleM: Double?
    }

    struct Ground: Sendable {
        /// How far the surface Tony stands on is below the phone.
        let surfaceBelowM: Double?
        let lanes: [Lane]
        let age: Double
    }

    /// Walks the lower part of the view outward in three lanes (left, centre, right), turning LiDAR depth into world
    /// heights, and reports where the ground stops being the surface Tony stands on: an edge (drop > 8 cm) or an
    /// obstacle (rise > 6 cm). The nearest visible ground is taken as that surface.
    func ground() throws -> Ground {
        let l = try current()
        guard let d = l.depth else { throw Failure.noDepth }
        let camY = l.transform.columns.3.y
        let camXZ = SIMD2(l.transform.columns.3.x, l.transform.columns.3.z)
        // Bottom of the image (near) upward (far, and above the horizon, where walls and furniture show up).
        let rows = stride(from: 0.98, through: 0.10, by: -0.03).map { $0 }
        let lanes: [(String, Double)] = [("left", 0.2), ("centre", 0.5), ("right", 0.8)]
        // Per lane: (horizontal distance, height, below the horizon?) for three columns across the lane
        var samples: [[(r: Float, y: Float, ground: Bool)]] = Array(repeating: [], count: lanes.count)
        DepthMap.read(d, l.confidence) { m in
            for (i, lane) in lanes.enumerated() {
                for v in rows {
                    for x in [lane.1 - 0.08, lane.1, lane.1 + 0.08] {
                        let (sx, sy) = Self.sensor(x, v)
                        guard let depth = m.sample(sx, sy, radius: 2).metres else { continue }
                        let p = Self.worldPoint(l, x, v, depth: depth)
                        let below = Self.ray(l, x, v).y < -0.05
                        samples[i].append((simd_length(SIMD2(p.x, p.z) - camXZ), p.y, below))
                    }
                }
            }
        }
        let nearest = samples.flatMap { $0.filter(\.ground).prefix(6) }.map(\.y).sorted()
        guard !nearest.isEmpty else {
            return Ground(
                surfaceBelowM: nil, lanes: lanes.map { Lane(name: $0.0) }, age: Date().timeIntervalSince(l.at))
        }
        let surface = nearest[nearest.count / 2]
        let out: [Lane] = lanes.enumerated().map { i, lane in
            var r = Lane(name: lane.0)
            for s in samples[i].sorted(by: { $0.r < $1.r }) {
                let dy = s.y - surface
                // Anything 6–45 cm above the surface is in Tony's way (higher is overhead: a table top).
                if dy > 0.06, dy < 0.45 {
                    r.obstacleM = cm(Double(s.r))
                    break
                }
                guard s.ground else { continue }
                if dy < -0.08 {
                    r.edgeM = cm(Double(s.r))
                    r.dropM = cm(Double(-dy))
                    break
                }
                if abs(dy) <= 0.06 { r.clearM = cm(Double(s.r)) }
            }
            return r
        }
        return Ground(surfaceBelowM: cm(Double(camY - surface)), lanes: out, age: Date().timeIntervalSince(l.at))
    }

    // ---- pose ---------------------------------------------------------------------------------------------------

    struct Pose {
        let x, y, z, yawDeg, pitchDeg: Double
        let tracking: String
        let age: Double
    }

    func pose() throws -> Pose {
        let l = try current()
        let t = l.transform
        let forward = -simd_make_float3(t.columns.2)  // the back camera looks along the camera's -Z
        let yaw = atan2(Double(-forward.x), Double(-forward.z)) * 180 / .pi
        let pitch = asin(Double(max(-1, min(1, forward.y)))) * 180 / .pi
        return Pose(
            x: Double(t.columns.3.x), y: Double(t.columns.3.y), z: Double(t.columns.3.z), yawDeg: yaw,
            pitchDeg: pitch, tracking: l.tracking, age: Date().timeIntervalSince(l.at))
    }

    // ---- detection ----------------------------------------------------------------------------------------------

    struct Detection: Sendable {
        let kind: String
        var label: String?
        let x, y, w, h, confidence: Double
        var metres: Double?
        var bearingDeg = 0.0
        var elevationDeg = 0.0
        /// Where it is in the world (pose coordinates), when depth is known: walk there even after it's out of view.
        var world: SIMD3<Float>?
    }

    /// Detected by default. `text` (OCR) and `codes` (QR, barcodes) only when asked: slower and rarely wanted.
    static let defaultKinds = ["people", "faces", "hands", "animals", "objects"]
    static let detectKinds = defaultKinds + ["text", "codes"]

    /// YOLO26n (80 COCO classes, NMS-free end-to-end head) compiled into the app from App/Models, on the Neural
    /// Engine; class names come from the model's metadata. Nil when not bundled (scripts/export-yolo.sh).
    nonisolated(unsafe) private static let objectModel: (model: VNCoreMLModel, names: [String])? = {
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let url = Bundle.main.url(forResource: "yolo26n", withExtension: "mlmodelc"),
            let m = try? MLModel(contentsOf: url, configuration: config), let v = try? VNCoreMLModel(for: m)
        else { return nil }
        // Ultralytics writes names as a Python dict literal: "{0: 'person', 1: 'bicycle', ...}"
        let meta = m.modelDescription.metadata[.creatorDefinedKey] as? [String: String]
        let names = (meta?["names"] ?? "").matches(of: /'([^']*)'/).map { String($0.1) }
        return (v, names)
    }()
    static var hasObjectModel: Bool { objectModel != nil }
    static let objectThreshold: Float = 0.35

    /// YOLO26 end-to-end output [1, 300, 6]: x1, y1, x2, y2 in the 640-px (scale-filled, portrait) input, score,
    /// class. Already de-duplicated, so no NMS.
    private static func yoloObjects(_ results: [VNObservation]?) -> [Detection] {
        guard let model = objectModel,
            let a = results?.compactMap({ $0 as? VNCoreMLFeatureValueObservation }).first?.featureValue.multiArrayValue,
            a.shape.count == 3, a.shape[2].intValue >= 6
        else { return [] }
        let side: Float = 640
        var out: [Detection] = []
        for i in 0..<a.shape[1].intValue {
            func v(_ j: Int) -> Float { a[[0, NSNumber(value: i), NSNumber(value: j)]].floatValue }
            let score = v(4)
            guard score >= objectThreshold else { continue }
            let cls = Int(v(5))
            let label = cls < model.names.count ? model.names[cls] : "class \(cls)"
            if label == "person" { continue }  // people come from Vision's dedicated (better) human detector
            let x1 = max(0, v(0) / side)
            let y1 = max(0, v(1) / side)
            let x2 = min(1, v(2) / side)
            let y2 = min(1, v(3) / side)
            out.append(
                Detection(
                    kind: "objects", label: label, x: Double(x1), y: Double(y1), w: Double(x2 - x1),
                    h: Double(y2 - y1), confidence: Double(score)))
        }
        return out
    }

    /// What the camera sees in the latest frame, with distance, bearing and world position when depth has it.
    func detect(kinds: Set<String>) throws -> (objects: [Detection], age: Double) {
        let l = try current()
        let age = Date().timeIntervalSince(l.at)
        var requests: [(String, VNImageBasedRequest)] = []
        if kinds.contains("people") {
            let r = VNDetectHumanRectanglesRequest()
            r.upperBodyOnly = false
            requests.append(("people", r))
        }
        if kinds.contains("faces") { requests.append(("faces", VNDetectFaceRectanglesRequest())) }
        if kinds.contains("hands") {
            let r = VNDetectHumanHandPoseRequest()
            r.maximumHandCount = 4
            requests.append(("hands", r))
        }
        if kinds.contains("animals") { requests.append(("animals", VNRecognizeAnimalsRequest())) }
        if kinds.contains("objects"), let model = Self.objectModel?.model {
            let r = VNCoreMLRequest(model: model)
            r.imageCropAndScaleOption = .scaleFill
            requests.append(("objects", r))
        }
        if kinds.contains("text") {
            let r = VNRecognizeTextRequest()
            r.recognitionLevel = .accurate
            requests.append(("text", r))
        }
        if kinds.contains("codes") { requests.append(("codes", VNDetectBarcodesRequest())) }
        let handler = VNImageRequestHandler(cvPixelBuffer: l.image, orientation: .right)
        try handler.perform(requests.map(\.1))
        var out: [Detection] = []
        for (kind, req) in requests {
            if kind == "objects" {
                out += Self.yoloObjects(req.results)
                continue
            }
            for obs in req.results ?? [] {
                guard let box = Self.box(obs) else { continue }
                // Vision boxes are normalized with the origin bottom-left; ours is top-left.
                out.append(
                    Detection(
                        kind: kind, label: Self.label(obs), x: box.minX, y: 1 - box.maxY, w: box.width,
                        h: box.height, confidence: Double(obs.confidence)))
            }
        }
        Self.place(&out, in: l)
        return (out, age)
    }

    /// Adds bearing and elevation, and (with depth) distance and world position, to boxes found in frame `l`.
    private static func place(_ out: inout [Detection], in l: Latest) {
        for i in out.indices {
            let cx = out[i].x + out[i].w / 2
            let cy = out[i].y + out[i].h / 2
            (out[i].bearingDeg, out[i].elevationDeg) = Self.angles(l, Self.ray(l, cx, cy))
        }
        if let d = l.depth {
            DepthMap.read(d, l.confidence) { m in
                for i in out.indices {
                    let cx = out[i].x + out[i].w / 2
                    let cy = out[i].y + out[i].h / 2
                    let (sx, sy) = Self.sensor(cx, cy)
                    out[i].metres = m.sample(sx, sy, radius: 3).metres
                    if let md = out[i].metres { out[i].world = Self.worldPoint(l, cx, cy, depth: md) }
                }
            }
        }
    }

    // ---- frames for the on-device vision model -----------------------------------------------------------------

    /// One frame kept for the vision model: its RGB pixels plus the depth and pose of that same moment, so boxes the
    /// model finds seconds later are placed where things were when the picture was taken.
    struct Frame: @unchecked Sendable {
        fileprivate let latest: Latest
        let rgb: [UInt8]
        let width: Int
        let height: Int
    }

    func capture(maxSide: Int) throws -> Frame {
        let l = try current()
        let image = portrait(l, maxSide: maxSide)
        let w = Int(image.extent.width.rounded(.down))
        let h = Int(image.extent.height.rounded(.down))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        ci.render(
            image, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return Frame(latest: l, rgb: rgb, width: w, height: h)
    }

    /// Boxes (normalized portrait, top-left origin) that something else (the vision model) found in `frame`, placed
    /// in the world the way `detect` places its own.
    func place(_ boxes: [(label: String, x: Double, y: Double, w: Double, h: Double)], in frame: Frame) -> [Detection] {
        var out = boxes.map {
            Detection(kind: "located", label: $0.label, x: $0.x, y: $0.y, w: $0.w, h: $0.h, confidence: 1)
        }
        Self.place(&out, in: frame.latest)
        return out
    }

    // ---- tracking (companion mode: follow Tony from frame to frame) -------------------------------------------

    /// Vision's object tracker, seeded with one box (from the vision model or the caller) and stepped once per
    /// frame. Milliseconds per step, so it can run at 10 Hz where the vision model takes seconds.
    private var tracker: (request: VNTrackObjectRequest, handler: VNSequenceRequestHandler, label: String)?

    var tracking: Bool { lock.withLock { tracker != nil } }

    func startTracking(label: String, x: Double, y: Double, w: Double, h: Double) {
        let box = CGRect(x: x, y: 1 - y - h, width: w, height: h)  // Vision: bottom-left origin
        let r = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
        r.trackingLevel = .accurate
        lock.withLock { tracker = (r, VNSequenceRequestHandler(), label) }
    }

    func stopTracking() { lock.withLock { tracker = nil } }

    /// One tracker step on the latest frame: where the target is now, placed in the world like `detect`'s boxes.
    /// Confidence falls toward 0 when the tracker loses it. Call from one task only.
    func trackStep() throws -> Detection? {
        guard let t = lock.withLock({ tracker }) else { return nil }
        let l = try current()
        try t.handler.perform([t.request], on: l.image, orientation: .right)
        guard let obs = t.request.results?.first as? VNDetectedObjectObservation else { return nil }
        t.request.inputObservation = obs
        let b = obs.boundingBox
        var out = [
            Detection(
                kind: "tracked", label: t.label, x: b.minX, y: 1 - b.maxY, w: b.width, h: b.height,
                confidence: Double(obs.confidence))
        ]
        Self.place(&out, in: l)
        return out[0]
    }

    private static func label(_ obs: VNObservation) -> String? {
        if let o = obs as? VNRecognizedObjectObservation { return o.labels.first?.identifier.lowercased() }
        if let t = obs as? VNRecognizedTextObservation { return t.topCandidates(1).first?.string }
        if let b = obs as? VNBarcodeObservation {
            return [
                b.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: ""), b.payloadStringValue,
            ]
            .compactMap { $0 }.joined(separator: ": ")
        }
        return nil
    }

    private static func box(_ obs: VNObservation) -> CGRect? {
        if let r = obs as? VNDetectedObjectObservation { return r.boundingBox }
        if let r = obs as? VNRectangleObservation { return r.boundingBox }
        if let hand = obs as? VNHumanHandPoseObservation,
            let pts = try? hand.recognizedPoints(.all).values.filter({ $0.confidence > 0.3 }), !pts.isEmpty
        {
            let xs = pts.map(\.location.x)
            let ys = pts.map(\.location.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        return nil
    }
}

private func cm(_ v: Double) -> Double { (v * 100).rounded() / 100 }

/// Read access to a LiDAR depth map (Float32 metres) and its confidence map (UInt8 0–2), both in sensor orientation.
/// Only valid inside `DepthMap.read`, which keeps the buffers locked.
private struct DepthMap {
    let depth: UnsafePointer<Float32>
    let conf: UnsafePointer<UInt8>?
    let width, height, depthStride, confStride: Int

    static func read<T>(_ d: CVPixelBuffer, _ c: CVPixelBuffer?, _ body: (DepthMap) -> T) -> T {
        CVPixelBufferLockBaseAddress(d, .readOnly)
        if let c { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(d, .readOnly)
            if let c { CVPixelBufferUnlockBaseAddress(c, .readOnly) }
        }
        let m = DepthMap(
            depth: CVPixelBufferGetBaseAddress(d)!.assumingMemoryBound(to: Float32.self),
            conf: c.flatMap { CVPixelBufferGetBaseAddress($0)?.assumingMemoryBound(to: UInt8.self) },
            width: CVPixelBufferGetWidth(d), height: CVPixelBufferGetHeight(d),
            depthStride: CVPixelBufferGetBytesPerRow(d) / MemoryLayout<Float32>.size,
            confStride: c.map(CVPixelBufferGetBytesPerRow) ?? 0)
        return body(m)
    }

    private func value(_ px: Int, _ py: Int) -> (Float32, UInt8)? {
        let v = depth[py * depthStride + px]
        let c = conf?[py * confStride + px] ?? 2
        guard v.isFinite, v > 0, c >= 1 else { return nil }  // drop low-confidence pixels
        return (v, c)
    }

    /// Median depth in a (2r+1)² patch around normalized (sx, sy).
    func sample(_ sx: Double, _ sy: Double, radius r: Int) -> (metres: Double?, confidence: Int) {
        let cx = min(width - 1, max(0, Int(sx * Double(width))))
        let cy = min(height - 1, max(0, Int(sy * Double(height))))
        var vals: [(Float32, UInt8)] = []
        for py in max(0, cy - r)...min(height - 1, cy + r) {
            for px in max(0, cx - r)...min(width - 1, cx + r) {
                if let v = value(px, py) { vals.append(v) }
            }
        }
        guard !vals.isEmpty else { return (nil, 0) }
        vals.sort { $0.0 < $1.0 }
        let mid = vals[vals.count / 2]
        return ((Double(mid.0) * 100).rounded() / 100, Int(mid.1))
    }

    /// 5th-percentile depth in a normalized sensor rectangle: "nearest thing", robust to single noisy pixels.
    func nearest(_ xs: Range<Double>, _ ys: Range<Double>) -> Double? {
        let x0 = Int(xs.lowerBound * Double(width))
        let x1 = max(x0 + 1, Int(xs.upperBound * Double(width)))
        let y0 = Int(ys.lowerBound * Double(height))
        let y1 = max(y0 + 1, Int(ys.upperBound * Double(height)))
        var vals: [Float32] = []
        for py in max(0, y0)..<min(height, y1) {
            for px in max(0, x0)..<min(width, x1) {
                if let v = value(px, py) { vals.append(v.0) }
            }
        }
        guard vals.count >= 10 else { return nil }
        vals.sort()
        return (Double(vals[vals.count / 20]) * 100).rounded() / 100
    }
}
