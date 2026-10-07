import XCTest

/// **v4 B5 §2** — the alive-particle count of a transition: what was born and has not yet lived out its life (the steady
/// state `birthRate × lifeSpan` is wrong for a trail that is on for 0.55 s).
final class V4ParticleLedgerTests: XCTestCase {
    typealias Ledger = V4.ParticleLedger

    /// One trail at 95/s for 0.55 s, sparks living 0.8 s: 52 born, all alive at the end of the flight, none 0.8 s after it.
    func testATrailThatIsOnForAFlight() {
        var ledger = Ledger()
        let dt = 1.0 / 90
        var t = 0.0
        while t < 0.55 - 1e-9 {
            ledger.emit(rate: 95, dt: dt, life: 0.8, at: t)
            t += dt
        }
        XCTAssertEqual(ledger.alive(at: 0.55), 95 * 0.55, accuracy: 1.5)
        XCTAssertEqual(ledger.alive(at: 1.0), 95 * (0.55 - 0.2), accuracy: 1.5, "the first 0.2 s of sparks are gone")
        XCTAssertEqual(ledger.alive(at: 1.4), 0, accuracy: 0.001)
        XCTAssertTrue(ledger.isEmpty, "the dead are forgotten")
    }

    /// The steady state of an emitter that stays on is `birthRate × lifeSpan`, the number the old census printed.
    func testASteadyEmitterReachesItsSteadyState() {
        var ledger = Ledger()
        let dt = 1.0 / 90
        for i in 0..<900 { ledger.emit(rate: 30, dt: dt, life: 3, at: Double(i) * dt) }
        XCTAssertEqual(ledger.alive(at: 899 * dt), 30 * 3, accuracy: 1.5)
    }

    func testBurstsAndNonsense() {
        var ledger = Ledger()
        ledger.burst(count: 12, life: 0.6, at: 1)
        ledger.burst(count: 12, life: 0.6, at: 1.18)
        XCTAssertEqual(ledger.alive(at: 1.2), 24)
        XCTAssertEqual(ledger.alive(at: 1.7), 12)
        ledger.emit(rate: .nan, dt: 0.01, life: 1, at: 2)
        ledger.emit(rate: 10, dt: 0, life: 1, at: 2)
        ledger.burst(count: -3, life: 1, at: 2)
        XCTAssertEqual(ledger.alive(at: 2), 0)
    }

    func testFrameStat() {
        var s = V4.FrameStat()
        XCTAssertEqual(s.average, 0)
        for v in [2.0, 6.0, 4.0, .infinity] { s.add(v) }
        XCTAssertEqual(s.frames, 3, "a non-finite sample is not a frame")
        XCTAssertEqual(s.peak, 6)
        XCTAssertEqual(s.average, 4)
    }
}
