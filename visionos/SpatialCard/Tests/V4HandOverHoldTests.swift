import XCTest
import simd

/// **v4 B1 follow-up — the hand-over hold.** The first recognition always reveals the card with A1's dissolve: if the
/// materials are still loading at the closure, the outline holds (breathing) and the hand-over waits, at most 2.5 s.
/// These check the numbers the rig and the controller share: where the clock waits, when it runs on, the breath, the
/// release rule and the lingering dust's budget.
final class V4HandOverHoldTests: XCTestCase {
    private let hold = V4.HandOverHold.standard
    private let beats = V4.RecognitionTimeline.Beats.standard

    /// The coordinator's brief: capped at 2.5 s.
    func testTheHoldIsCappedAtTwoAndAHalfSeconds() {
        XCTAssertEqual(hold.cap, 2.5, accuracy: 1e-12)
    }

    /// The clock waits once the ribbon has broken up (only the drawn outline is left) and before the outline's own
    /// hand-over — never on a moving part of the recognition.
    func testTheClockWaitsAfterTheRibbonHasBrokenUpAndBeforeTheHandOver() {
        let point = hold.holdPoint(beats)
        XCTAssertEqual(point, beats.dissolveEnd, accuracy: 1e-6)
        XCTAssertGreaterThan(point, beats.closure)
        XCTAssertLessThan(point, beats.closure + beats.outlineHold, "the outline must not have started to fade")
        let timeline = V4.RecognitionTimeline()
        XCTAssertEqual(timeline.ribbonLevel(at: point), 0, accuracy: 1e-6, "the ribbon is gone")
        XCTAssertEqual(timeline.outlineLevel(at: point), 1, accuracy: 1e-6, "the outline is whole")
        XCTAssertFalse(timeline.isFlying(at: point))
    }

    /// After any hold the outline still hands over when the card is where it always is at the hand-over: the card's
    /// clock at the hand-over equals the unheld `outlineHold` (0.5 s ≈ 80 % dissolved), and the outline is gone when
    /// the card's clock reaches the unheld `outlineHold + outlineFade`.
    func testAfterAHoldTheHandOverLandsAtTheSameCardMoment() {
        let resume = hold.resumeCardClock(beats)
        XCTAssertEqual(resume, Double(beats.dissolveEnd - beats.closure), accuracy: 1e-6)
        let handOverOnCardClock = resume + Double(beats.closure + beats.outlineHold - hold.holdPoint(beats))
        XCTAssertEqual(handOverOnCardClock, Double(beats.outlineHold), accuracy: 1e-6)
        let goneOnCardClock = resume + Double(beats.outlineGone - hold.holdPoint(beats))
        XCTAssertEqual(goneOnCardClock, Double(beats.outlineHold + beats.outlineFade), accuracy: 1e-6)
        let reveal = V4.HeroCardTimeline.revealInPlace()
        let dissolve = reveal.dissolveProgress(at: handOverOnCardClock)
        XCTAssertTrue((0.75...0.85).contains(dissolve), "the card owns the scene at the hand-over (\(dissolve))")
    }

    /// The breath starts without a step or a kink, only ever brightens, peaks half a period in and repeats.
    func testTheBreathStartsSmoothlyAndOnlyBrightens() {
        XCTAssertEqual(hold.breath(held: 0), 1, accuracy: 1e-6)
        XCTAssertLessThan(hold.breath(held: 0.01) - 1, 0.001, "no kink at the start")
        XCTAssertEqual(hold.breath(held: hold.breathPeriod / 2), 1 + hold.breathDepth, accuracy: 1e-5)
        XCTAssertEqual(hold.breath(held: hold.breathPeriod), 1, accuracy: 1e-5)
        for i in 0...300 {
            let h = Float(i) * 0.01
            let b = hold.breath(held: h)
            XCTAssertGreaterThanOrEqual(b, 1 - 1e-6)
            XCTAssertLessThanOrEqual(b, 1 + hold.breathDepth + 1e-6)
            XCTAssertEqual(b, hold.breath(held: h + hold.breathPeriod), accuracy: 1e-4)
        }
        // The stroke settles at 0.62: at the top of the breath it stays inside the ramp (≤ 1), never clipped flat.
        XCTAssertLessThanOrEqual(V4.RibbonProfile.stroke.steady * (1 + hold.breathDepth), 1)
    }

    /// At the release the breath eases back to the outline's own level — monotonic, done after `settle`.
    func testTheBreathSettlesBackToTheOutlinesLevel() {
        let from = hold.breath(held: 0.6)
        XCTAssertEqual(hold.settled(from: from, elapsed: 0), from, accuracy: 1e-6)
        XCTAssertEqual(hold.settled(from: from, elapsed: hold.settle), 1, accuracy: 1e-6)
        XCTAssertEqual(hold.settled(from: from, elapsed: 5), 1, accuracy: 1e-6)
        var last = from
        for i in 1...30 {
            let v = hold.settled(from: from, elapsed: Float(i) * hold.settle / 30)
            XCTAssertLessThanOrEqual(v, last + 1e-6)
            last = v
        }
    }

    /// The release rule: A1's style on the card releases at once; a load that failed releases at once (nothing to
    /// wait for); otherwise the hold waits — until the cap.
    func testTheHoldReleasesOnTheStyleOnAFailureOrAtTheCap() {
        XCTAssertEqual(hold.decide(styleReady: true, mayStillArrive: false, held: 0), .release(.materialsReady))
        XCTAssertEqual(hold.decide(styleReady: true, mayStillArrive: true, held: 9), .release(.materialsReady))
        XCTAssertEqual(hold.decide(styleReady: false, mayStillArrive: false, held: 0), .release(.materialsFailed))
        XCTAssertEqual(hold.decide(styleReady: false, mayStillArrive: true, held: 0), .wait)
        XCTAssertEqual(hold.decide(styleReady: false, mayStillArrive: true, held: 2.49), .wait)
        XCTAssertEqual(hold.decide(styleReady: false, mayStillArrive: true, held: 2.5), .release(.cap))
        XCTAssertEqual(V4.HandOverHold.Reason.materialsReady.rawValue, "materials ready")
    }

    /// The lingering dust is a trickle (a third of the trail's rate, round motes) and cannot push the scene past
    /// A2's 400-mote budget even if it overlapped the recognition's own peak — which it cannot (the trail has stopped).
    func testTheLingeringDustIsATrickleInsideTheBudget() {
        let spec = V4.GoldDustSpec.standard
        let linger = spec.linger
        XCTAssertEqual(linger.birthRate, spec.trail.birthRate * 0.35, accuracy: 1e-4)
        XCTAssertEqual(linger.streak, 0)
        XCTAssertEqual(linger.emitSeconds, Float(hold.cap), accuracy: 1e-6)
        XCTAssertEqual(linger.lifeSpan, spec.trail.lifeSpan, "the same motes as the trail's")
        XCTAssertLessThanOrEqual(spec.peakAlive + linger.peakAlive, 400)
        // `--ribbon-dust` scales it with the rest.
        XCTAssertEqual(spec.scaled(by: 0.5).linger.birthRate, linger.birthRate * 0.5, accuracy: 1e-4)
    }
}
