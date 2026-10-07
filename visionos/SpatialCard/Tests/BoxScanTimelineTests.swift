import XCTest
import simd

/// **V3-2a2 S1 / plan §4 E1.** The recognition scan's clock, checked without a RealityKit scene: the order
/// the twelve rods are drawn in, where the band stands, when the entrance is allowed to start, and what the
/// scan does with a transition that arrives while it is running.
final class BoxScanTimelineTests: XCTestCase {
    private let w: Float = 0.060, l: Float = 0.095, t: Float = 0.0085

    // MARK: - The two versions

    func testTheFullScanConvergesAtOneOhFiveAndTheSummonAtSixTenths() {
        let full = BoxScanTimeline(full: true)
        XCTAssertEqual(full.edgesIn, 0.25, accuracy: 1e-6)
        XCTAssertEqual(full.bandStart, 0.20, accuracy: 1e-6)
        XCTAssertEqual(full.bandEnd, 0.80, accuracy: 1e-6)
        XCTAssertEqual(full.glowAt, 0.35, accuracy: 1e-6)
        XCTAssertEqual(full.converge, 1.05, accuracy: 1e-6)
        XCTAssertEqual(full.total, 1.20, accuracy: 1e-6)

        let summon = BoxScanTimeline(full: false)
        XCTAssertEqual(summon.edgesIn, 0.12, accuracy: 1e-6)
        XCTAssertEqual(summon.bandStart, 0.15, accuracy: 1e-6)
        XCTAssertEqual(summon.bandEnd, 0.40, accuracy: 1e-6)
        XCTAssertEqual(summon.glowAt, 0.15, accuracy: 1e-6)
        XCTAssertEqual(summon.converge, 0.60, accuracy: 1e-6)
        XCTAssertEqual(summon.total, 0.60, accuracy: 1e-6)
    }

    /// The whole point of sending `glow` when we do: one BLE trip later the real LCD's own 300 ms bar has to
    /// be running while the virtual band crosses the screen area (plan §4 E1: z ±24.5 mm). The two are
    /// intervals, not instants — the device's bar takes 300 ms to run down 320 px.
    func testTheDevicesBarRunsWhileTheBandIsOverTheScreen() {
        let bleTrip: Float = 0.060, glowMs: Float = 0.300, screenHalfZ: Float = 0.0245
        for timeline in [BoxScanTimeline(full: true), BoxScanTimeline(full: false)] {
            // When the virtual band enters and leaves the screen rectangle.
            guard let enters = timeline.bandCrosses(z: screenHalfZ, length: l),
                  let leaves = timeline.bandCrosses(z: -screenHalfZ, length: l) else {
                return XCTFail("the band crosses the screen area")
            }
            let barStart = timeline.glowAt + bleTrip
            let barEnd = barStart + glowMs
            // The device's bar has to be running for the *whole* of the virtual band's pass over the
            // screen — the band crosses those 49 mm in 54 ms on a summon, which is a blink.
            XCTAssertLessThanOrEqual(barStart, enters,
                                     "device bar \(barStart)–\(barEnd) s vs band over the screen \(enters)–\(leaves) s")
            XCTAssertGreaterThanOrEqual(barEnd, leaves,
                                        "device bar \(barStart)–\(barEnd) s vs band over the screen \(enters)–\(leaves) s")
            // …and the real bar never starts before the wireframe is on screen.
            XCTAssertGreaterThan(barStart, timeline.bandStart)
        }
    }

    // MARK: - The band

    func testTheBandRunsFromTheReaderEdgeToTheTopEdge() {
        let timeline = BoxScanTimeline(full: true)
        XCTAssertEqual(timeline.bandZ(at: 0, length: l), l / 2, accuracy: 1e-6)
        XCTAssertEqual(timeline.bandZ(at: timeline.bandStart, length: l), l / 2, accuracy: 1e-6)
        XCTAssertEqual(timeline.bandZ(at: 0.5, length: l), 0, accuracy: 0.002)   // easeInOutCubic is symmetric
        XCTAssertEqual(timeline.bandZ(at: timeline.bandEnd, length: l), -l / 2, accuracy: 1e-6)
        XCTAssertEqual(timeline.bandZ(at: 5, length: l), -l / 2, accuracy: 1e-6)

        // Monotonic: the band never goes back over ground it has covered.
        var previous = Float.greatestFiniteMagnitude
        for step in 0...60 {
            let z = timeline.bandZ(at: Float(step) / 50, length: l)
            XCTAssertLessThanOrEqual(z, previous + 1e-6)
            previous = z
        }
    }

