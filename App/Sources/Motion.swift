import CoreMotion
import Foundation

/// The phone's own IMU at 50 Hz: tilt from upright (as mounted, portrait) and body events — a second opinion next
/// to tonyd's IMU, and the fastest way to notice a fall. Events are reported, never acted on: stopping is tonyd's job.
final class Motion: @unchecked Sendable {
    struct Event: Sendable {
        let kind: String  // "fall", "impact", "freefall", "upright"
        let value: Double
    }

    /// Called on the motion queue.
    var onEvent: (@Sendable (Event) -> Void)?

    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var _tiltDeg = 0.0
    private var _rollDeg = 0.0
    private var fallen = false
    private var tiltedSince: Date?
    private var freefallSince: Date?
    private var lastImpact = Date.distantPast

    /// Degrees away from upright (0 = standing, 90 = lying), and sideways lean (positive = leaning right).
    var tilt: (deg: Double, rollDeg: Double, fallen: Bool) { lock.withLock { (_tiltDeg, _rollDeg, fallen) } }

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        queue.maxConcurrentOperationCount = 1
        manager.deviceMotionUpdateInterval = 1.0 / 50
        manager.startDeviceMotionUpdates(to: queue) { [weak self] m, _ in
            if let m { self?.update(m) }
        }
    }

    private func update(_ m: CMDeviceMotion) {
        let g = m.gravity  // device frame, unit-ish; upright portrait is (0, -1, 0)
        let tilt = acos(max(-1, min(1, -g.y))) * 180 / .pi
        let roll = atan2(g.x, -g.y) * 180 / .pi
        let a = m.userAcceleration
        let accel = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
        let total = ((a.x + g.x) * (a.x + g.x) + (a.y + g.y) * (a.y + g.y) + (a.z + g.z) * (a.z + g.z)).squareRoot()
        let now = Date()
        var events: [Event] = []
        lock.withLock {
            _tiltDeg = tilt
            _rollDeg = roll
            // Fallen: more than 60° from upright for half a second; back up once under 30°.
            if tilt > 60 {
                tiltedSince = tiltedSince ?? now
                if !fallen, now.timeIntervalSince(tiltedSince!) > 0.5 {
                    fallen = true
                    events.append(Event(kind: "fall", value: (tilt * 10).rounded() / 10))
                }
            } else {
                tiltedSince = nil
                if fallen, tilt < 30 {
                    fallen = false
                    events.append(Event(kind: "upright", value: (tilt * 10).rounded() / 10))
                }
            }
            // Free fall: total acceleration under 0.35 g for 80 ms (dropped, or falling over fast).
            if total < 0.35 {
                freefallSince = freefallSince ?? now
                if now.timeIntervalSince(freefallSince!) > 0.08 {
                    events.append(Event(kind: "freefall", value: (total * 100).rounded() / 100))
                    freefallSince = .distantFuture
                }
            } else {
                freefallSince = nil
            }
            // Impact: a 2.5 g jolt (hit the floor, bumped into something), at most once a second.
            if accel > 2.5, now.timeIntervalSince(lastImpact) > 1 {
                lastImpact = now
                events.append(Event(kind: "impact", value: (accel * 10).rounded() / 10))
            }
        }
        for e in events { onEvent?(e) }
    }
}
