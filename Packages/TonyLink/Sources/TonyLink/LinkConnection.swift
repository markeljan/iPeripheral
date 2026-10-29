import Foundation

/// One WebSocket to the bridge. Reconnecting is the caller's job (see `PeripheralLink` in the app), so this stays
/// a thin, testable wrapper.
public final class LinkConnection: Sendable {
    public let url: URL
    private let task: URLSessionWebSocketTask

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 << 20
    }

    public func open() { task.resume() }

    public func close() { task.cancel(with: .normalClosure, reason: nil) }

    public func send(_ message: Outgoing) async throws {
        let data = try message.jsonData()
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func send(_ frame: BinaryFrame) async throws {
        try await task.send(.data(try frame.encoded()))
    }

    /// Incoming messages until the socket closes (the stream then finishes, or throws the socket error).
    public func messages() -> AsyncThrowingStream<Incoming, Error> {
        AsyncThrowingStream { continuation in
            let reader = Task { [task] in
                do {
                    while !Task.isCancelled {
                        switch try await task.receive() {
                        case .string(let s):
                            continuation.yield(try Incoming(json: Data(s.utf8)))
                        case .data(let d):  // the bridge sends no binary frames in v1; read the header anyway
                            continuation.yield(Incoming(object: try BinaryFrame(decoding: d).header))
                        @unknown default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in reader.cancel() }
        }
    }
}