    /// The four vertical rods flash as the band reaches them, which is the start and the end of the sweep.
    func testTheVerticalRodsFlashWhenTheBandReachesThem() {
        let timeline = BoxScanTimeline(full: true)
        let near = timeline.bandCrosses(z: l / 2, length: l)
        let far = timeline.bandCrosses(z: -l / 2, length: l)
        XCTAssertEqual(near ?? -1, timeline.bandStart, accuracy: 0.01)
        XCTAssertEqual(far ?? -1, timeline.bandEnd, accuracy: 0.01)
        XCTAssertNil(timeline.bandCrosses(z: l, length: l))
        // …and the answer really is where the band is.
        if let mid = timeline.bandCrosses(z: 0.01, length: l) {
            XCTAssertEqual(timeline.bandZ(at: mid, length: l), 0.01, accuracy: 0.001)
        } else {
            XCTFail("the band crosses z = 10 mm")
        }
    }

    // MARK: - The twelve edges

    func testTheTwelveEdgesAreTheAnchorBox() {
        let edges = BoxScanTimeline.edges(width: w, length: l, thickness: t)
        XCTAssertEqual(edges.count, 12)
        XCTAssertEqual(edges.filter { $0.along == .x }.count, 4)
        XCTAssertEqual(edges.filter { $0.along == .y }.count, 4)
        XCTAssertEqual(edges.filter { $0.along == .z }.count, 4)
        // Total wire length = 4 × each dimension.
        let total = edges.reduce(Float(0)) { $0 + $1.length }
        XCTAssertEqual(total, 4 * (w + l + t), accuracy: 1e-5)
        // Every rod is on the box's surface, never inside the device's air.
        for edge in edges {
            XCTAssertLessThanOrEqual(abs(edge.mid.x), w / 2 + 1e-6)
            XCTAssertLessThanOrEqual(abs(edge.mid.z), l / 2 + 1e-6)
            XCTAssertLessThanOrEqual(edge.mid.y, 1e-6)
            XCTAssertGreaterThanOrEqual(edge.mid.y, -t - 1e-6)
        }
    }

    /// The outline is drawn *out of* the corner nearest the reader: the first rod is one that touches it,
    /// the last one is across the box, and neighbours are 20 ms apart.
    func testTheEdgesAreStaggeredFromTheReaderCorner() {
        let corner = BoxScanTimeline.readerCorner(width: w, length: l)
        XCTAssertEqual(corner, SIMD3<Float>(w / 2, 0, l / 2))

        let order = BoxScanTimeline.drawOrder(width: w, length: l, thickness: t)
        XCTAssertEqual(order.count, 12)
        XCTAssertEqual(Set(order).count, 12)

        let edges = BoxScanTimeline.edges(width: w, length: l, thickness: t)
        var previous = -Float.greatestFiniteMagnitude
        for index in order {
            let d = simd_length(edges[index].mid - corner)
            XCTAssertGreaterThanOrEqual(d, previous - 1e-6, "the draw order is by distance from the corner")
            previous = d
        }
        // The first rod is the vertical one *standing on* the reader corner (its midpoint is 4.25 mm away,
        // nearer than any rail's), and the last is the vertical rod diagonally opposite it.
        let first = edges[order[0]]
        XCTAssertEqual(first.along, .y)
        XCTAssertEqual(first.mid.x, w / 2, accuracy: 1e-6)
        XCTAssertEqual(first.mid.z, l / 2, accuracy: 1e-6)
        let last = edges[order[11]]
        XCTAssertEqual(last.along, .y)
        XCTAssertEqual(last.mid.x, -w / 2, accuracy: 1e-6)
        XCTAssertEqual(last.mid.z, -l / 2, accuracy: 1e-6)
        // The rail nearest the reader is the one along the reader edge itself, and it is drawn early.
        let readerRail = edges.firstIndex { $0.along == .x && abs($0.mid.z - l / 2) < 1e-6 && $0.mid.y == 0 }
        XCTAssertLessThan(order.firstIndex(of: readerRail ?? 0) ?? 99, 4)

        XCTAssertEqual(BoxScanTimeline.drawDelay(index: order[0], width: w, length: l, thickness: t), 0, accuracy: 1e-6)
        XCTAssertEqual(BoxScanTimeline.drawDelay(index: order[1], width: w, length: l, thickness: t),
                       BoxScanTimeline.edgeStagger, accuracy: 1e-6)
        XCTAssertEqual(BoxScanTimeline.drawDelay(index: order[11], width: w, length: l, thickness: t),
                       11 * BoxScanTimeline.edgeStagger, accuracy: 1e-6)
    }

