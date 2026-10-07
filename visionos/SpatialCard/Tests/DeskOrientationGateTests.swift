import XCTest
import simd

/// V3-1b §3: "is the passport lying on a desk, or is it in a hand?" — the question the gravity snap and the flat
/// gate both hang off, and the one V3-1 answered from tilt alone.
///
/// The headset numbers this matrix is written against: the object tracker's pitch/roll on a thin slab **at rest**
/// read 3.7°, 5.5°, 14.1°, 17.3°, 21.9° and 27.7°, so "on the desk" has to survive 27°; a device lying flat in a
/// palm is under 35° too, so tilt cannot be the whole answer; desk jitter is 0.3–1 mm against 5–9 mm in hand.
final class DeskOrientationGateTests: XCTestCase {
    private let deg: Float = .pi / 180

    /// Feed the gate at 30 Hz from `from` to `to`, standing still at `position`.
    @discardableResult
    private func hold(_ gate: inout DeskOrientationGate, tilt: Float, at position: SIMD3<Float>,
                      planeBelow: Float?, from: TimeInterval, to: TimeInterval) -> [DeskOrientationGate.Change] {
        var changes: [DeskOrientationGate.Change] = []
        var t = from
        while t <= to + 1e-9 {
            if let change = gate.update(tilt: tilt, position: position, planeBelow: planeBelow, at: t) {
                changes.append(change)
            }
            t += 1.0 / 30
        }
        return changes
    }

    /// Feed the gate at 30 Hz while the device slides at `speed` m/s along +X.
    @discardableResult
    private func carry(_ gate: inout DeskOrientationGate, tilt: Float, speed: Float, planeBelow: Float?,
                       from: TimeInterval, to: TimeInterval) -> [DeskOrientationGate.Change] {
        var changes: [DeskOrientationGate.Change] = []
        var t = from
        while t <= to + 1e-9 {
            let p = SIMD3<Float>(speed * Float(t - from), 1.1, -0.6)
            if let change = gate.update(tilt: tilt, position: p, planeBelow: planeBelow, at: t) {
                changes.append(change)
            }
            t += 1.0 / 30
        }
        return changes
    }

    /// Park the gate in "hand" so the entry rules are the ones under test.
    private func inHand(at time: TimeInterval = 0) -> DeskOrientationGate {
        var gate = DeskOrientationGate()
        hold(&gate, tilt: 70 * deg, at: [0, 1.2, -0.6], planeBelow: nil, from: time, to: time + 0.5)
        XCTAssertFalse(gate.isOnDesk, "a device held at 70° is not on a desk")
        return gate
    }

    /// The prior is the desk: a card that is first seen lying on one must reveal itself there, and
    /// `PresenceGate` turns a single non-flat observation in `acquiring` straight into `carrying(.notFlat)`.
    func testAFreshGateStartsOnTheDesk() {
        let gate = DeskOrientationGate()
        XCTAssertTrue(gate.isOnDesk)
        XCTAssertEqual(gate.speed, 0)
    }

    /// Still, flat, and a plane 1 cm under the screen: the desk is granted after `stillForPlane`.
    func testStillOnAPlaneComesBackToTheDeskAfterFourTenths() {
        var gate = inHand()
        let changes = hold(&gate, tilt: 12 * deg, at: [0, 1.05, -0.6], planeBelow: 0.011, from: 10, to: 10.9)
        XCTAssertEqual(changes.count, 1)
        let change = try? XCTUnwrap(changes.first)
        XCTAssertTrue(change?.isOnDesk ?? false)
        XCTAssertTrue(change?.reason.contains("plane 1.1 cm below") ?? false, change?.reason ?? "no change")
        XCTAssertTrue(gate.isOnDesk)

        // …and not one observation sooner.
        var early = inHand()
        hold(&early, tilt: 12 * deg, at: [0, 1.05, -0.6], planeBelow: 0.011, from: 10, to: 10.3)
        XCTAssertFalse(early.isOnDesk, "0.3 s of stillness is not yet evidence")
    }

