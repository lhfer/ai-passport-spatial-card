import XCTest
import simd

/// **v4 B1 §2–3.** The recognition and the hero card as the product plays them: the first recognition's timing budget,
/// the in-place reveal, the reentry's rise without the count, the live follower roll, and the geometry that mounts the
/// portrait card in v3's card frame, on the hinge and in front of the hand deck.
final class V4IntegrationTests: XCTestCase {
    private let layout = V4.HeroCardLayout(shape: .portrait)
    private var mount: V4.HeroCardMount { V4.HeroCardMount(layout: layout) }

    /// The ribbon's outline for the portrait card, exactly as `Geometry.heroCard(_:)` builds it in the app.
    private var heroGeometry: V4.RecognitionTimeline.Geometry {
        var g = V4.RecognitionTimeline.Geometry.standard
        g.cardWidth = layout.size.x
        g.cardHeight = layout.size.y
        g.cornerRadius = layout.cornerRadius
        g.cardCenterHeight = V4.HeroCardMount.restHeight
        g.cardTiltDegrees = V4.HeroCardMount.restPitch * 180 / .pi
        return g
    }

    // MARK: - The first recognition's budget

    /// Bible §3: the first recognition lands in ≤ 3.5 s. The ribbon closes at 1.90 s; from there the card dissolves
    /// in (0.6–0.8 s, brief), pops up and counts — and the count's last reel lands by 3.5 s.
    func testTheFirstRecognitionLandsInsideThreeAndAHalfSeconds() {
        let beats = V4.RecognitionTimeline.Beats.standard
        let reveal = V4.HeroCardTimeline.revealInPlace()
        XCTAssertEqual(reveal.dissolveDuration, 0.7, accuracy: 1e-9)
        XCTAssertTrue((0.6...0.8).contains(reveal.dissolveDuration), "brief: 0.6–0.8 s")
        let landing = Double(beats.closure) + reveal.countLanding
        XCTAssertLessThanOrEqual(landing, 3.5, "count lands at \(landing) s")
        XCTAssertGreaterThan(landing, 3.3, "…and not by cutting the count short")
        XCTAssertEqual(reveal.odometerDuration, 1.2, accuracy: 1e-9, "A4's count, unchanged")
        // The entrance hands over to idle a tenth after the landing.
        XCTAssertEqual(reveal.entranceDuration, reveal.countLanding + reveal.settleTail, accuracy: 1e-9)
    }

