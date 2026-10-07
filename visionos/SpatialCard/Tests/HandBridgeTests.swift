import XCTest
import simd

/// v3 plan H4 / V3-2b B6: the rule that carries the card through an object-tracking dropout.
///
/// The headset is the only place this can ever run (the simulator has neither hand nor object tracking), so
/// the whole rule is a pure value type and this is where it is actually checked.
final class HandBridgeTests: XCTestCase {
    private func pose(_ x: Float, _ y: Float, _ z: Float, yawDeg: Float = 0) -> simd_float4x4 {
        HandBridge.pose(rotation: simd_quatf(angle: yawDeg * .pi / 180, axis: [0, 1, 0]), translation: [x, y, z])
    }

    private func distance(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        simd_length(HandBridge.translation(of: a) - HandBridge.translation(of: b))
    }

    /// The offset is learned from a wrist that is **holding** the device. A hand 30 cm away is a hand doing
    /// something else, and taking its transform would carry the card off on the wrong arm.
    func testTheOffsetIsOnlyLearnedFromAWristOnTheDevice() {
        var bridge = HandBridge()
        let device = pose(0, 1.2, -0.6)
        bridge.observeHand(.left, pose: pose(0.30, 1.2, -0.6), tracked: true, at: 1.0)
        bridge.observeObject(screen: device, tracked: true, at: 1.0)
        XCTAssertFalse(bridge.hasOffset(.left), "30 cm away is not holding it")

        bridge.observeHand(.left, pose: pose(0.02, 1.17, -0.6), tracked: true, at: 1.1)
        bridge.observeObject(screen: device, tracked: true, at: 1.1)
        XCTAssertTrue(bridge.hasOffset(.left), "3.6 cm away is")

        // …and an untracked hand teaches nothing either, however close it claims to be.
        var other = HandBridge()
        other.observeHand(.right, pose: pose(0.01, 1.2, -0.6), tracked: false, at: 1.0)
        other.observeObject(screen: device, tracked: true, at: 1.0)
        XCTAssertFalse(other.hasOffset(.right))
    }

    /// A grip that shifts is followed, not snapped to: after three time constants the stored offset is on the
    /// new one, and a single frame of nonsense would move it by a third of τ's worth.
    func testTheOffsetLowPassesTowardAMovedGrip() {
        var bridge = HandBridge()
        let device = pose(0, 1.2, -0.6)
        // 30 Hz of "the wrist is 3 cm below the device", then the grip slides 2 cm along it.
        for k in 0..<30 {
            let t = 1.0 + Double(k) / 30
            bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: device, tracked: true, at: t)
        }
        let settled = bridge.offset(.left)!
        XCTAssertEqual(simd_length(HandBridge.translation(of: settled) - SIMD3<Float>(0, 0.03, 0)), 0, accuracy: 1e-5)

        for k in 0..<27 {                                  // 0.9 s = 3 τ
            let t = 2.0 + Double(k) / 30
            bridge.observeHand(.left, pose: pose(0, 1.15, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: device, tracked: true, at: t)
        }
        let moved = HandBridge.translation(of: bridge.offset(.left)!)
        XCTAssertEqual(simd_length(moved - SIMD3<Float>(0, 0.05, 0)), 0, accuracy: 0.003,
                       "three time constants should be within 3 mm of the new grip")
    }

    /// The whole point: the object drops out, the hand keeps moving, and the card goes with the hand — to
    /// within a millimetre of `T_hand · T_hand→device`, for as long as the bridge is allowed to run.
    func testTheCardIsCarriedByTheHandWhenTheObjectDropsOut() {
        var bridge = HandBridge()
        for k in 0..<15 {
            let t = 1.0 + Double(k) / 30
            bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: pose(0, 1.2, -0.6), tracked: true, at: t)
        }
        let lost = 1.0 + 14.0 / 30                        // the last tracked object observation
        XCTAssertNil(bridge.decide(at: lost + 0.10), "0.1 s is a dropped frame, not a loss")

