import XCTest

/// **V3-2a2 S2.** The `glow` command's wire format and the rule the simulator's stand-in device answers it
/// by. Both live next to the protocol rather than in `FakeDeviceLink`, which needs CoreBluetooth and cannot
/// be compiled into this target.
final class DeviceProtocolTests: XCTestCase {
    func testTheGlowLineIsTheOneTheFirmwareExpects() {
        let line = DeviceCommand.glow(id: "g1", ms: 300, kind: "sweep").line
        XCTAssertEqual(line, "{\"id\":\"g1\",\"kind\":\"sweep\",\"ms\":300,\"t\":\"glow\"}\n")
        XCTAssertEqual(DeviceCommand.glow(id: "g1", ms: 300, kind: "sweep").typeName, "glow")
        XCTAssertEqual(DeviceCommand.glow(id: "g7", ms: 300, kind: "sweep").id, "g7")
        // `ms` is clamped on the way out: the protocol's own ceiling is 1000.
        XCTAssertTrue(DeviceCommand.glow(id: "g2", ms: 5000, kind: "flash").line.contains("\"ms\":1000"))
        XCTAssertTrue(DeviceCommand.glow(id: "g3", ms: 0, kind: "flash").line.contains("\"ms\":1"))
        XCTAssertTrue(DeviceCommand.glow(id: "g4", ms: 120, kind: "flash").line.contains("\"kind\":\"flash\""))
    }

    /// The fake link answers `glow` 80 ms later, like it answers `strip` — the two commands the plan's
    /// scan smoke chains together — while the two handshake commands keep their own choreography.
    func testTheFakeLinkAcksGlowLikeStrip() {
        XCTAssertEqual(DeviceCommand.glow(id: "g1", ms: 300, kind: "sweep").fakeAckDelayMilliseconds, 80)
        XCTAssertEqual(DeviceCommand.ping(id: "v1").fakeAckDelayMilliseconds, 40)
        XCTAssertEqual(DeviceCommand.playCue(id: "v1", cue: "connect").fakeAckDelayMilliseconds, 40)
        XCTAssertEqual(DeviceCommand.setMode(id: "v1", mode: .ar).fakeAckDelayMilliseconds, 40)
        XCTAssertNil(DeviceCommand.setTheme(id: "v1", theme: "base").fakeAckDelayMilliseconds)
        XCTAssertNil(DeviceCommand.strip(id: "v1", text: "♥12").fakeAckDelayMilliseconds)
        XCTAssertNil(DeviceCommand.ack(id: "v1", ok: true, err: nil).fakeAckDelayMilliseconds)
    }

    /// Nothing else on the wire moved: the existing commands still encode exactly as they did.
    func testTheOtherCommandsAreUnchanged() {
        XCTAssertEqual(DeviceCommand.strip(id: "v9", text: nil).line, "{\"id\":\"v9\",\"t\":\"strip\"}\n")
        XCTAssertEqual(DeviceCommand.playCue(id: "v2", cue: "connect").line,
                       "{\"cue\":\"connect\",\"id\":\"v2\",\"t\":\"play_cue\"}\n")
        XCTAssertEqual(DeviceCommand.setMode(id: "v3", mode: .ar).line,
                       "{\"id\":\"v3\",\"mode\":\"ar\",\"t\":\"set_mode\"}\n")
    }

    /// An `ack` with `ok:false err:"unknown"` is how an 0.1.x build refuses a command it has never heard of
    /// — the signal `DeviceCoordinator` turns off `glow` on for the rest of the session.
    func testAnUnknownAckParses() {
        let message = DeviceMessage.parse(line: "{\"t\":\"ack\",\"id\":\"v2\",\"ok\":false,\"err\":\"unknown\"}")
        XCTAssertEqual(message, .ack(id: "v2", ok: false, err: "unknown", theme: nil))
    }
}
