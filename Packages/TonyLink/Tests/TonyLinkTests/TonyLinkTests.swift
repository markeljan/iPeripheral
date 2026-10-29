import Foundation
import Testing

@testable import TonyLink

@Test func decodesRobotState() throws {
    let json = #"""
        {"type":"robot_state","state":{"busy":true,"job":{"id":3,"skill":"wave","state":"running"},
         "tilt_deg":4.5,"lying":false,"asleep":false,"battery_mv":11560,"torque_on":16,
         "hottest":[6,"left elbow",71],"camera":{"ok":true}}}
        """#
    guard case .robotState(let s) = try Incoming(json: Data(json.utf8)) else {
        Issue.record("not robot_state")
        return
    }
    #expect(s.busy)
    #expect(s.skill == "wave")
    #expect(s.batteryVolts == 11.56)
    #expect(s.torqueOn == 16)
    #expect(s.hottest?.joint == "left elbow")
    #expect(s.hottest?.celsius == 71)
}

@Test func decodesRequestArgsWithoutEnvelope() throws {
    let json = #"{"type":"request","rid":7,"op":"snapshot","max_side":1280,"quality":0.7}"#
    let msg = try Incoming(json: Data(json.utf8))
    #expect(msg == .request(rid: 7, op: "snapshot", args: ["max_side": 1280, "quality": 0.7]))
}

@Test func decodesAuthMessages() throws {
    #expect(
        try Incoming(json: Data(#"{"type":"welcome","robot":"tonypi","bridge":"0.1.0","token":"t"}"#.utf8))
            == .welcome(robot: "tonypi", bridge: "0.1.0", token: "t"))
    #expect(
        try Incoming(json: Data(#"{"type":"error","error":"wrong code","tries_left":2}"#.utf8))
            == .error("wrong code", triesLeft: 2))
    #expect(try Incoming(json: Data(#"{"type":"something_new","x":1}"#.utf8)) == .unknown(type: "something_new"))
}

@Test func encodesOutgoing() throws {
    let hello = String(decoding: try Outgoing.hello(token: "t", device: "iPhone", app: "0.1").jsonData(), as: UTF8.self)
    #expect(hello == #"{"app":"0.1","device":"iPhone","token":"t","type":"hello","v":1}"#)
    let reply = Outgoing.reply(rid: 4, ok: false, error: "no camera").object
    #expect(reply["type"] == "reply" && reply["rid"] == 4 && reply["ok"] == false && reply["error"] == "no camera")
    let status = Outgoing.status(PhoneStatus(battery: 0.5, charging: true, thermal: "nominal", caps: ["camera"])).object
    #expect(status["type"] == "status" && status["caps"] == ["camera"])
}

@Test func binaryFrameRoundTrip() throws {
    let frame = BinaryFrame(
        header: ["type": "reply", "rid": 1, "mime": "image/jpeg"], payload: Data([0xFF, 0xD8, 0x00]))
    let data = try frame.encoded()
    #expect(data.prefix(4) == Data([0, 0, 0, UInt8(data.count - 4 - 3)]))
    #expect(try BinaryFrame(decoding: data) == frame)
    #expect(try BinaryFrame(decoding: data.dropFirst(0)) == frame)  // slices keep working
    #expect(throws: BinaryFrame.DecodeError.self) { try BinaryFrame(decoding: Data([0, 0, 1, 0, 1])) }
}
