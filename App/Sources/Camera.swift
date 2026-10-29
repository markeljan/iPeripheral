@preconcurrency import AVFoundation
import CoreImage
import UIKit

/// Back wide camera, always capturing at low rate; `snapshot` encodes the latest frame (no shutter delay).
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible {
        case unavailable, denied, noFrame
        var description: String {
            switch self {
            case .unavailable: "no camera on this device"
            case .denied: "camera permission denied"
            case .noFrame: "no camera frame yet"
            }
        }
    }

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera")
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestAt = Date.distantPast
    private let ci = CIContext()
    private(set) var running = false

    func start() async throws {
        if running { return }
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw Failure.denied }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device)
        else { throw Failure.unavailable }
        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90  // portrait, as mounted
        }
        try? device.lockForConfiguration()
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)  // battery + heat: 15 fps is plenty
        device.unlockForConfiguration()
        session.commitConfiguration()
        queue.async { [session] in session.startRunning() }
        running = true
    }

    func captureOutput(
        _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = px
        latestAt = Date()
        lock.unlock()
    }

    /// JPEG of the latest frame, longest side scaled down to `maxSide`.
    func snapshot(maxSide: Int, quality: Double) throws -> (jpeg: Data, width: Int, height: Int, age: Double) {
        lock.lock()
        let px = latest
        let at = latestAt
        lock.unlock()
        guard let px else { throw running ? Failure.noFrame : Failure.unavailable }
        var image = CIImage(cvPixelBuffer: px)
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
        return (jpeg, Int(image.extent.width), Int(image.extent.height), Date().timeIntervalSince(at))
    }
}
