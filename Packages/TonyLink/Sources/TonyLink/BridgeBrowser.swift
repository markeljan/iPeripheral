import Foundation
import Network

/// Finds the bridge on the LAN via Bonjour (`_tonypi-phone._tcp`) and resolves it to a ws:// URL.
public enum BridgeBrowser {
    public static let serviceType = "_tonypi-phone._tcp"

    /// The first bridge found within `timeout` seconds, or nil.
    public static func find(timeout: TimeInterval = 5) async -> URL? {
        await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
            let once = Once(cont)
            browser.browseResultsChangedHandler = { results, _ in
                guard let result = results.first else { return }
                resolve(result.endpoint) { url in
                    if let url { once.resume(url) }
                    browser.cancel()
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { once.resume(nil) }
            }
            browser.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                browser.cancel()
                once.resume(nil)
            }
        }
    }

    /// Resolve a Bonjour endpoint to host:port by opening (and dropping) a TCP connection to it. IPv4 only: a
    /// link-local IPv6 address needs its zone, which ws:// URLs can't carry reliably.
    private static func resolve(_ endpoint: NWEndpoint, done: @escaping @Sendable (URL?) -> Void) {
        let params = NWParameters.tcp
        (params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let conn = NWConnection(to: endpoint, using: params)
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = conn.currentPath?.remoteEndpoint {
                    var h = "\(host)"
                    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                    done(URL(string: "ws://\(h):\(port.rawValue)/"))
                } else {
                    done(nil)
                }
                conn.cancel()
            case .failed, .cancelled:
                done(nil)
            default:
                break
            }
        }
        conn.start(queue: .global())
    }
}

/// Resumes a continuation at most once, from any thread.
private final class Once<T: Sendable>: @unchecked Sendable {
    private var cont: CheckedContinuation<T, Never>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }

    func resume(_ value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}
