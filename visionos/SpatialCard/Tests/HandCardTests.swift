import XCTest
import simd

/// v3 H2: the two pure pieces of the hand-held card — the ring UP / DOWN walk (`HandPager`) and which way the
/// card faces while it is on the device (`HandFacing`).
final class HandCardTests: XCTestCase {
    // MARK: - The pager

    private func pager(worlds: [String] = ["neon-city", "data-nebula"],
                       notes: [String] = ["n1", "n2", "n3", "n4", "n5"]) -> HandPager {
        var p = HandPager()
        p.sync(worlds: worlds, notes: notes)
        return p
    }

    /// One ring: profile → each world in coin order → the three latest notes → profile. Only three notes,
    /// however many the hub sent: the ring is a thing you walk, not a list you scroll.
    func testRingIsProfileThenWorldsThenThreeNotes() {
        let p = pager()
        XCTAssertEqual(p.pages, [.profile, .world("neon-city"), .world("data-nebula"),
                                 .note("n1"), .note("n2"), .note("n3")])
        XCTAssertEqual(p.count, 6)
        XCTAssertEqual(p.page, .profile)
    }

    /// DOWN walks forward and wraps; UP walks back and wraps the other way.
    func testStepWrapsBothWays() {
        var p = pager()
        XCTAssertEqual(p.step(1), .world("neon-city"))
        XCTAssertEqual(p.step(1), .world("data-nebula"))
        XCTAssertEqual(p.step(1), .note("n1"))
        XCTAssertEqual(p.step(1), .note("n2"))
        XCTAssertEqual(p.step(1), .note("n3"))
        XCTAssertEqual(p.step(1), .profile, "the ring closes")
        XCTAssertEqual(p.step(-1), .note("n3"), "…and UP from the profile is the last page")
        XCTAssertEqual(p.step(-1), .note("n2"))
        XCTAssertEqual(p.index, 4)
    }

    /// Nothing to page through (no worlds, no notes): the pager says so instead of flipping the card to the
    /// page it is already on.
    func testSinglePageRingDoesNotFlip() {
        var p = pager(worlds: [], notes: [])
        XCTAssertEqual(p.count, 1)
        XCTAssertNil(p.step(1))
        XCTAssertNil(p.step(-1))
        XCTAssertEqual(p.page, .profile)
    }

    /// The hub's list lands seconds after the space opens, and lands again whenever a note is published. A
    /// page that survives stays put; one whose note has gone falls back to the profile rather than rendering
    /// an empty frame.
    func testSyncKeepsAValidPageAndDropsAStaleOne() {
        var p = pager()
        _ = p.step(1)
        _ = p.step(1)
        _ = p.step(1)
        XCTAssertEqual(p.page, .note("n1"))

        p.sync(worlds: ["neon-city", "data-nebula"], notes: ["n0", "n1", "n2"])
        XCTAssertEqual(p.page, .note("n1"), "still in the list, still on it")

        p.sync(worlds: ["neon-city", "data-nebula"], notes: ["n7", "n8", "n9"])
        XCTAssertEqual(p.page, .profile, "the note it was showing is gone")

        // A world that disappears (the `--all-worlds` set shrinking) does the same.
        _ = p.step(1)
        XCTAssertEqual(p.page, .world("neon-city"))
        p.sync(worlds: ["data-nebula"], notes: ["n7"])
        XCTAssertEqual(p.page, .profile)
    }

    /// Settling on the desk, folding away and entering a world all end the pager.
    func testResetGoesBackToTheProfile() {
        var p = pager()
        _ = p.step(-1)
        XCTAssertEqual(p.page, .note("n3"))
        p.reset()
        XCTAssertEqual(p.page, .profile)
        XCTAssertEqual(p.index, 0)
    }

    /// What `[hand] page → …` prints.
    func testPageLabels() {
        XCTAssertEqual(HandPage.profile.label, "profile")
        XCTAssertEqual(HandPage.world("neon-city").label, "neon-city")
        XCTAssertEqual(HandPage.note("68c1f2a09b3e4d5a6b7c8d9e").label, "note 68c1f2")
    }

    // MARK: - The facing policy

