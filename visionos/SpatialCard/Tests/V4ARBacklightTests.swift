import XCTest

/// **v4 B2 §3.1 — the AR session's backlight.** `--ar-backlight 100|85|keep` (default 100), sent after `set_mode ar`:
/// the flag's rule, the log line the next headset round greps, and the wire format the firmware's `proto.c` parses
/// (`{"t":"backlight","id":…,"percent":N}`, `percent` 0–100 or `err:"percent"`).
final class V4ARBacklightTests: XCTestCase {
    /// The brief: 100 % (direct current) unless the flag says otherwise.
    func testTheDefaultIsAHundredPercentDirectCurrent() {
        XCTAssertEqual(V4.ARBacklight.default, .percent(100))
        XCTAssertEqual(V4.ARBacklight.default.percent, 100)
        XCTAssertEqual(V4.ARBacklight.drive(100), "DC")
        XCTAssertEqual(V4.ARBacklight.drive(85), "PWM")
    }

    func testTheFlagParsesThePercentsAndKeep() {
        XCTAssertEqual(V4.ARBacklight.parse("100"), .percent(100))
        XCTAssertEqual(V4.ARBacklight.parse("85"), .percent(85))
        XCTAssertEqual(V4.ARBacklight.parse("85%"), .percent(85))
        XCTAssertEqual(V4.ARBacklight.parse(" Keep "), .keep)
        XCTAssertNil(V4.ARBacklight.parse("keep")?.percent, "keep sends nothing")
    }

    /// 0 would blank the screen the object model was trained on, and the firmware refuses anything past 100.
    func testNonsenseIsRefusedRatherThanSent() {
        XCTAssertNil(V4.ARBacklight.parse("0"))
        XCTAssertNil(V4.ARBacklight.parse("101"))
        XCTAssertNil(V4.ARBacklight.parse("-5"))
        XCTAssertNil(V4.ARBacklight.parse("bright"))
        XCTAssertNil(V4.ARBacklight.parse(""))
    }

    /// The line the brief names, spelled exactly.
    func testTheSentLineSaysTheLevelAndTheDrive() {
        XCTAssertEqual(V4.ARBacklight.sentLine(100), "[ble] backlight 100 % (AR session, DC)")
        XCTAssertEqual(V4.ARBacklight.sentLine(85), "[ble] backlight 85 % (AR session, PWM)")
    }

    /// The trade-off the report has to state: at 100 the firmware's key blink can only go darker.
    func testTheBlinkNoteStatesTheTradeOff() {
        XCTAssertTrue(V4.ARBacklight.blinkNote(100).contains("dark"))
        XCTAssertTrue(V4.ARBacklight.blinkNote(85).contains("brightens"))
        XCTAssertTrue(V4.ARBacklight.percent(100).flagLine.contains("after set_mode ar"))
        XCTAssertTrue(V4.ARBacklight.keep.flagLine.contains("keep"))
    }

    /// The firmware's `proto_parse` reads `t`, `id` and an integer `percent`.
    func testTheWireFormatIsTheOneTheFirmwareParses() {
        let command = DeviceCommand.backlight(id: "v2", percent: 100)
        XCTAssertEqual(command.line, "{\"id\":\"v2\",\"percent\":100,\"t\":\"backlight\"}\n")
        XCTAssertEqual(command.typeName, "backlight")
        XCTAssertEqual(command.id, "v2")
        // Clamped rather than refused by the device.
        XCTAssertTrue(DeviceCommand.backlight(id: "v3", percent: 140).line.contains("\"percent\":100"))
        XCTAssertTrue(DeviceCommand.backlight(id: "v4", percent: -3).line.contains("\"percent\":0"))
    }

    /// The simulator's stand-in device answers it with a plain `ack`, like every command without a handshake.
    func testTheFakeLinkAcksIt() {
        XCTAssertEqual(DeviceCommand.backlight(id: "v2", percent: 100).fakeAckDelayMilliseconds, 40)
    }
}
