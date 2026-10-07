import XCTest

/// **v4 B4 §2** — a pick-up has to be seen: the hand leaving (+10 cm) or rising (+10 cm) with the passport within 1.5 s of
/// reaching it, outside the put-down's 2 s and the key's 1.5 s. Each scenario is a line of round 2's B3 run 1, where B2's
/// "a hand within 15 cm for 0.5 s" folded the card seven times on the desk and six of them were not pick-ups.
final class V4PickupWatchTests: XCTestCase {
    typealias Watch = V4.PickupFold.PickupWatch
    typealias Hand = Watch.Hand
    let radius: Float = 0.15

    /// Drives the watch at 10 Hz from `from` to `to`, the hand given by `hand(t)`; returns every event and when the fold
    /// would have gone (nil = never).
    func run(_ watch: inout Watch, from: Double, to: Double, settledAt: Double? = nil, keyAt: Double? = nil,
             active: (Double) -> Bool = { _ in true }, hand: (Double) -> Hand?) -> (events: [Watch.Event], foldAt: Double?) {
        var events: [Watch.Event] = []
        var t = from
        while t <= to + 1e-9 {
            events += watch.step(active: active(t), hand: hand(t), radius: radius, at: t, settledAt: settledAt, keyAt: keyAt)
            if watch.shouldFold(at: t) { return (events, t) }
            t += 0.1
        }
        return (events, nil)
    }

    func near(_ cm: Float, over: Float = 0.03) -> Hand { Hand(distance: cm / 100, height: over) }

    /// Line 603: put down, 1 s later lost with the hand still on it (14 cm) — it stays there.
    func testAHandThatStaysAfterThePutDownIsNotAPickUp() {
        var w = Watch()
        let r = run(&w, from: 11.0, to: 16.0, settledAt: 10.0) { _ in self.near(14) }
        XCTAssertNil(r.foldAt)
        XCTAssertTrue(r.events.contains { if case .reach = $0 { return true } else { return false } })
        XCTAssertTrue(r.events.contains { if case .noPickUp = $0 { return true } else { return false } }, "the window runs out")
    }

    /// …and the hand that let go of it withdrawing inside the 2 s: letting go, not a pick-up.
    func testTheHandLettingGoAfterThePutDownIsNotAPickUp() {
        var w = Watch()
        let r = run(&w, from: 11.0, to: 16.0, settledAt: 10.0) { t in t < 11.5 ? self.near(13) : self.near(40, over: 0.08) }
        XCTAssertNil(r.foldAt)
        XCTAssertTrue(r.events.contains { if case .guarded(let why) = $0 { return why.contains("put-down") } else { return false } })
    }

    /// Lines 792 / 832: lost the instant OK (or DOWN) was pressed, the hand on the keys (12–14 cm) — then it goes.
    func testTheHandThatPressedAKeyIsNotAPickUp() {
        var w = Watch()
        let r = run(&w, from: 20.0, to: 25.0, keyAt: 20.1) { t in t < 21.0 ? self.near(12) : self.near(45, over: 0.12) }
        XCTAssertNil(r.foldAt)
        XCTAssertTrue(r.events.contains { if case .guarded(let why) = $0 { return why.contains("key") } else { return false } })
    }

    /// Line 1084: lost with the hand 54 cm away; 3 s later the hand reaches over (14 cm) to press OK and leaves. Timed from
    /// the loss the evidence window would long be over and the fold would have gone on the grab (B2); timed from the reach,
    /// the key's guard covers the hand leaving.
    func testTheWindowOpensAtTheReachNotTheLoss() {
        var w = Watch()
        let r = run(&w, from: 30.0, to: 37.0, keyAt: 33.6) { t in
            if t < 33.0 { return self.near(54) }
            if t < 34.0 { return self.near(14) }
            return self.near(50)
        }
        XCTAssertNil(r.foldAt)
        let reach = r.events.firstIndex { if case .reach = $0 { return true } else { return false } }
        XCTAssertNotNil(reach, "the reach at 33 s opens the window")
    }

