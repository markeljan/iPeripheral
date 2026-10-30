import SwiftUI

enum Face: String, CaseIterable, Sendable {
    case idle, listening, thinking, speaking, happy, sad, warn, asleep, offline
}

/// Tony's face: two eyes on black. Blinks on its own; shape and colour follow the mood. The eyes look toward `gaze`
/// (-1…1, x right, y down: the person looking at the screen) or wander slowly when nobody is there.
struct FaceView: View {
    let face: Face
    var gaze: CGPoint? = nil

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                draw(ctx: ctx, size: size, t: t)
            }
        }
        .background(.black)
        .animation(.easeInOut(duration: 0.25), value: face)
    }

    private var color: Color {
        switch face {
        case .warn: .orange
        case .sad: .blue
        case .offline: .gray.opacity(0.5)
        case .listening: .cyan
        default: .white
        }
    }

    private func draw(ctx: GraphicsContext, size: CGSize, t: Double) {
        let w = size.width
        let h = size.height
        let eyeW = w * 0.22
        let gap = w * 0.16
        let cy = h * 0.42
        let blink = (t.truncatingRemainder(dividingBy: 4.2)) < 0.12  // a blink every ~4 s
        var eyeH: CGFloat = eyeW * 1.25
        var dy: CGFloat = 0
        switch face {
        case .asleep, .offline: eyeH = eyeW * 0.1
        case .happy: eyeH = eyeW * 0.6
        case .thinking: dy = -h * 0.03 + CGFloat(sin(t * 2)) * 4
        case .listening: eyeH *= 1.1 + 0.05 * CGFloat(sin(t * 6))
        default: break
        }
        if blink && face != .asleep && face != .offline { eyeH = eyeW * 0.08 }
        let look =
            gaze
            ?? CGPoint(x: 0.35 * sin(t * 0.23) + 0.15 * sin(t * 0.71), y: 0.25 * sin(t * 0.17))
        let lookX = face == .offline || face == .asleep ? 0 : look.x * w * 0.08
        let lookY = face == .offline || face == .asleep ? 0 : look.y * h * 0.05

        for side in [-1.0, 1.0] {
            let cx = w / 2 + CGFloat(side) * (gap / 2 + eyeW / 2) + lookX
            let rect = CGRect(x: cx - eyeW / 2, y: cy - eyeH / 2 + dy + lookY, width: eyeW, height: eyeH)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(eyeW, eyeH) / 2), with: .color(color))
        }
        if face == .speaking {  // mouth bar that moves while talking
            let mh = 6 + 14 * abs(CGFloat(sin(t * 11)))
            let mouth = CGRect(x: w / 2 - w * 0.12, y: h * 0.66 - mh / 2, width: w * 0.24, height: mh)
            ctx.fill(Path(roundedRect: mouth, cornerRadius: mh / 2), with: .color(color))
        }
    }
}

#Preview {
    FaceView(face: .speaking)
}