    /// No plane detected (no scene understanding yet, a shelf, the simulator) and no remembered desk height:
    /// stillness alone has to carry the argument, and it takes three times as long.
    ///
    /// **V3-4 §5**: 2.0 s → 1.2 s. The first headset round never found a plane it would accept, so every
    /// put-down of the session paid the full fallback and "put it down → the gallery" measured 2.5 s.
    func testStillWithoutAPlaneNeedsOnePointTwoSeconds() {
        // Two runs rather than one continued: restarting `hold` on the timestamp the previous one ended
        // at can land a hair *before* it in floating point, which the gate reads as an out-of-order
        // observation and restarts its stillness clock for — a harness artefact, not a rule.
        var early = inHand()
        hold(&early, tilt: 12 * deg, at: [0, 1.05, -0.6], planeBelow: nil, from: 10, to: 11.1)
        XCTAssertFalse(early.isOnDesk, "1.1 s without a plane is not enough")
        var gate = inHand()
        hold(&gate, tilt: 12 * deg, at: [0, 1.05, -0.6], planeBelow: nil, from: 10, to: 11.25)
        XCTAssertTrue(gate.isOnDesk)
    }

    /// A plane too far under the screen is the floor, not the desk the device is lying on.
    func testAPlaneOutOfReachDoesNotCount() {
        var gate = inHand()
        hold(&gate, tilt: 12 * deg, at: [0, 1.05, -0.6], planeBelow: 0.4, from: 10, to: 11.0)
        XCTAssertFalse(gate.isOnDesk, "40 cm below is not what the device is resting on")
    }

    /// Flat enough to be a desk, but moving: a device carried horizontally through the air is still in a hand.
    func testFlatButMovingIsAHand() {
        var gate = inHand()
        carry(&gate, tilt: 25 * deg, speed: 0.15, planeBelow: 0.011, from: 10, to: 12.5)
        XCTAssertFalse(gate.isOnDesk)
        XCTAssertGreaterThan(gate.speed, 0.12)
    }

    /// The worst rest reading the headset produced. It has to read as the desk, or a passport simply lying there
    /// is drawn in the hand form with the tracker's pitch error on show.
    func testTheWorstRestingTiltStillReadsAsTheDesk() {
        var gate = inHand()
        hold(&gate, tilt: 27 * deg, at: [0.2, 1.05, -0.6], planeBelow: 0.008, from: 10, to: 10.9)
        XCTAssertTrue(gate.isOnDesk)
    }

    /// Picked up: one condition, held for `exitDwell`. Quick, because being wrong about "in a hand" only costs a
    /// snap that is not applied, and being wrong about "on the desk" costs the card.
    func testTiltLeavesTheDeskWithinTheDwell() {
        var gate = DeskOrientationGate()
        hold(&gate, tilt: 5 * deg, at: [0, 1.05, -0.6], planeBelow: 0.008, from: 0, to: 1.0)
        XCTAssertTrue(gate.isOnDesk)

        var changes = hold(&gate, tilt: 50 * deg, at: [0, 1.05, -0.6], planeBelow: 0.008, from: 1.0, to: 1.10)
        XCTAssertTrue(changes.isEmpty, "one tilted observation is not a pick-up")
        XCTAssertTrue(gate.isOnDesk)
        changes = hold(&gate, tilt: 50 * deg, at: [0, 1.05, -0.6], planeBelow: 0.008, from: 1.10, to: 1.20)
        XCTAssertEqual(changes.count, 1)
        XCTAssertFalse(gate.isOnDesk)
        XCTAssertTrue(changes.first?.reason.contains("tilt 50°") ?? false, changes.first?.reason ?? "-")
    }

