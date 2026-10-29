import Foundation

/// Binary WebSocket frame: `[u32 big-endian header length][header JSON][payload]`.
public struct BinaryFrame: Sendable, Equatable {
    public var header: [String: JSONValue]
    public var payload: Data

    public init(header: [String: JSONValue], payload: Data) {
        self.header = header
        self.payload = payload
    }

    public enum DecodeError: Error { case tooShort, badHeaderLength }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let h = try enc.encode(header)
        var out = Data(capacity: 4 + h.count + payload.count)
        let n = UInt32(h.count).bigEndian
        withUnsafeBytes(of: n) { out.append(contentsOf: $0) }
        out.append(h)
        out.append(payload)
        return out
    }

    public init(decoding data: Data) throws {
        guard data.count >= 4 else { throw DecodeError.tooShort }
        let bytes = [UInt8](data.prefix(4))
        let n = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        guard data.count >= 4 + n else { throw DecodeError.badHeaderLength }
        let start = data.startIndex
        header = try JSONDecoder().decode([String: JSONValue].self, from: data[(start + 4)..<(start + 4 + n)])
        payload = Data(data[(start + 4 + n)...])
    }
}
