import SwiftUI
import TonyLink

/// Full-screen face. Tap = stop the body. Long-press = debug overlay. Pairing sheet when the bridge asks for a code.
struct RootView: View {
    @Environment(PeripheralLink.self) private var link
    @State private var debug = false

    var body: some View {
        ZStack {
            FaceView(face: link.face)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { link.stop() }
                .onLongPressGesture(minimumDuration: 1) { debug.toggle() }
            if debug { DebugOverlay(close: { debug = false }) }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: .constant(needsCode)) { PairingView() }
    }

    private var needsCode: Bool {
        if case .needsCode = link.phase { return true }
        return false
    }
}

struct PairingView: View {
    @Environment(PeripheralLink.self) private var link
    @State private var code = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Pair with Tony").font(.title.bold())
            Text("Tony just said a 6-digit code out loud. (It's also in `journalctl -u tonypi-phone` on the Pi.)")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            TextField("123456", text: $code)
                .keyboardType(.numberPad)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .onChange(of: code) { _, new in
                    code = String(new.filter(\.isNumber).prefix(6))
                    if code.count == 6 { link.pair(code: code) }
                }
            if case .needsCode(let error?) = link.phase {
                Text(error).foregroundStyle(.red)
            }
        }
        .padding(32)
        .interactiveDismissDisabled()
        .onChange(of: link.phase) { _, _ in code = "" }
    }
}

struct DebugOverlay: View {
    @Environment(PeripheralLink.self) private var link
    let close: () -> Void
    @State private var url = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tony Eyes \(PeripheralLink.appVersion)").font(.headline)
                Spacer()
                Button("Close", action: close)
            }
            row("link", phaseText)
            if let r = link.robot {
                row(
                    "robot", r.busy ? "running \(r.skill ?? "?")" : (r.asleep ? "asleep" : (r.lying ? "lying" : "idle"))
                )
                row("battery", r.batteryVolts.map { String(format: "%.2f V", $0) } ?? "–")
                row("tilt", r.tiltDeg.map { String(format: "%.0f°", $0) } ?? "–")
                row("torque", r.torqueOn.map { "\($0)/16 on" } ?? "–")
                if let h = r.hottest { row("hottest", "\(h.joint) \(Int(h.celsius)) °C") }
            }
            row("ears", link.earsState)
            row("phone heard", link.phoneHeard ?? "–")
            row("agent heard", link.lastHeard ?? "–")
            row("said", link.lastSaid ?? "–")
            row("requests", "\(link.requestsServed)")
            if let e = link.lastError { row("error", e) }
            TextField("ws://192.0.2.1:8766/ (blank = Bonjour)", text: $url)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                .onSubmit {
                    link.manualURL = url
                    link.reconnect()
                }
            HStack {
                Button("Reconnect") { link.reconnect() }
                Spacer()
                Button("Forget pairing", role: .destructive) { link.forgetPairing() }
            }
        }
        .font(.system(.footnote, design: .monospaced))
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding()
        .onAppear { url = link.manualURL }
    }

    private var phaseText: String {
        switch link.phase {
        case .searching: "searching (Bonjour)"
        case .connecting(let u): "connecting \(u)"
        case .needsCode: "waiting for pairing code"
        case .connected(let h): "connected \(h)"
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(v)
        }
    }
}