    /// Speed leaves it too, and says so.
    func testSpeedLeavesTheDesk() {
        var gate = DeskOrientationGate()
        hold(&gate, tilt: 5 * deg, at: [0, 1.05, -0.6], planeBelow: 0.008, from: 0, to: 1.0)
        let changes = carry(&gate, tilt: 5 * deg, speed: 0.3, planeBelow: 0.008, from: 1.0, to: 2.0)
        XCTAssertEqual(changes.count, 1)
        XCTAssertFalse(gate.isOnDesk)
        XCTAssertTrue(changes.first?.reason.contains("moving") ?? false, changes.first?.reason ?? "-")
    }

    /// 35° in, 45° out: a device resting at 40° stays where the gate put it, in either direction.
    func testHysteresisBetweenThirtyFiveAndFortyFive() {
        var onDesk = DeskOrientationGate()
        hold(&onDesk, tilt: 5 * deg, at: [0, 1.05, -0.6], planeBelow: 0.008, from: 0, to: 1.0)
        hold(&onDesk, tilt: 40 * deg, at: [0, 1.05, -0.6], planeBelow: 0.008, from: 1.0, to: 2.0)
        XCTAssertTrue(onDesk.isOnDesk, "40° is past the entry angle but not past the exit angle")
        hold(&onDesk, tilt: 46 * deg, at: [0, 1.05, -0.6], planeBelow: 0.008, from: 2.0, to: 2.5)
        XCTAssertFalse(onDesk.isOnDesk, "46° leaves")

        // …and from the hand, 40° is not enough to come back however still and well-planted it is.
        hold(&onDesk, tilt: 40 * deg, at: [0, 1.05, -0.6], planeBelow: 0.008, from: 2.5, to: 6.0)
        XCTAssertFalse(onDesk.isOnDesk)
        hold(&onDesk, tilt: 34 * deg, at: [0, 1.05, -0.6], planeBelow: 0.008, from: 6.0, to: 6.6)
        XCTAssertTrue(onDesk.isOnDesk)
    }