        // The object stops being reported and the hand moves sideways at 0.3 m/s.
        //
        // **V3-4 §3 changed the first quarter second of this.** V3-2b cut straight to `hand · offset`, and
        // on the headset that step read as 1.9–3.0 m/s of travel to the continuity gate (`trail on`) on all
        // three occlusions. The take-over now *starts* where the camera left the card and eases onto the
        // hand's answer over `takeoverBlend`; after that it is exactly what it always was.
        var bridgedTicks = 0
        var takeover: TimeInterval?
        for k in 1...45 {
            let t = lost + Double(k) / 30
            let x = Float(t - lost) * 0.3
            bridge.observeHand(.left, pose: pose(x, 1.17, -0.6), tracked: true, at: t)
            let drive = bridge.decide(at: t)
            guard t - lost >= bridge.lossTimeout else {
                XCTAssertNil(drive, "still inside the 0.15 s loss timeout at \(t - lost)")
                continue
            }
            guard let drive else {
                XCTFail("no bridge \(t - lost) s after the loss")
                return
            }
            XCTAssertEqual(drive.kind, .bridged)
            XCTAssertEqual(drive.side, .left)
            if takeover == nil {
                takeover = t
                // The first bridged frame is the last tracked pose, not a jump to the hand 4.5 cm away.
                XCTAssertEqual(distance(drive.pose, pose(0, 1.20, -0.6)), 0, accuracy: 0.001,
                               "the hand-over has a step in it")
            } else if t - (takeover ?? t) > bridge.takeoverBlend {
                // …and once the residual is gone, the card is where the hand says the device is.
                XCTAssertEqual(distance(drive.pose, pose(x, 1.20, -0.6)), 0, accuracy: 0.001)
            }
            bridgedTicks += 1
        }
        XCTAssertGreaterThan(bridgedTicks, 35, "the loss is carried, not frozen")
        XCTAssertTrue(bridge.isBridging)
    }

    /// Past `maxBridge` the wearer has put the passport down, handed it over or walked away: the bridge
    /// gives up and the existing `held(untracked)` freeze is the honest answer. It does not start again on
    /// the next tick — only a real object observation re-arms it.
    ///
    /// **V3-5 §1** rewrote the three hard-coded `3.0`s here to read `maxBridge` (now 6 s — see there for
    /// why). What is asserted is unchanged: the bridge carries the whole budget, stops at the end of it,
    /// and does not start a second one on the same loss.
    func testTheBridgeExpiresAtTheEndOfItsBudget() {
        var bridge = HandBridge()
        let budget = bridge.maxBridge
        for k in 0..<10 {
            let t = Double(k) / 30
            bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: pose(0, 1.2, -0.6), tracked: true, at: t)
        }
        let lost = 9.0 / 30
        var lastDrive: HandBridge.Drive?
        for k in 1...Int((budget + 1) * 30) {
            let t = lost + Double(k) / 30
            bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            let drive = bridge.decide(at: t)
            if t - lost >= bridge.lossTimeout, t - lost < budget - 0.1 {
                XCTAssertNotNil(drive, "still inside the budget at \(t - lost)")
            }
            if drive != nil { lastDrive = drive }
        }
        XCTAssertNotNil(lastDrive)
        XCTAssertLessThan(lastDrive!.elapsed, budget)
        XCTAssertGreaterThan(lastDrive!.elapsed, budget - 0.1, "it carried the whole budget")
        XCTAssertTrue(bridge.expired)
        XCTAssertFalse(bridge.isBridging)
        bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: lost + budget + 4)
        XCTAssertNil(bridge.decide(at: lost + budget + 4), "one bridge per loss")
    }

    /// The object comes back somewhere slightly else. The card eases onto it over a quarter of a second,
    /// monotonically, and arrives exactly on the tracked pose — a cut here would look like a relocation to
    /// the continuity gate and like a glitch to the camera.
    func testComingBackBlendsOverAQuarterSecond() {
        var bridge = HandBridge()
        for k in 0..<10 {
            let t = Double(k) / 30
            bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: pose(0, 1.2, -0.6), tracked: true, at: t)
        }
        let lost = 9.0 / 30
        for k in 1...30 {                                   // 1 s of bridge
            let t = lost + Double(k) / 30
            bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            _ = bridge.decide(at: t)
        }
        let bridged = bridge.lastBridgedPose!
        XCTAssertEqual(distance(bridged, pose(0, 1.2, -0.6)), 0, accuracy: 1e-5)
        // The object is seen again 4 cm away — and then keeps being seen, as a real stream does.
        let back = pose(0.04, 1.2, -0.6)
        let t0 = lost + 1
        var previous: Float = 0
        var blends = 0
        for k in 0...8 {
            let t = t0 + Double(k) * 0.03
            bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: back, tracked: true, at: t)
            guard t - t0 < bridge.blendBack else {
                XCTAssertNil(bridge.decide(at: t), "0.25 s and the object has the card")
                continue
            }
            guard let drive = bridge.decide(at: t) else { XCTFail("no blend at \(t - t0)"); return }
            XCTAssertEqual(drive.kind, .blending)
            let travelled = distance(bridged, drive.pose)
            XCTAssertGreaterThanOrEqual(travelled, previous - 1e-6, "the hand-over must not go backwards")
            XCTAssertLessThanOrEqual(travelled, distance(bridged, back) + 1e-6, "…and never past the object")
            previous = travelled
            blends += 1
        }
        XCTAssertGreaterThan(blends, 5)
        XCTAssertEqual(previous, distance(bridged, back), accuracy: 0.006, "it lands on the tracked pose")
        XCTAssertFalse(bridge.isBridging)
    }

    /// The hand is lost too (a wrist out of view, both hands down): there is nothing to bridge with and the
    /// freeze is what should happen. Same for a hand whose observations have simply stopped arriving.
    func testWithoutAHandThereIsNoBridge() {
        var bridge = HandBridge()
        for k in 0..<10 {
            let t = Double(k) / 30
            bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: pose(0, 1.2, -0.6), tracked: true, at: t)
        }
        bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: false, at: 0.5)
        XCTAssertNil(bridge.decide(at: 0.6), "the hand is not tracked either")

        // …and a hand that was tracked but has not been heard from for a quarter of a second is stale.
        bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: 0.7)
        XCTAssertNotNil(bridge.decide(at: 0.75))
        XCTAssertNil(bridge.decide(at: 1.1), "no hand observation for 0.4 s")

        // A hand that never held the device cannot carry it either.
        var fresh = HandBridge()
        fresh.observeObject(screen: pose(0, 1.2, -0.6), tracked: true, at: 0)
        fresh.observeHand(.right, pose: pose(0.4, 1.2, -0.6), tracked: true, at: 0.5)
        XCTAssertNil(fresh.decide(at: 0.5))
    }

    // MARK: - V3-4 §3: which hand, and how it takes over

    /// Feed both hands: the right one holding the passport for five seconds, the left one arriving 0.2 s
    /// before the loss — which is exactly what an occlusion looks like. V3-2b took `Side.allCases` in order
    /// and picked the **left** every time; all three occlusions of the first headset round were bridged by
    /// the hand reaching over the device, and the card flew off after it (`deckLag = 173–177 mm`).
    func testTheHandThatHasBeenHoldingItLongestCarriesTheCard() {
        var bridge = HandBridge()
        let device = pose(0, 1.2, -0.6)
        // Five seconds of the right hand holding it.
        for k in 0...150 {
            let t = Double(k) / 30
            bridge.observeHand(.right, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: device, tracked: true, at: t)
        }
        // The left hand reaches over it 0.2 s before the object drops out.
        for k in 0...6 {
            let t = 5.0 + Double(k) / 30
            bridge.observeHand(.right, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            bridge.observeHand(.left, pose: pose(0.01, 1.23, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: device, tracked: true, at: t)
        }
        XCTAssertTrue(bridge.hasOffset(.left), "the occluding hand does learn an offset — that is the trap")
        XCTAssertGreaterThan(bridge.holdingSeconds(.right, at: 5.2), 5.0)
        XCTAssertLessThan(bridge.holdingSeconds(.left, at: 5.2), 0.5)

        bridge.observeObject(screen: device, tracked: false, at: 5.25)
        let drive = bridge.decide(at: 5.25)
        XCTAssertEqual(drive?.side, .right, "the hand that has been holding it, not the one that arrived")
        XCTAssertGreaterThan(drive?.holding ?? 0, 5.0)
        XCTAssertTrue(bridge.handsSummary(at: 5.25).contains("R("), bridge.handsSummary(at: 5.25))
        XCTAssertTrue(bridge.handsSummary(at: 5.25).contains("*"), "the Σ line stars the carrying hand")
    }

    /// An offset nobody has confirmed for a second is a memory of a grip. It may not start a bridge — this
    /// is the whole of `bridge on (right, 461.16 s after loss)` — but it may not end one either: while the
    /// bridge drives, the object is by definition missing, so the offset cannot be refreshed.
    func testAStaleOffsetCannotStartABridgeButCannotEndOneEither() {
        var bridge = HandBridge()
        let device = pose(0, 1.2, -0.6)
        for k in 0...60 {
            let t = Double(k) / 30
            bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: device, tracked: true, at: t)
        }
        // Two seconds later the hand is still there but nothing has confirmed the grip.
        bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: 4.0)
        bridge.observeObject(screen: device, tracked: false, at: 4.0)
        XCTAssertNil(bridge.decide(at: 4.0), "a two-second-old offset may not start a bridge")

        // A bridge that *has* started runs its full budget on the same stale offset.
        //
        // **V3-5 §1** rewrote the two numbers in this half, not the rule: `maxBridge` is 6 s now (3 s was
        // sized for an occlusion; the case that hurt on the headset was ARKit taking 8.5 s to re-detect a
        // passport that had just been picked up), so the loop runs to the new budget and the assertion
        // after it is one tick past it. The assertion itself — "it runs the whole budget on a stale offset,
        // and not a moment longer" — is unchanged.
        var running = HandBridge()
        let budget = running.maxBridge
        for k in 0...60 {
            let t = Double(k) / 30
            running.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            running.observeObject(screen: device, tracked: true, at: t)
        }
        running.observeObject(screen: device, tracked: false, at: 2.05)
        XCTAssertNotNil(running.decide(at: 2.05))
        for k in 1...Int(budget * 20) + 10 {
            let t = 2.05 + Double(k) / 20
            running.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            if t < 2.05 + budget - 0.05 {
                XCTAssertNotNil(running.decide(at: t), "the bridge was cut short at \(t)")
            }
        }
        XCTAssertNil(running.decide(at: 2.05 + budget + 0.15), "…and no longer than maxBridge")
    }

    /// The engage window: a bridge starts inside half a second of the loss and never later. The 14:23 log
    /// had `bridge on (right, 461.16 s after loss)` — a hand that had held the passport minutes earlier
    /// picking a card up off a desk it was nowhere near.
    func testABridgeOnlyStartsRightAfterTheLoss() {
        var bridge = HandBridge()
        let device = pose(0, 1.2, -0.6)
        for k in 0...60 {
            let t = Double(k) / 30
            bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: device, tracked: true, at: t)
        }
        // 0.3 s after the last tracked observation, with the hand still reporting: inside the window.
        bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: 2.3)
        XCTAssertNotNil(bridge.decide(at: 2.3))

        // A second bridge, offered 0.8 s after a loss, is refused however good the offset is.
        var late = HandBridge()
        for k in 0...60 {
            let t = Double(k) / 30
            late.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
            late.observeObject(screen: device, tracked: true, at: t)
        }
        late.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: 2.8)
        XCTAssertNil(late.decide(at: 2.8), "0.8 s after the loss is not a hand-over, it is a guess")
    }

    /// **The take-over has no step in it.** The offset is a low-passed average of a grip that has been
    /// shifting, so `hand · offset` on the first bridged frame is never exactly where the camera last put
    /// the card. V3-2b cut straight to it and the continuity gate read the jump as 1.9–3.0 m/s of travel
    /// (`trail on`). The residual is now smoothed to nothing over a quarter of a second.
    func testTheTakeOverStartsWhereTheCameraLeftOff() {
        var bridge = HandBridge()
        // A grip that drifts 2 cm while it is being learned, so the stored offset is behind the truth.
        for k in 0...60 {
            let t = Double(k) / 30
            let slide = Float(k) / 60 * 0.02
            bridge.observeHand(.left, pose: pose(0, 1.17 + slide, -0.6), tracked: true, at: t)
            bridge.observeObject(screen: pose(0, 1.2, -0.6), tracked: true, at: t)
        }
        let lastTracked = bridge.lastObjectPose!
        bridge.observeObject(screen: lastTracked, tracked: false, at: 2.05)
        bridge.observeHand(.left, pose: pose(0, 1.19, -0.6), tracked: true, at: 2.05)
        let first = bridge.decide(at: 2.05)!
        XCTAssertEqual(distance(first.pose, lastTracked), 0, accuracy: 0.0005,
                       "the first bridged frame is where the camera left the card")

        // …and by the end of the blend the residual is gone: the card is on the hand's own answer.
        bridge.observeHand(.left, pose: pose(0, 1.19, -0.6), tracked: true, at: 2.35)
        let settled = bridge.decide(at: 2.35)!
        XCTAssertGreaterThan(distance(settled.pose, first.pose), 0,
                             "the residual has to actually be blended out")
    }

    /// `--bridge-orientation frozen` (the default): the wrist supplies the translation and the last frame
    /// the camera saw supplies the rotation. A wrist that rolls 30° while the object is missing moves the
    /// card not at all; with `hand` it turns the card by the full 30°, which is V3-2b and what produced
    /// `rotJitter = 3.5–12.4°` and a `tilt 141°` face-down false positive.
    func testFrozenOrientationIgnoresTheWristsOwnRotation() {
        func run(_ orientation: HandBridge.Orientation) -> simd_quatf {
            var bridge = HandBridge()
            bridge.orientation = orientation
            let device = HandBridge.pose(rotation: simd_quatf(angle: 0.3, axis: [1, 0, 0]),
                                         translation: [0, 1.2, -0.6])
            for k in 0...60 {
                let t = Double(k) / 30
                bridge.observeHand(.left, pose: pose(0, 1.17, -0.6), tracked: true, at: t)
                bridge.observeObject(screen: device, tracked: true, at: t)
            }
            bridge.observeObject(screen: device, tracked: false, at: 2.05)
            // The wrist rolls 30° about its own X while the object is missing.
            let rolled = HandBridge.pose(rotation: simd_quatf(angle: 30 * .pi / 180, axis: [1, 0, 0]),
                                         translation: [0, 1.17, -0.6])
            bridge.observeHand(.left, pose: rolled, tracked: true, at: 2.05)
            _ = bridge.decide(at: 2.05)
            bridge.observeHand(.left, pose: rolled, tracked: true, at: 2.4)
            return HandBridge.rotation(of: bridge.decide(at: 2.4)!.pose)
        }
        let frozen = run(.frozen), followed = run(.hand)
        let reference = simd_quatf(angle: 0.3, axis: [1, 0, 0])
        func degrees(_ a: simd_quatf, _ b: simd_quatf) -> Float {
            abs((a.inverse * b).angle) * 180 / .pi
        }
        XCTAssertLessThan(degrees(frozen, reference), 1, "frozen must not follow the wrist at all")
        XCTAssertGreaterThan(degrees(followed, reference), 20, "--bridge-orientation hand is V3-2b's")
    }

    // MARK: - V3-5 §1: the pick-up, and the world

    /// **The 9.7 s freeze.** Picking the passport up off a desk from above puts the wrist / middle-knuckle
    /// midpoint 8–12 cm from the device's centre, and the fingers close over the passport *before* the
    /// wrist is anywhere near it. At `attachRadius` 0.10 no offset was ever learned — the second headset
    /// round recorded `[timing] pick-up: loss → carrying 9.71 s` with `hands=L(-)·R(-)` and `bridged=0%`
    /// throughout, waiting the 8.5 s ARKit needed to find the passport again. At 0.15 the grip is learned.
    func testAGripFromAboveIsLearnedAtTheWiderRadius() {
        let device = pose(0, 1.05, -0.6)
        // The reaching hand: 12 cm above the passport's centre, which is where the midpoint of a grip from
        // above actually sits.
        let overhead = pose(0, 1.17, -0.6)

        var narrow = HandBridge()
        narrow.attachRadius = 0.10
        narrow.observeHand(.right, pose: overhead, tracked: true, at: 1.0)
        narrow.observeObject(screen: device, tracked: true, at: 1.0)
        XCTAssertFalse(narrow.hasOffset(.right), "10 cm is the radius that produced the 9.7 s freeze")

        var bridge = HandBridge()
        XCTAssertEqual(bridge.attachRadius, 0.15, accuracy: 1e-6, "V3-5 §1's default")
        for k in 0...40 {
            let t = Double(k) / 30
            bridge.observeHand(.right, pose: overhead, tracked: true, at: t)
            bridge.observeObject(screen: device, tracked: true, at: t)
        }
        XCTAssertTrue(bridge.hasOffset(.right), "a grip from above 12 cm away is a grip")
        // …and the offset really is the lever, not an average of nothing: it puts the card back on the device.
        let offset = bridge.offset(.right)!
        XCTAssertEqual(distance(overhead * offset, device), 0, accuracy: 0.001)
        // The other wrist, held where the wearer's other hand would be, is still nowhere near it.
        bridge.observeHand(.left, pose: pose(0.35, 1.1, -0.6), tracked: true, at: 1.4)
        bridge.observeObject(screen: device, tracked: true, at: 1.4)
        XCTAssertFalse(bridge.hasOffset(.left), "15 cm may not reach across to the other hand")
    }

    /// **Inside a world nothing is decided and nothing is spent.** The tracker is paused under `.full`
    /// immersion: the object stream is switched off, not failing. The second headset round burned the whole
    /// budget on that non-loss (`bridge on (right, holding 18.1 s, 0.03 s after loss)` at world entry, then
    /// `3 s up`) and left `expired` set for the moment it was needed — the way out, which froze for 7 s.
    func testAPausedBridgeDecidesNothingAndSpendsNothing() {
        var bridge = HandBridge()
        let device = pose(0, 1.2, -0.6)
        let wrist = pose(0, 1.10, -0.6)
        for k in 0...60 {
            let t = Double(k) / 30
            bridge.observeHand(.left, pose: wrist, tracked: true, at: t)
            bridge.observeObject(screen: device, tracked: true, at: t)
        }
        // The shell goes opaque: the world has the tracker.
        bridge.setPaused(true, at: 2.0)
        XCTAssertTrue(bridge.isPaused)
        // Thirty seconds of world. The hand keeps being tracked; the camera says nothing at all.
        for k in 0...600 {
            let t = 2.0 + Double(k) / 20
            bridge.observeHand(.left, pose: wrist, tracked: true, at: t)
            XCTAssertNil(bridge.decide(at: t), "the bridge answered inside a world at \(t)")
        }
        XCTAssertFalse(bridge.expired, "a world may not spend the budget")
    }

    /// **And the unpause is the loss instant.** Coming out of a world with the passport still in the hand
    /// and the camera not yet on it, the bridge carries the card home instead of freezing — which is the
    /// `held(world) → held(stale)` the headset round ended every world exit with.
    func testTheUnpauseIsTheLossInstantAndTheGripSurvivesTheWorld() {
        var bridge = HandBridge()
        let device = pose(0, 1.2, -0.6)
        let wrist = pose(0, 1.10, -0.6)
        for k in 0...60 {
            let t = Double(k) / 30
            bridge.observeHand(.left, pose: wrist, tracked: true, at: t)
            bridge.observeObject(screen: device, tracked: true, at: t)
        }
        bridge.setPaused(true, at: 2.0)
        for k in 0...600 {
            let t = 2.0 + Double(k) / 20
            bridge.observeHand(.left, pose: wrist, tracked: true, at: t)
            _ = bridge.decide(at: t)
        }
        // The shell lifts at t = 32 and the object is not seen again for seconds.
        bridge.setPaused(false, at: 32.0)
        XCTAssertFalse(bridge.isPaused)
        bridge.observeHand(.left, pose: wrist, tracked: true, at: 32.3)
        let drive = bridge.decide(at: 32.3)
        XCTAssertNotNil(drive, "0.3 s after the world let go, the hand still has the passport")
        XCTAssertEqual(drive?.side, .left)
        XCTAssertLessThanOrEqual(drive?.afterLoss ?? 99, 0.5, "the loss clock runs from the unpause")
        // The hold did not restart: it carried on through the world.
        XCTAssertGreaterThan(drive?.holding ?? 0, 30)

        // …and a world whose shell goes opaque **inside the 0.25 s hand-over** must not leave the bridging
        // side set. `endBridge` deliberately keeps `bridgingSide` while a blend is in flight, and
        // `holdingHand`'s first rule returns that side *without* the freshness check — so a pause has to
        // cancel the blend before it ends the bridge, or a world hands the card to a grip nobody has
        // confirmed for half a minute.
        var blending = HandBridge()
        let far = pose(0.5, 0.9, -0.3)
        for k in 0...60 {
            let t = Double(k) / 30
            blending.observeHand(.left, pose: wrist, tracked: true, at: t)
            blending.observeObject(screen: device, tracked: true, at: t)
        }
        blending.observeObject(screen: device, tracked: false, at: 2.05)
        XCTAssertNotNil(blending.decide(at: 2.05), "the bridge is driving")
        // Two and a half seconds later the object is back — but the wrist is nowhere near it now, so the
        // grip is never re-confirmed and the stored offset is already stale when the world opens.
        for k in 1...50 {
            let t = 2.05 + Double(k) / 20
            blending.observeHand(.left, pose: far, tracked: true, at: t)
            _ = blending.decide(at: t)
        }
        blending.observeHand(.left, pose: far, tracked: true, at: 4.5)
        blending.observeObject(screen: device, tracked: true, at: 4.5)
        XCTAssertEqual(blending.decide(at: 4.5)?.kind, .blending, "the hand-over has started")
        blending.setPaused(true, at: 4.55)                       // the shell goes opaque mid-blend
        for k in 0...400 {
            let t = 4.55 + Double(k) / 20
            blending.observeHand(.left, pose: far, tracked: true, at: t)
        }
        blending.setPaused(false, at: 24.55)
        blending.observeHand(.left, pose: far, tracked: true, at: 24.8)
        XCTAssertNil(blending.decide(at: 24.8),
                     "a pause inside the hand-over may not carry the bridging side across the world")

        // A hand that had already let go before the world opened is *not* revived by the unpause.
        var other = HandBridge()
        for k in 0...60 {
            let t = Double(k) / 30
            other.observeHand(.left, pose: wrist, tracked: true, at: t)
            other.observeObject(screen: device, tracked: true, at: t)
        }
        // Two seconds of the camera watching the passport with the hand nowhere near it.
        for k in 0...60 {
            let t = 2.0 + Double(k) / 30
            other.observeHand(.left, pose: pose(0.4, 1.0, -0.4), tracked: true, at: t)
            other.observeObject(screen: device, tracked: true, at: t)
        }
        other.setPaused(true, at: 4.0)
        other.setPaused(false, at: 20.0)
        other.observeHand(.left, pose: wrist, tracked: true, at: 20.2)
        XCTAssertNil(other.decide(at: 20.2), "a grip the camera had already lost is not restored by a world")
    }
}
