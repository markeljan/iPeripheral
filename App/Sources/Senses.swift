@preconcurrency import ARKit
import CoreImage
import UIKit
import Vision

/// The phone's eyes: one ARKit session gives the camera image, LiDAR depth and the phone's pose together (ARKit
/// owns the back camera, so there is no separate AVCaptureSession). Keeps only the latest frame; every query
/// answers from it, so nothing waits for a shutter.
///
/// Coordinates: `x, y` are normalized 0–1 in the portrait image the snapshot returns, origin top-left. World pose:
/// metres, y up, origin where tracking started; yaw is degrees, positive = turned left.
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
        var tracking: String
        var at: Date
    }

    static var supported: Bool { ARWorldTrackingConfiguration.isSupported }
    static var hasLiDAR: Bool { ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) }

    private let session = ARSession()
    private let queue = DispatchQueue(label: "senses")
    private let lock = NSLock()
    private var latest: Latest?
    private let ci = CIContext()
    private(set) var running = false

    func start() {
        guard Self.supported, !running else { return }
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if Self.hasLiDAR { config.frameSemantics.insert(.smoothedSceneDepth) }
        // Lowest frame rate at full image size: plenty for a walking robot, and much cooler than 60 fps.
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        if let f = formats.filter({ $0.imageResolution.width >= 1920 }).min(by: {
            $0.framesPerSecond < $1.framesPerSecond
        }) {
            config.videoFormat = f
        }
        session.delegate = self
        session.delegateQueue = queue
        session.run(config)
        running = true
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
            transform: frame.camera.transform, tracking: tracking, at: Date())
        lock.withLock { latest = l }
    }

    private func current() throws -> Latest {
        guard let l = lock.withLock({ latest }) else { throw running ? Failure.noFrame : Failure.unavailable }
        return l
    }

    // ---- snapshot -----------------------------------------------------------------------------------------------

    struct Snapshot {
        let jpeg: Data
        let width: Int
        let height: Int
        let age: Double
    }

    /// JPEG of the latest frame, portrait, longest side scaled down to `maxSide`.
    func snapshot(maxSide: Int, quality: Double) throws -> Snapshot {
        let l = try current()
        var image = CIImage(cvPixelBuffer: l.image).oriented(.right)  // sensor is landscape; mounted phone is portrait
        image = image.transformed(by: .init(translationX: -image.extent.minX, y: -image.extent.minY))
        let side = max(image.extent.width, image.extent.height)
        if side > CGFloat(maxSide) {
            let s = CGFloat(maxSide) / side
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        guard
            let jpeg = ci.jpegRepresentation(
                of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
        else { throw Failure.noFrame }
        return Snapshot(
            jpeg: jpeg, width: Int(image.extent.width.rounded()), height: Int(image.extent.height.rounded()),
            age: Date().timeIntervalSince(l.at))
    }

    // ---- depth --------------------------------------------------------------------------------------------------

    /// Portrait (x, y) → landscape sensor (sx, sy); the sensor image is the portrait image turned 90° anticlockwise.
    private static func sensor(_ x: Double, _ y: Double) -> (Double, Double) { (y, 1 - x) }

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

    struct Detection {
        let kind: String
        let x, y, w, h, confidence: Double
        var metres: Double?
    }

    static let detectKinds = ["people", "faces", "hands"]

    /// People, faces and hands in the latest frame, with the distance to each box's centre when depth is available.
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
        let handler = VNImageRequestHandler(cvPixelBuffer: l.image, orientation: .right)
        try handler.perform(requests.map(\.1))
        var out: [Detection] = []
        for (kind, req) in requests {
            for obs in req.results ?? [] {
                guard let box = Self.box(obs) else { continue }
                // Vision boxes are normalized with the origin bottom-left; ours is top-left.
                out.append(
                    Detection(
                        kind: kind, x: box.minX, y: 1 - box.maxY, w: box.width, h: box.height,
                        confidence: Double(obs.confidence)))
            }
        }
        if let d = l.depth {
            DepthMap.read(d, l.confidence) { m in
                for i in out.indices {
                    let (sx, sy) = Self.sensor(out[i].x + out[i].w / 2, out[i].y + out[i].h / 2)
                    out[i].metres = m.sample(sx, sy, radius: 3).metres
                }
            }
        }
        return (out, age)
    }

    private static func box(_ obs: VNObservation) -> CGRect? {
        if let r = obs as? VNDetectedObjectObservation { return r.boundingBox }
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
