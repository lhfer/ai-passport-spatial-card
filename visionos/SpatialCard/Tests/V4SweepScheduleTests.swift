import XCTest

/// **v4 A1.** The name card's idle sweep: one every 8–12 s (start to start), reproducible from its seed, invisible
/// between sweeps.
final class V4SweepScheduleTests: XCTestCase {
    /// Run two minutes at 90 fps and collect when each sweep starts.
    private func starts(seed: UInt64) -> (starts: [Double], values: [Float]) {
        var schedule = V4.SweepSchedule(seed: seed, firstDelay: 2.5)
        var starts: [Double] = []
        var values: [Float] = []
        var previous: Float = 1
        let dt = 1.0 / 90
        for frame in 0..<(90 * 120) {
            let value = schedule.advance(by: dt)
            if value < previous - 0.5 { starts.append(Double(frame + 1) * dt) }
            previous = value
            values.append(value)
        }
        return (starts, values)
    }

    func testOneSweepEveryEightToTwelveSeconds() {
        let run = starts(seed: 42)
        XCTAssertGreaterThanOrEqual(run.starts.count, 9, "two minutes hold at least nine sweeps")
        XCTAssertEqual(run.starts.first ?? 0, 2.5, accuracy: 0.02, "the first one after the settle delay")
        for (a, b) in zip(run.starts, run.starts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 8 - 0.02)
            XCTAssertLessThanOrEqual(b - a, 12 + 0.02)
        }
    }

    func testValuesStayInRangeAndRestPastTheCard() {
        let run = starts(seed: 7)
        XCTAssertTrue(run.values.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(run.values.first, 1, "resting (past the far corner) before the first sweep")
        // Most of the time the card is quiet: a 1.4 s sweep in every 8–12 s.
        let resting = run.values.filter { $0 == 1 }.count
        XCTAssertGreaterThan(Double(resting) / Double(run.values.count), 0.8)
    }

    func testSameSeedSameTake() {
        XCTAssertEqual(starts(seed: 99).starts, starts(seed: 99).starts)
        XCTAssertNotEqual(starts(seed: 99).starts, starts(seed: 100).starts)
    }
}