    /// Tracking jitter is not motion. 5 mm of RMS step at 30 Hz is 0.15 m/s of |Δp|/Δt and 0.024 m/s through the
    /// 0.3 s window — which is the whole reason the estimator is a window and not a frame difference.
    func testJitterDoesNotReadAsMotion() {
        var gate = DeskOrientationGate()
        var seed: UInt64 = 0x9E3779B9
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.01      // ±5 mm
        }
        var t: TimeInterval = 0
        while t < 2.0 {
            gate.update(tilt: 8 * deg, position: [noise(), 1.05 + noise(), -0.6 + noise()],
                        planeBelow: 0.008, at: t)
            t += 1.0 / 30
        }
        XCTAssertTrue(gate.isOnDesk, "5 mm of jitter must not read as a carry")
        XCTAssertLessThan(gate.speed, 0.04)
    }

    /// A tracking loss resets the stillness clock and nothing else: a device lost on a desk is still on the desk,
    /// but the 0.4 s of "it has not moved" has to be earned again with observations.
    func testATrackingLossResetsOnlyTheStillnessClock() {
        var gate = inHand()
        hold(&gate, tilt: 12 * deg, at: [0, 1.05, -0.6], planeBelow: 0.011, from: 10, to: 10.2)
        gate.loseTracking()
        XCTAssertFalse(gate.isOnDesk)
        XCTAssertEqual(gate.speed, 0)
        hold(&gate, tilt: 12 * deg, at: [0, 1.05, -0.6], planeBelow: 0.011, from: 11, to: 11.3)
        XCTAssertFalse(gate.isOnDesk, "the clock started again at the first observation after the loss")
        hold(&gate, tilt: 12 * deg, at: [0, 1.05, -0.6], planeBelow: 0.011, from: 11.3, to: 11.5)
        XCTAssertTrue(gate.isOnDesk)

        // The other direction: a device that was on the desk when it was lost is still on it.
        var resting = DeskOrientationGate()
        hold(&resting, tilt: 5 * deg, at: [0, 1.05, -0.6], planeBelow: 0.008, from: 0, to: 1.0)
        resting.loseTracking()
        XCTAssertTrue(resting.isOnDesk)
    }
    // MARK: - V3-2a H5: the anticipation

    /// The deck's put-down anticipation needs to know that the passport is flat **before** the 0.4 s of
    /// stillness are up — otherwise the bloom always arrives unannounced, 0.4 s after the wearer let go.
    /// Motion cancels it on the next observation.
    func testTheCandidateFiresBeforeStillnessAndIsCancelledByMotion() {
        let step = 1.0 / 30
        var gate = DeskOrientationGate()
        var t: TimeInterval = 0

        /// Pick the passport up: tilted and travelling, so the gate leaves the desk and the stillness clock
        /// is cleared.
        func pickUp() {
            var p = SIMD3<Float>(0, 1.05, 0)
            for _ in 0..<30 {
                p.y += 0.006
                gate.update(tilt: 60 * .pi / 180, position: p, planeBelow: nil, at: t)
                t += step
            }
        }

        pickUp()
        XCTAssertFalse(gate.isOnDesk)
        XCTAssertFalse(gate.isCandidate)

        // Put it back down flat on a plane and hold it there: the anticipation comes first, the desk after.
        let rest = SIMD3<Float>(0, 1.05, 0)
        var candidateBeforeTheDesk = false
        for _ in 0..<60 {
            gate.update(tilt: 8 * .pi / 180, position: rest, planeBelow: 0.008, at: t)
            t += step
            if gate.isCandidate, !gate.isOnDesk { candidateBeforeTheDesk = true }
            if gate.isOnDesk { break }
        }
        XCTAssertTrue(candidateBeforeTheDesk, "flat and slowing down is the put-down coming")
        XCTAssertTrue(gate.isOnDesk, "and the desk follows")
        XCTAssertFalse(gate.isCandidate, "granted: the anticipation is over")

        // Again, and this time the wearer picks it back up mid-air: the anticipation has to let go.
        pickUp()
        var sawCandidate = false
        for _ in 0..<20 {
            gate.update(tilt: 8 * .pi / 180, position: rest, planeBelow: 0.008, at: t)
            t += step
            if gate.isCandidate { sawCandidate = true; break }
        }
        XCTAssertTrue(sawCandidate)
        XCTAssertFalse(gate.isOnDesk)
        gate.update(tilt: 8 * .pi / 180, position: rest + [0.12, 0, 0], planeBelow: 0.008, at: t)
        XCTAssertFalse(gate.isCandidate, "one real move and the deck relaxes again")
    }

    // MARK: - V3-4 §5: the put-down is 0.4 s, not 2 s

    /// **The plane that was thrown away.** The headset's one detected plane for the real desk sat 1.9 cm
    /// *above* the passport's screen (`desk plane found … (drop -0.019 m)`) — a plane estimate is a fitted
    /// rectangle over a noisy cloud, and a centimetre of bias is ordinary. V3-2b accepted −1 cm, so every
    /// put-down of the session fell through to the 2 s no-plane path.
    func testAPlaneTwoCentimetresAboveTheScreenIsStillTheDesk() {
        var gate = inHand()
        let changes = hold(&gate, tilt: 3 * deg, at: [0, 1.1, -0.6], planeBelow: -0.020, from: 10, to: 10.6)
        XCTAssertTrue(gate.isOnDesk, "a plane 2 cm above the screen is the desk it is lying on")
        XCTAssertTrue(changes.first?.reason.contains("plane") ?? false, changes.first?.reason ?? "-")
        // …and one 5 cm above it is not: that is a shelf, or a badly fitted plane.
        var far = inHand()
        hold(&far, tilt: 3 * deg, at: [0, 1.1, -0.6], planeBelow: -0.05, from: 10, to: 11.0)
        XCTAssertFalse(far.isOnDesk, "5 cm above the screen is not the surface it is resting on")
    }

    /// **The remembered desk.** Once the gate has confirmed a desk it knows how high it is, so coming back
    /// to that height flat and still is worth as much as a plane: 0.4 s rather than 1.2 s.
    func testTheRememberedDeskHeightIsWorthAsMuchAsAPlane() {
        var gate = DeskOrientationGate()
        // Lying on the desk, which is where the prior already has it: the height is learned from the
        // observations themselves, not only from a transition (a session that starts with the passport on
        // the desk never produces one).
        hold(&gate, tilt: 3 * deg, at: [0, 1.1, -0.6], planeBelow: 0.008, from: 10, to: 11.0)
        XCTAssertTrue(gate.isOnDesk)
        XCTAssertEqual(gate.rememberedHeight ?? 0, 1.1, accuracy: 1e-5)

        // Pick it up …
        carry(&gate, tilt: 60 * deg, speed: 0.4, planeBelow: nil, from: 11.0, to: 11.8)
        XCTAssertFalse(gate.isOnDesk)
        // … and put it back at the same height, with no plane reported at all this time: 0.4 s, not 1.2 s.
        let changes = hold(&gate, tilt: 3 * deg, at: [0.2, 1.108, -0.6], planeBelow: nil, from: 20, to: 20.5)
        XCTAssertTrue(gate.isOnDesk, "back on the desk it was just lifted off")
        XCTAssertTrue(changes.first?.reason.contains("remembered height") ?? false, changes.first?.reason ?? "-")
    }

    /// Without a plane **and** without a memory, the fallback is 1.2 s — down from 2.0 s, and still four
    /// times the 0.3 s speed window, so a slow carry cannot walk through it.
    func testWithoutAPlaneOrAMemoryTheFallbackIsOnePointTwoSeconds() {
        var early = inHand()
        hold(&early, tilt: 3 * deg, at: [0, 1.1, -0.6], planeBelow: nil, from: 10, to: 11.1)
        XCTAssertFalse(early.isOnDesk, "1.1 s of stillness is not yet a put-down")
        var gate = inHand()
        hold(&gate, tilt: 3 * deg, at: [0, 1.1, -0.6], planeBelow: nil, from: 10, to: 11.25)
        XCTAssertTrue(gate.isOnDesk, "1.2 s is")
    }

    /// **The known cost of the memory rule, written down.** A palm held dead flat, with no plane under it,
    /// more than 3 cm from the desk the gate remembers, still pays the full 1.2 s — a full second of holding
    /// it perfectly still is not enough. A palm at *exactly* the remembered height would come in at 0.4 s;
    /// that is the trade the rule makes, and a hand is almost never within 3 cm of the surface it lifted off.
    func testAPalmHeldFlatWellAboveTheRememberedDeskDoesNotEnter() {
        var gate = DeskOrientationGate()
        hold(&gate, tilt: 3 * deg, at: [0, 1.10, -0.6], planeBelow: 0.008, from: 10, to: 11.0)
        XCTAssertTrue(gate.isOnDesk)
        XCTAssertEqual(gate.rememberedHeight ?? 0, 1.10, accuracy: 1e-5)
        carry(&gate, tilt: 55 * deg, speed: 0.4, planeBelow: nil, from: 11.0, to: 11.8)
        XCTAssertFalse(gate.isOnDesk)
        // 12 cm above the desk, flat in a palm, perfectly still for a second.
        hold(&gate, tilt: 4 * deg, at: [0.1, 1.22, -0.6], planeBelow: nil, from: 20, to: 20.98)
        XCTAssertFalse(gate.isOnDesk, "a flat palm 12 cm up is not the desk")
        // The same palm, held for the full fallback, does enter — that has always been true, and is the
        // price of having a fallback at all.
        hold(&gate, tilt: 4 * deg, at: [0.1, 1.22, -0.6], planeBelow: nil, from: 21.05, to: 21.35)
        XCTAssertTrue(gate.isOnDesk, "1.2 s of dead-flat stillness is the fallback, plane or no plane")
    }
}
