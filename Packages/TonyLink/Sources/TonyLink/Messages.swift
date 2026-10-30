import Foundation

/// Protocol v1, see docs/protocol.md.
public let protocolVersion = 1

/// Bridge → phone.
public enum Incoming: Sendable, Equatable {
    case welcome(robot: String, bridge: String, token: String?)
    case pairCodeSent
    case error(String, triesLeft: Int?)
    case robotState(RobotState)
    case robotEvent(JSONValue)
    case agentEvent(JSONValue)
    case request(rid: Int, op: String, args: [String: JSONValue])
    /// Words and phrases for speech recognition to favour (the robot's skill names).
    case vocabulary([String])
    case unknown(type: String)

    public init(json data: Data) throws {
        let obj = try JSONDecoder().decode([String: JSONValue].self, from: data)
        self.init(object: obj)
    }

    public init(object o: [String: JSONValue]) {
        let type = o["type"]?.string ?? ""
        switch type {
        case "welcome":
            self = .welcome(
                robot: o["robot"]?.string ?? "", bridge: o["bridge"]?.string ?? "",
                token: o["token"]?.string)
        case "pair_code_sent":
            self = .pairCodeSent
        case "error":
            self = .error(o["error"]?.string ?? "error", triesLeft: o["tries_left"]?.int)
        case "robot_state":
            self = .robotState(RobotState(o["state"] ?? .null))
        case "robot_event":
            self = .robotEvent(o["event"] ?? .null)
        case "agent_event":
            self = .agentEvent(o["event"] ?? .null)
        case "vocabulary":
            self = .vocabulary(o["words"]?.array?.compactMap(\.string) ?? [])
        case "request":
            var args = o
            args["type"] = nil
            args["rid"] = nil
            args["op"] = nil
            self = .request(rid: o["rid"]?.int ?? -1, op: o["op"]?.string ?? "", args: args)
        default:
            self = .unknown(type: type)
        }
    }
}

/// Phone → bridge.
public enum Outgoing: Sendable, Equatable {
    case hello(token: String, device: String, app: String)
    case pairRequest(device: String)
    case pairConfirm(code: String)
    case stop
    case command(text: String)
    /// A finished phrase the phone's ears heard, whatever it was (for logs and tuning the wake word).
    case transcript(text: String)
    /// Something the phone noticed on its own: `fall`, `impact`, `freefall`, `upright` (motion) or `sound`.
    case event(kind: String, fields: [String: JSONValue])
    /// The phone's ARKit pose, streamed ~10 Hz so the bridge always has a fresh one.
    case pose(fields: [String: JSONValue])
    case status(PhoneStatus)
    case reply(rid: Int, ok: Bool, error: String? = nil, fields: [String: JSONValue] = [:])

    public var object: [String: JSONValue] {
        switch self {
        case .hello(let token, let device, let app):
            return [
                "type": "hello", "v": .number(Double(protocolVersion)), "token": .string(token),
                "device": .string(device), "app": .string(app),
            ]
        case .pairRequest(let device):
            return ["type": "pair_request", "v": .number(Double(protocolVersion)), "device": .string(device)]
        case .pairConfirm(let code):
            return ["type": "pair_confirm", "code": .string(code)]
        case .stop:
            return ["type": "stop"]
        case .command(let text):
            return ["type": "command", "text": .string(text)]
        case .transcript(let text):
            return ["type": "transcript", "text": .string(text)]
        case .event(let kind, let fields):
            var o = fields
            o["type"] = "event"
            o["kind"] = .string(kind)
            return o
        case .pose(let fields):
            var o = fields
            o["type"] = "pose"
            return o
        case .status(let s):
            var o = s.object
            o["type"] = "status"
            return o
        case .reply(let rid, let ok, let error, let fields):
            var o = fields
            o["type"] = "reply"
            o["rid"] = .number(Double(rid))
            o["ok"] = .bool(ok)
            if let error { o["error"] = .string(error) }
            return o
        }
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        return try enc.encode(object)
    }
}

/// Phone health, sent every few seconds and in reply to a `status` request.
public struct PhoneStatus: Sendable, Equatable {
    public var battery: Double?
    public var charging: Bool
    public var thermal: String
    public var caps: [String]
    /// "mounted" (on Tony: his senses and face) or "companion" (on a stand, watching Tony from outside).
    public var mode: String

    public init(battery: Double?, charging: Bool, thermal: String, caps: [String], mode: String = "mounted") {
        self.battery = battery
        self.charging = charging
        self.thermal = thermal
        self.caps = caps
        self.mode = mode
    }

    public var object: [String: JSONValue] {
        [
            "battery": battery.map { .number($0) } ?? .null, "charging": .bool(charging),
            "thermal": .string(thermal), "caps": .array(caps.map { .string($0) }), "mode": .string(mode),
        ]
    }
}

/// Typed view of tonyd's `state` dict. `raw` keeps everything, typed fields cover what the app shows.
public struct RobotState: Sendable, Equatable {
    public let raw: JSONValue

    public init(_ raw: JSONValue) { self.raw = raw }

    public var busy: Bool { raw["busy"]?.bool ?? false }
    public var skill: String? { raw["job"]?["skill"]?.string }
    public var tiltDeg: Double? { raw["tilt_deg"]?.double }
    public var lying: Bool { raw["lying"]?.bool ?? false }
    public var asleep: Bool { raw["asleep"]?.bool ?? false }
    public var batteryVolts: Double? { raw["battery_mv"]?.double.map { $0 / 1000 } }
    public var torqueOn: Int? { raw["torque_on"]?.int }
    /// [id, joint, °C] of the hottest servo.
    public var hottest: (joint: String, celsius: Double)? {
        guard let a = raw["hottest"]?.array, a.count >= 3, let j = a[1].string, let t = a[2].double else { return nil }
        return (j, t)
    }
}