    /// Line 1282, the one real pick-up: the hand goes from 15 to 29 cm off where the passport lay within a second.
    func testAHandLeavingWithThePassportIsAPickUp() {
        var w = Watch()
        let r = run(&w, from: 40.0, to: 43.0) { t in
            t < 40.3 ? self.near(15) : Hand(distance: Float(0.15 + min(0.14, (t - 40.3) * 0.25)), height: Float(0.03 + (t - 40.3) * 0.2))
        }
        XCTAssertNotNil(r.foldAt)
        XCTAssertLessThanOrEqual(r.foldAt ?? 99, 41.0, "within a second of the loss")
        XCTAssertGreaterThanOrEqual(r.foldAt ?? 0, 40.5, "never before the hold is 0.5 s old")
        XCTAssertTrue(r.events.contains { if case .evidence = $0 { return true } else { return false } })
    }

    /// The trade-off, written down: 1282 came right after an OK (line 1270). Inside the key's 1.5 s the same evidence is
    /// ignored — the card waits where it was, dimmed, and joins the hand when the passport is seen there (B2's relocation).
    func testAPickUpRightAfterAKeyWaitsInstead() {
        var w = Watch()
        let r = run(&w, from: 40.0, to: 43.0, keyAt: 39.8) { t in
            t < 40.3 ? self.near(15) : Hand(distance: Float(0.15 + min(0.14, (t - 40.3) * 0.25)), height: 0.05)
        }
        XCTAssertNil(r.foldAt)
    }

    /// Lifting it straight up (the hand barely gets farther from where it lay, but rises 11 cm): a pick-up.
    func testAHandRisingWithThePassportIsAPickUp() {
        var w = Watch()
        let r = run(&w, from: 50.0, to: 52.0) { t in
            let up = Float(max(0, min(0.11, (t - 50.2) * 0.2)))
            return Hand(distance: 0.12 + up * 0.5, height: 0.03 + up)
        }
        XCTAssertNotNil(r.foldAt)
        XCTAssertTrue(r.events.contains { if case .evidence(let why) = $0 { return why.contains("rose") } else { return false } })
    }

    /// No hand data (`--no-hands`, a script without a hand): never a pick-up — B2's desk loss, wait and dim.
    func testNoHandIsNeverAPickUp() {
        var w = Watch()
        let r = run(&w, from: 0, to: 10) { _ in nil }
        XCTAssertNil(r.foldAt)
    }

    /// A hand far away the whole time: the desk loss.
    func testAFarHandIsNeverAPickUp() {
        var w = Watch()
        let r = run(&w, from: 0, to: 10) { t in Hand(distance: Float(0.5 + 0.1 * sin(t)), height: 0.2) }
        XCTAssertNil(r.foldAt)
        XCTAssertFalse(r.events.contains { if case .reach = $0 { return true } else { return false } })
    }

    /// After a window closes with the hand still near, nothing counts until the hand has gone; a new reach opens a new one.
    func testANewReachOpensANewWindow() {
        var w = Watch()
        let r = run(&w, from: 0, to: 8) { t in
            if t < 2.5 { return self.near(13) }           // reach at 0, window runs out at 1.5
            if t < 3.0 { return self.near(40) }           // the hand goes (leaves the reach)
            if t < 3.5 { return self.near(12) }           // a new reach at 3.0
            return Hand(distance: 0.30, height: 0.20)     // …and this time it leaves with it
        }
        XCTAssertNotNil(r.foldAt)
        XCTAssertGreaterThanOrEqual(r.foldAt ?? 0, 3.5)
        XCTAssertEqual(r.events.filter { if case .reach = $0 { return true } else { return false } }.count, 2)
        XCTAssertTrue(r.events.contains { if case .handLeft = $0 { return true } else { return false } })
    }

    /// The hold ends (the passport is seen again where it lay) without a pick-up: said so, and everything is forgotten.
    func testAHoldThatEndsForgetsEverything() {
        var w = Watch()
        let r = run(&w, from: 0, to: 4, active: { $0 < 3 }) { _ in self.near(13) }
        XCTAssertNil(r.foldAt)
        XCTAssertTrue(r.events.contains { if case .holdEnded = $0 { return true } else { return false } })
        XCTAssertNil(w.holdSince)
        XCTAssertNil(w.reachAt)
    }

    func testTheLinesSayWhy() {
        let reach = Watch.line(.reach(Hand(distance: 0.14, height: 0.03)))
        XCTAssertTrue(reach.hasPrefix("[pickup] reach (hand 14 cm, +3 cm over the passport)"), reach)
        XCTAssertTrue(Watch.line(.holdStarted(nil)).contains("no hand tracked"))
        XCTAssertTrue(Watch.line(.evidence("x")).hasPrefix("[pickup] a pick-up: "))
    }
}