    /// `device` has to reproduce the base orientation **exactly** — it is the control in the A/B the headset
    /// will run, and an approximation there would compare the wrong thing.
    func testDeviceFacingIsExactlyTheBaseOrientation() {
        for head in [SIMD3<Float>(0.3, 0.6, 0.4), SIMD3<Float>(-1, 2, -3), SIMD3<Float>(0, 0.035, 0)] {
            let q = HandFacing.orientation(mode: .device, card: [0, 0.035, 0], head: head)
            let (_, angle) = PresenceGate.delta(from: simd_float4x4(q), to: simd_float4x4(HandFacing.base))
            // In degrees: `acos` next to 1 turns single-precision dust into 0.06°, which is not a deviation.
            XCTAssertEqual(angle * 180 / .pi, 0, accuracy: 0.1, "head at \(head)")
        }
        // …and the base orientation is the one the card lies in on the screen: front along the screen's
        // normal (+Y), top toward the screen's top edge (anchor −Z). `foldIntoDevice` ends here too.
        let m = simd_float4x4(HandFacing.base)
        XCTAssertEqual(simd_dot(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z), SIMD3<Float>(0, 1, 0)),
                       1, accuracy: 1e-5, "the card's front is the screen's normal")
        XCTAssertEqual(simd_dot(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z), SIMD3<Float>(0, 0, -1)),
                       1, accuracy: 1e-5, "the card's top is the screen's top edge")
    }

    /// `billboard` looks straight at the reader; `hybrid` gets 60 % of the way there. The point of the blend
    /// is that the card still *belongs* to the device — 20° of object-tracker orientation error becomes 8°.
    func testHybridIsSixtyPercentOfTheWayToTheReader() {
        let card = SIMD3<Float>(0, 0.035, 0)
        let head = SIMD3<Float>(0, 0.5, 0.5)          // 45° up and toward the reader, in the device's frame
        let screenNormal = SIMD3<Float>(0, 1, 0)
        let toHead = simd_normalize(head - card)
        let full = acos(simd_dot(screenNormal, toHead))

        func normal(_ mode: HandFacing) -> SIMD3<Float> {
            let m = simd_float4x4(HandFacing.orientation(mode: mode, card: card, head: head))
            return simd_normalize(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        }
        XCTAssertEqual(simd_dot(screenNormal, normal(.device)), 1, accuracy: 1e-5)
        XCTAssertEqual(acos(simd_dot(screenNormal, normal(.hybrid))), full * 0.6, accuracy: 1e-3)
        XCTAssertEqual(simd_dot(normal(.billboard), toHead), 1, accuracy: 1e-5)
    }

    /// However far the card has turned toward the reader, its up stays as close to the screen's top edge as
    /// that leaves room for — the card reads as standing *on* the passport, not floating beside it.
    func testUpStaysWithTheScreensTopEdge() {
        let card = SIMD3<Float>(0, 0.035, 0)
        for head in [SIMD3<Float>(0, 0.6, 0.5), SIMD3<Float>(0.4, 0.7, 0.2), SIMD3<Float>(-0.3, 0.5, 0.6)] {
            let m = simd_float4x4(HandFacing.orientation(mode: .billboard, card: card, head: head))
            let up = simd_normalize(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
            let z = simd_normalize(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            XCTAssertEqual(simd_dot(up, z), 0, accuracy: 1e-4, "orthonormal")
            XCTAssertGreaterThan(simd_dot(up, SIMD3<Float>(0, 0, -1)), 0, "up leans toward the screen's top")
        }
    }

    /// Degenerate inputs must not produce a NaN orientation: no head pose at all (the simulator before world
    /// tracking exists), and a reader standing exactly where the card is.
    func testDegenerateInputsFallBackToTheScreensOwnNormal() {
        let noHead = HandFacing.orientation(mode: .hybrid, card: [0, 0.035, 0], head: nil)
        let (_, angle) = PresenceGate.delta(from: simd_float4x4(noHead), to: simd_float4x4(HandFacing.base))
        XCTAssertEqual(angle * 180 / .pi, 0, accuracy: 0.1)

        let onTop = HandFacing.orientation(mode: .billboard, card: [0, 0.035, 0], head: [0, 0.035, 0])
        XCTAssertTrue(onTop.vector.x.isFinite && onTop.vector.w.isFinite)

        // The reader directly above the device: the blend takes the normal onto the up hint itself, and the
        // basis still has to be well formed rather than collapsing.
        let above = HandFacing.orientation(mode: .billboard, card: [0, 0.035, 0], head: [0, 0.035, -1])
        let m = simd_float4x4(above)
        let up = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        XCTAssertEqual(simd_length(up), 1, accuracy: 1e-4)
    }

    /// The exponential approach: τ 0.12 s covers 63 % of the turn in one time constant, never overshoots, and
    /// survives a stalled main actor (a 2 s dt is clamped, not teleported through).
    func testFacingStepIsAnExponentialApproach() {
        let from = HandFacing.base
        let to = HandFacing.orientation(mode: .billboard, card: [0, 0.035, 0], head: [0, 0.5, 0.5])
        let (_, full) = PresenceGate.delta(from: simd_float4x4(from), to: simd_float4x4(to))

        let oneTau = HandFacing.step(current: from, target: to, dt: 0.12, tau: 0.12)
        let (_, covered) = PresenceGate.delta(from: simd_float4x4(from), to: simd_float4x4(oneTau))
        XCTAssertEqual(covered / full, 0.632, accuracy: 0.02)

        var q = from
        for _ in 0..<60 { q = HandFacing.step(current: q, target: to, dt: 1.0 / 60, tau: 0.12) }
        let (_, remaining) = PresenceGate.delta(from: simd_float4x4(q), to: simd_float4x4(to))
        XCTAssertLessThan(remaining * 180 / .pi, 0.5, "converges, does not oscillate")

        let stalled = HandFacing.step(current: from, target: to, dt: 2.0, tau: 0.12)
        let (_, jump) = PresenceGate.delta(from: simd_float4x4(from), to: simd_float4x4(stalled))
        XCTAssertLessThanOrEqual(jump, full + 1e-3, "clamped to one 0.25 s step, never past the target")
        XCTAssertEqual(HandFacing.step(current: from, target: to, dt: 0, tau: 0.12).vector, from.vector)
    }
    // MARK: - V3-2a H2: the hinge (plan §4 E3)

    /// Weight 0 has to reproduce the base **exactly** — the A/B between `--hand-form hinge` and `hover` on
    /// the headset is only meaningful if "no blend" means the identity and not something 0.001 rad off it.
    func testHingeWeightZeroIsExactlyTheBase() {
        let q = HandFacing.hinged(weight: 0, card: [0, 0.0675, 0], head: [0.2, 0.9, 0.4])
        XCTAssertEqual(q.real, 1, accuracy: 0)
        XCTAssertEqual(simd_length(q.imag), 0, accuracy: 0)
    }

    /// 0.6 of the way toward the eyes, and **only** about the hinge's own X axis: the sideways part of
    /// "toward the wearer" is dropped, not turned into yaw or roll, so the card stays square on the device.
    func testHingeBlendsOnlyTheHingeAxisAngle() {
        let card = SIMD3<Float>(0, 0.0675, 0)
        // A head up and in front of the card in hinge space, and well off to one side.
        // 20.6° of hinge angle at full weight: inside the ±35° clamp, so the blend is the thing measured.
        let head = SIMD3<Float>(0.35, -0.30, 0.80)
        let full = HandFacing.hingeAngle(weight: 1, card: card, head: head)
        let blended = HandFacing.hingeAngle(weight: HandFacing.hingeWeight, card: card, head: head)
        XCTAssertEqual(blended, full * HandFacing.hingeWeight, accuracy: 1e-5)
        let q = HandFacing.hinged(weight: HandFacing.hingeWeight, card: card, head: head)
        // Pure rotation about +X: the other two imaginary parts are zero.
        XCTAssertEqual(q.imag.y, 0, accuracy: 1e-6)
        XCTAssertEqual(q.imag.z, 0, accuracy: 1e-6)
        // The sideways offset of the head changes nothing.
        let centred = HandFacing.hingeAngle(weight: HandFacing.hingeWeight, card: card, head: [0, -0.30, 0.80])
        XCTAssertEqual(blended, centred, accuracy: 1e-5)
    }

    /// The cover may not open past ±35°, however far the wearer leans.
    func testHingeAngleIsClampedBothWays() {
        let card = SIMD3<Float>(0, 0.0675, 0)
        // Hinge space: +Y runs up the card (past the device's **top** edge) and +Z out of the screen, so a
        // seated wearer is at −Y / +Z and the cover lifts toward them (positive). A reader on the far side
        // of the passport would lay it the other way, and the clamp has to hold in both directions.
        let towardTheReader = HandFacing.hingeAngle(weight: 1, card: card, head: [0, -1.2, 0.01])
        let awayFromTheReader = HandFacing.hingeAngle(weight: 1, card: card, head: [0, 1.2, 0.01])
        XCTAssertEqual(towardTheReader, HandFacing.hingeClamp, accuracy: 1e-5)
        // V3-3 final: the cover never folds past flat — seen from behind it lies at 0°, not at −35°.
        XCTAssertEqual(awayFromTheReader, 0, accuracy: 1e-5)
        XCTAssertLessThanOrEqual(abs(HandFacing.hingeAngle(weight: 1, card: card, head: [0.9, 1.2, -0.8])),
                                 HandFacing.hingeClamp + 1e-6)
    }

    /// Whatever the hinge angle, the card's up stays in the hinge's own plane: its top edge never swings
    /// sideways off the device's top edge, which is the whole reason the LCD stays clear.
    func testTheCardsUpStaysOverTheTopEdge() {
        let card = SIMD3<Float>(0, 0.0675, 0)
        for head in [SIMD3<Float>(0.4, 0.5, 0.3), [-0.6, 0.2, 0.5], [0, 0.9, -0.2], [0.1, -0.3, 0.7]] {
            let q = HandFacing.hinged(weight: HandFacing.hingeWeight, card: card, head: head)
            let up = q.act(SIMD3<Float>(0, 1, 0))
            XCTAssertEqual(up.x, 0, accuracy: 1e-6, "up leaves the hinge plane for head \(head)")
            let right = q.act(SIMD3<Float>(1, 0, 0))
            XCTAssertEqual(simd_length(right - SIMD3<Float>(1, 0, 0)), 0, accuracy: 1e-6, "the hinge axis itself must not turn")
        }
    }

    // MARK: - V3-2b B0b: a *true* hinge (the arm)

    /// The one thing the arm exists for: the card's bottom edge stays **on the hinge** — at the frame's own
    /// origin — at 0° and at both ends of the ±35° clamp.
    ///
    /// The V3-2a2 model (the same rotation taken about the card's *centre*) is measured beside it, because the
    /// number it produces is the bug: on a 135 mm card at hand scale the bottom edge swung 41 mm off the
    /// device's top edge at the clamp, i.e. the cover floated free exactly when it opened toward the wearer.
    func testTheCardsBottomEdgeStaysOnTheHinge() {
        let halfHeight = HandDeckLayout.cardTop / 2          // 67.5 mm: cardHeight 0.27 × --hand-scale 0.5
        for angle in [0, HandFacing.hingeClamp, -HandFacing.hingeClamp] {
            let edge = HandFacing.cardBottomEdge(angle: angle, halfHeight: halfHeight)
            XCTAssertEqual(simd_length(edge), 0, accuracy: 1e-6, "bottom edge left the hinge at \(angle)")
            // …and the centre is exactly half a card away from it, on the arc the arm sweeps.
            let centre = HandFacing.cardCentre(angle: angle, halfHeight: halfHeight)
            XCTAssertEqual(simd_length(centre), halfHeight, accuracy: 1e-6)
            XCTAssertEqual(centre.x, 0, accuracy: 1e-6, "the arm turns about the hinge's own X axis")
        }
        // The model this replaced, at the clamp: 2·h·sin(α/2).
        let old = HandFacing.cardBottomEdgeAboutCentre(angle: HandFacing.hingeClamp, halfHeight: halfHeight)
        XCTAssertEqual(simd_length(old), 2 * halfHeight * sin(HandFacing.hingeClamp / 2), accuracy: 1e-6)
        XCTAssertGreaterThan(simd_length(old), 0.040, "…which is the 41 mm the arm removes")
    }

    /// The deck is struck in the **arm's** frame, so opening the cover carries the hand of cards with it: how
    /// much of every deck card shows above the name card's top edge is the same at 0° as at ±35°. (Measured
    /// the way the wearer sees it — along the card's own up axis, which the arm turns too.)
    func testTheDecksExposureHoldsAtTheClamp() {
        let slots = HandDeckLayout.slots(count: HandDeckLayout.fullCount)
        let flat = slots.map { $0.top - HandDeckLayout.cardTop }
        for angle in [0, HandFacing.hingeClamp, -HandFacing.hingeClamp] {
            let arm = HandFacing.hinged(angle: angle)
            let up = arm.act(SIMD3<Float>(0, 1, 0))
            let cardTop = arm.act(SIMD3<Float>(0, HandDeckLayout.cardTop, 0))
            for (index, slot) in slots.enumerated() {
                let top = arm.act(SIMD3<Float>(slot.position.x, slot.top, slot.position.z))
                let exposed = simd_dot(top - cardTop, up)
                XCTAssertEqual(exposed, flat[index], accuracy: 1e-5,
                               "slot \(index) exposure moved when the cover opened to \(angle)")
            }
        }
        XCTAssertGreaterThan(flat[HandDeckLayout.fullCount / 2], 0.025, "…and the middle card still shows ≥ 25 mm")
    }
}