    /// `--fake-box scan` hands the rig a different box, and the outline is simply cut to it.
    func testTheOutlineFollowsWhateverBoxTheAnchorReports() {
        let edges = BoxScanTimeline.edges(width: 0.0586, length: 0.094, thickness: 0.0052)
        XCTAssertEqual(edges.count, 12)
        let total = edges.reduce(Float(0)) { $0 + $1.length }
        XCTAssertEqual(total, 4 * (0.0586 + 0.094 + 0.0052), accuracy: 1e-5)
    }

    // MARK: - The entrance the scan holds back

    /// The plan's reason for all of this: on the headset the unfold follows the first detection by 34 ms.
    func testAnEntranceThatArrivesDuringTheScanIsDeferredToTheBeat() {
        var pending = BoxScanTimeline.Pending()
        XCTAssertEqual(pending.handle(.intro(.unfold)), .hold)
        XCTAssertEqual(pending.intro, .unfold)
        XCTAssertEqual(pending.take(), .unfold)
        // …and only once.
        XCTAssertNil(pending.take())
    }

    func testTheLatestEntranceWins() {
        var pending = BoxScanTimeline.Pending()
        XCTAssertEqual(pending.handle(.intro(.cinematic)), .hold)
        XCTAssertEqual(pending.handle(.intro(.unfold)), .hold)
        XCTAssertEqual(pending.take(), .unfold)
    }

    /// A freeze is silent: the scan is anchored to the frozen pose and finishes on it, entrance and all.
    func testAFreezeLetsTheScanFinishAndKeepsWhatItIsHolding() {
        var pending = BoxScanTimeline.Pending()
        XCTAssertEqual(pending.handle(.intro(.cinematic)), .hold)
        XCTAssertEqual(pending.handle(.freeze), .pass)
        XCTAssertEqual(pending.intro, .cinematic)
        XCTAssertEqual(pending.take(), .cinematic)
    }

    /// A hide takes the wireframe with it, and the entrance nobody is waiting for any more.
    func testAHideDropsTheWireframeAndThePendingEntrance() {
        var pending = BoxScanTimeline.Pending()
        XCTAssertEqual(pending.handle(.intro(.reentry)), .hold)
        XCTAssertEqual(pending.handle(.hide), .drop)
        XCTAssertNil(pending.intro)
        XCTAssertNil(pending.take())
    }

    func testTheIntroLabelsAreWhatTheLogPrints() {
        XCTAssertEqual(BoxScanTimeline.Intro.cinematic.rawValue, "cinematic")
        XCTAssertEqual(BoxScanTimeline.Intro.reentry.rawValue, "reentry")
        XCTAssertEqual(BoxScanTimeline.Intro.unfold.rawValue, "unfold")
        XCTAssertEqual(BoxScanTimeline.Arrival.intro(.reentry).intro, .reentry)
        XCTAssertNil(BoxScanTimeline.Arrival.freeze.intro)
    }
}