    /// Brief: 轮廓画完 → 溶解显形 → 立体书弹出 → 数字滚动. The dissolve starts first, the pop-up leaves the face while it
    /// is still finishing (follow-through), and every layer is up well before the count lands.
    func testTheRevealIsSequencedDissolveThenPopUpThenTheCountLanding() {
        let reveal = V4.HeroCardTimeline.revealInPlace()
        XCTAssertEqual(reveal.dissolveProgress(at: 0), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(reveal.layerStart, 0.3, "the pop-up waits for the dissolve to be under way")
        XCTAssertLessThan(reveal.layerStart, reveal.dissolveDuration, "…and overlaps its end (follow-through)")
        let lastLayer = reveal.layerPopOrder.map(reveal.layerStartTime).max() ?? 0
        XCTAssertLessThan(lastLayer + 0.6, reveal.countLanding, "the pop-up has settled before the count lands")
        XCTAssertGreaterThan(reveal.countLanding, reveal.dissolveDuration)
    }

    func testTheDissolveFillsMonotonicallyAndTheTypeArrivesBehindItsFront() {
        let reveal = V4.HeroCardTimeline.revealInPlace()
        var previous = -1.0, previousContent = -1.0
        var t = 0.0
        while t <= 1.0 {
            let p = reveal.dissolveProgress(at: t)
            let c = reveal.contentOpacity(at: t)
            XCTAssertGreaterThanOrEqual(p, previous)
            XCTAssertGreaterThanOrEqual(c, previousContent)
            // Behind the front: nothing until a third of the card has filled in, all of it only near the end.
            if p <= reveal.contentFadeRange.lowerBound { XCTAssertEqual(c, 0, accuracy: 1e-9, "type ahead of the front at \(t)") }
            if c >= 0.999 { XCTAssertGreaterThanOrEqual(p, reveal.contentFadeRange.upperBound - 0.01) }
            previous = p
            previousContent = c
            t += 0.005
        }
        XCTAssertEqual(reveal.dissolveProgress(at: reveal.dissolveDuration), 1, accuracy: 1e-9)
        XCTAssertEqual(reveal.contentOpacity(at: 0.1), 0, accuracy: 1e-9, "nothing floats in an empty outline")
        XCTAssertEqual(reveal.contentOpacity(at: reveal.dissolveDuration), 1, accuracy: 1e-9)
    }

    /// A4's opaque shadow caster would read as a grey board through the dissolve's unfilled middle: it arrives only as
    /// the dissolve closes (and A4's own rise keeps it from the first frame).
    func testTheShadowCasterArrivesOnlyAsTheDissolveCloses() {
        let reveal = V4.HeroCardTimeline.revealInPlace()
        XCTAssertEqual(reveal.casterOpacity(at: 0.3), 0, accuracy: 1e-9)
        XCTAssertEqual(reveal.casterOpacity(at: 0.45), 0, accuracy: 1e-9)
        XCTAssertEqual(reveal.casterOpacity(at: reveal.dissolveDuration), 1, accuracy: 1e-9)
        XCTAssertEqual(V4.HeroCardTimeline().casterOpacity(at: 0), 1)
        XCTAssertEqual(V4.HeroCardTimeline.riseWithoutCount().casterOpacity(at: 0), 1)
    }

    /// In place: the card never travels — it stands where the ribbon drew it for the whole entrance.
    func testTheInPlaceRevealStandsInTheRibbonsOutline() {
        let reveal = V4.HeroCardTimeline.revealInPlace()
        let g = heroGeometry
        for t in stride(from: 0.0, through: reveal.entranceDuration, by: 0.05) {
            let pose = reveal.pose(at: t, startScale: 0.2)
            XCTAssertEqual(pose, reveal.restPose)
        }
        XCTAssertEqual(reveal.restPose.position.y, g.cardCenterHeight, accuracy: 1e-6)
        XCTAssertEqual(reveal.restPose.pitch, g.tilt, accuracy: 1e-6)
        XCTAssertEqual(reveal.restPose.scale, 1)
    }

    /// A4's own entrance is untouched by the new modes.
    func testTheRiseStillDissolvesNothing() {
        let rise = V4.HeroCardTimeline()
        XCTAssertEqual(rise.entrance, .rise)
        XCTAssertEqual(rise.dissolveProgress(at: 0), 1)
        XCTAssertEqual(rise.contentOpacity(at: 0), 1)
        XCTAssertTrue(rise.countsUp)
        XCTAssertEqual(rise.entranceDuration, rise.countLanding + rise.settleTail, accuracy: 1e-9)
    }

    // MARK: - The portrait outline

    /// The ribbon draws the card the reveal fills: 0.20 × 0.28 m with A4's corners, closing on its own top-right.
    func testTheRibbonDrawsThePortraitHeroCard() {
        let g = heroGeometry
        let timeline = V4.RecognitionTimeline(geometry: g)
        XCTAssertEqual(g.cardWidth, 0.20, accuracy: 1e-6)
        XCTAssertEqual(g.cardHeight, 0.28, accuracy: 1e-6)
        XCTAssertEqual(g.cornerRadius, 0.018, accuracy: 1e-6)
        XCTAssertEqual(g.cardTiltDegrees, -6, accuracy: 1e-4)
        XCTAssertEqual(simd_distance(timeline.closurePoint, g.onCard(0.10, 0.14 - 0.018)), 0, accuracy: 1e-5)
        XCTAssertEqual(timeline.headDistance(at: 1.9), timeline.path.length, accuracy: 1e-3)
        // Every outline point lies on the tilted card plane.
        var s = timeline.outlineStart
        while s <= timeline.path.length {
            let p = timeline.path.point(atDistance: s) - g.cardCenter
            XCTAssertEqual(simd_dot(p, g.cardNormal), 0, accuracy: 3e-4)
            s += 0.01
        }
    }

    /// H0 with the real case: past its launch the flight never crosses the **case** prism (60 × 96 mm, 11.5 mm off
    /// the screen towards the reader) below 8 cm.
    func testTheFlightStaysOffTheRealCase() {
        let timeline = V4.RecognitionTimeline(geometry: heroGeometry)
        var footprint = DeviceFootprint.aiPassport
        footprint.lcdCenter = V4.ScreenOffset.measured
        let caseCenter = V4.ScreenOffset.caseCenter(offset: V4.ScreenOffset.measured)
        var s = timeline.spiralStart
        while s <= timeline.path.length {
            let inS = timeline.path.point(atDistance: s)
            let inC = inS - caseCenter
            let over = abs(inC.x) <= footprint.half.x && abs(inC.z) <= footprint.half.y
            XCTAssertFalse(over && inC.y < 0.08, "over the case at \(s) m: \(inS)")
            s += 0.003
        }
    }

    // MARK: - The reentry: the rise without the count

    func testTheReentryRisesWithoutRecountingTheKnownNumber() {
        let rise = V4.HeroCardTimeline.riseWithoutCount()
        XCTAssertFalse(rise.countsUp)
        XCTAssertGreaterThan(rise.odometerTime(at: 0), V4.HeroCardOdometer(target: 4401).landing,
                             "the reels have always landed")
        XCTAssertNil(rise.sparkle(at: rise.countLanding + 0.1))
        XCTAssertNil(rise.glint(at: rise.countLanding + 0.1))
        // Over once the rise and the pop-up have settled — well inside the bible's 2.5 s for an un-skippable segment.
        XCTAssertLessThanOrEqual(rise.entranceDuration, 1.5)
        XCTAssertGreaterThan(rise.entranceDuration, (rise.layerPopOrder.map(rise.layerStartTime).max() ?? 0) + 0.4)
        XCTAssertGreaterThan(rise.firstSweepTime, rise.entranceDuration)
        // It still leaves the screen the way A4 designed: flat and at the screen's size.
        let first = rise.pose(at: 0, startScale: 0.18)
        XCTAssertEqual(first.pitch, -.pi / 2, accuracy: 1e-5)
    }

    // MARK: - The live follower count

    /// +12 on 4,401: the thousands and hundreds never move, the tens turn once, the ones run on to 3.
    func testALiveChangeRollsOnlyTheColumnsThatChange() {
        let odometer = V4.HeroCardOdometer(target: 4413, start: 4401)
        XCTAssertEqual(odometer.value(at: 0), 4401, accuracy: 1e-9)
        XCTAssertEqual(odometer.displayed(at: -1), 4401)
        for t in stride(from: -0.05, through: odometer.landing + 0.05, by: 0.002) {
            XCTAssertEqual(odometer.reelPosition(column: 3, at: t), 4, accuracy: 1e-9, "thousands")
            XCTAssertEqual(odometer.reelPosition(column: 2, at: t), 44, accuracy: 1e-9, "hundreds")
            let tens = odometer.reelPosition(column: 1, at: t)
            XCTAssertGreaterThanOrEqual(tens, 440 - 1e-9)
            XCTAssertLessThanOrEqual(tens, 441 + 1e-9)
            XCTAssertEqual(odometer.lit(column: 3, at: t), 1, accuracy: 1e-9, "no ghost zeros on a live number")
        }
        for column in 0..<4 {
            let landed = odometer.reelPosition(column: column, at: odometer.landing)
            XCTAssertEqual(landed, floor(4413 / pow(10, Double(column))), accuracy: 1e-6, "column \(column) lands")
        }
    }

    func testALiveRollIsNeverAheadOfItsCountAndOnlyGoesForward() {
        let odometer = V4.HeroCardOdometer(target: 4413, start: 4401)
        var previous = odometer.reelPosition(column: 0, at: 0)
        for t in stride(from: 0.0, through: odometer.landing, by: 0.0005) {
            let reel = odometer.reelPosition(column: 0, at: t)
            XCTAssertGreaterThanOrEqual(reel, previous - 1e-9)
            XCTAssertLessThanOrEqual(reel, odometer.value(at: t) + 1e-6, "the ones reel reads ahead of the count at \(t)")
            previous = reel
        }
    }

    /// No carry reaches the two leading columns, so the only gold dust is the landing's.
    func testALiveRollPopsOnlyOnTheLanding() {
        let pops = V4.HeroCardOdometer(target: 4413, start: 4401).pops()
        XCTAssertEqual(pops.count, 1)
        XCTAssertTrue(pops[0].isLanding)
        // A roll across a hundreds boundary does pop over the hundreds.
        let across = V4.HeroCardOdometer(target: 4512, start: 4495).pops()
        XCTAssertTrue(across.contains { !$0.isLanding && $0.column == 2 })
        // …and the entrance (start 0) is A4's exactly.
        XCTAssertEqual(V4.HeroCardOdometer(target: 4401, start: 0).pops(), V4.HeroCardOdometer(target: 4401).pops())
    }

    /// A lost follower is not rolled backwards through a sum written for growth: the reels stand on the new number.
    func testACountDownSnaps() {
        let down = V4.HeroCardOdometer(target: 4400, start: 4401)
        XCTAssertEqual(down.start, 4400)
        XCTAssertEqual(down.displayed(at: 0), 4400)
        XCTAssertEqual(down.reelPosition(column: 0, at: 0.3), 4400, accuracy: 1e-9)
    }

    // MARK: - The mount in v3's card frame

    /// The rig writes its pose in S; composed with the mount's inverse rest pose it is the identity at rest — the hero
    /// card stands exactly where v3's `cardGroup` rests (and the ribbon drew the outline).
    func testTheMountUndoesTheRestPose() {
        let rest = V4.HeroCardTimeline().restPose
        let restRotation = simd_quatf(angle: rest.pitch, axis: [1, 0, 0])
        let inverse = V4.HeroCardMount.inverseRest
        let p = SIMD3<Float>(0.03, -0.05, 0.004)
        let world = restRotation.act(p) + rest.position                 // a point of the card, placed by the rig
        let inMount = inverse.rotation.act(world) + inverse.translation   // …then through the mount
        XCTAssertEqual(simd_distance(inMount, p), 0, accuracy: 1e-6)
        XCTAssertEqual(V4.HeroCardMount.restHeight, 0.22, accuracy: 1e-6)
        XCTAssertEqual(V4.HeroCardMount.restPitch * 180 / .pi, -6, accuracy: 1e-4)
    }

    /// On the hinge the card's bottom edge is the hinge; the hand deck keeps v3's relations to the taller card.
    func testTheHandDeckClearsTheTallerCard() {
        let scale: Float = 0.5
        let m = mount
        XCTAssertEqual(m.hingeCardPosition(handScale: scale).y - m.size.y * scale / 2, 0, accuracy: 1e-7)
        XCTAssertEqual(m.deckLift(handScale: scale), 0.005, accuracy: 1e-6)
        // The raised card: 5 mm above the card's top edge, as V3-2a H3 put it over the 0.27 m card.
        let raised = HandDeckLayout.raised(index: 0)
        let raisedBottom = raised.position.y + m.deckLift(handScale: scale) - HandDeckLayout.cardSize.y * raised.scale / 2
        XCTAssertEqual(raisedBottom - m.handTop(handScale: scale), 0.005, accuracy: 5e-4)
        // The middle deck card still shows the same band above the card as it did over v3's.
        let middle = HandDeckLayout.slot(index: 3, count: 7)
        let exposedV4 = middle.top + m.deckLift(handScale: scale) - m.handTop(handScale: scale)
        let exposedV3 = middle.top - HandDeckLayout.cardTop
        XCTAssertEqual(exposedV4, exposedV3, accuracy: 1e-6)
        // …and every deck card stays behind the hero card's 12 mm slab (6 mm at hand scale).
        for slot in HandDeckLayout.slots(count: 7) {
            XCTAssertLessThan(slot.position.z, -m.thickness * scale, "slot \(slot.index)")
        }
    }

    /// The QR back is behind the slab and A4's shadow caster (0.5 mm behind it).
    func testTheBackFaceIsBehindTheSlabAndTheShadowCaster() {
        XCTAssertLessThan(mount.backZ, -(V4.HeroCardLayout.thickness + 0.0005))
        XCTAssertGreaterThan(mount.backZ, -0.02)
    }

    /// The beam's gold pool stays under the type column and inside the slab.
    func testTheLandingPoolStaysUnderTheTypeAndInsideTheSlab() {
        let m = mount
        let top = m.landingCenter.y + m.landingSize.y / 2
        let bottom = m.landingCenter.y - m.landingSize.y / 2
        XCTAssertLessThanOrEqual(top, layout.panel.minY + 1e-6, "under the type column's box")
        XCTAssertGreaterThanOrEqual(bottom, -m.size.y / 2 - 1e-6, "inside the slab")
        XCTAssertLessThan(m.landingSize.x, m.size.x)
    }

    func testTheBeamAimsAtThePortraitSlab() {
        let m = mount
        XCTAssertEqual(m.rayBottom, -0.14, accuracy: 1e-6)
        XCTAssertEqual(m.rayTargetZ, -0.006, accuracy: 1e-6)
        XCTAssertEqual(m.rayHalfWidth, 0.092, accuracy: 1e-6)
        XCTAssertEqual(m.shaftHeight, 0.22 - 0.14 + 0.02, accuracy: 1e-6)
        XCTAssertEqual(m.tapSize, m.size)
    }

    // MARK: - `--ribbon-dust`

    func testTheDustKnobScalesTheCountNotTheMotes() {
        let standard = V4.GoldDustSpec.standard
        XCTAssertEqual(standard.scaled(by: 1), standard)
        let double = standard.scaled(by: 2)
        XCTAssertEqual(double.trail.birthRate, standard.trail.birthRate * 2, accuracy: 1e-4)
        XCTAssertEqual(double.dissolve.birthRate, standard.dissolve.birthRate * 2, accuracy: 1e-4)
        XCTAssertEqual(double.sparkle.burstCount, standard.sparkle.burstCount * 2)
        XCTAssertEqual(double.trail.size, standard.trail.size)
        XCTAssertEqual(double.trail.lifeSpan, standard.trail.lifeSpan)
        XCTAssertLessThanOrEqual(standard.scaled(by: 1.15).peakAlive, 400, "the recognition's particle budget")
        XCTAssertEqual(standard.scaled(by: 0).peakAlive, 0)
        XCTAssertEqual(standard.scaled(by: .nan), standard)
    }
}
