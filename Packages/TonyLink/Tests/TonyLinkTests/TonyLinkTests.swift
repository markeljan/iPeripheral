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
    #expect(
        try Incoming(json: Data(#"{"type":"vocabulary","words":["wave","walk forward"]}"#.utf8))
            == .vocabulary(["wave", "walk forward"]))
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

@Test func listenerWakeWordAndCommand() {
    var l = Listener()
    #expect(l.hear("Hey Tony", isFinal: false) == .wake)
    #expect(l.hear("Hey Tony, wave", isFinal: true) == .command("wave"))
    #expect(l.hear("what a nice day", isFinal: true) == .none)
}

@Test func listenerFollowUpAfterBareWakeWord() {
    let t0 = Date()
    var l = Listener()
    #expect(l.hear("Tony.", isFinal: true, now: t0) == .wake)
    #expect(
        l.hear("walk forward two steps", isFinal: true, now: t0.addingTimeInterval(2))
            == .command("walk forward two steps"))
    #expect(l.hear("Tony", isFinal: true, now: t0) == .wake)
    #expect(l.hear("too late", isFinal: true, now: t0.addingTimeInterval(10)) == .none)
}

@Test func listenerSnapsNearMissesToSkillWords() {
    var l = Listener()
    l.setVocabulary(["wave", "bow", "step in place", "turn left"])
    #expect(l.hear("Tony Bo.", isFinal: true) == .command("bow"))
    #expect(l.hear("Hey Tony, wade please", isFinal: true) == .command("wave please"))
    #expect(l.hear("Tony, step and place", isFinal: true) == .command("step and place"))  // "and" isn't near a skill word
    #expect(l.hear("Tony, go home", isFinal: true) == .command("go home"))
}

@Test func listenerStopsOncePerSegmentWithoutWakeWord() {
    var l = Listener()
    #expect(l.hear("stop", isFinal: false) == .stop)
    #expect(l.hear("stop stop", isFinal: false) == .none)  // the same phrase, still being transcribed
    #expect(l.hear("stop stop Tony wave", isFinal: true) == .none)
    #expect(l.hear("Freeze!", isFinal: true) == .stop)  // a new segment
}

@Test func groundingParsesLFMBoxes() {
    let text = """
        Here you go:
        ```json
        [{"bbox_2d": [100, 200, 300, 600], "label": "red mug"}, {"bbox_2d": [500, 500, 400, 900], "label": "bad"}]
        ```
        """
    let boxes = Grounding.parse(text)  // the second box has xmax < xmin and is dropped
    #expect(boxes.count == 1 && boxes[0].label == "red mug")
    #expect(abs(boxes[0].x - 0.1) < 1e-9 && abs(boxes[0].y - 0.2) < 1e-9)
    #expect(abs(boxes[0].w - 0.2) < 1e-9 && abs(boxes[0].h - 0.4) < 1e-9)
    #expect(Grounding.parse("[]").isEmpty)
    #expect(Grounding.parse("I can't see one.").isEmpty)
}
