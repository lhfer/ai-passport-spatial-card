import XCTest
import simd

/// **v4 A2.** The ribbon's paths: a chain of cubic Béziers sampled by arc length. Checked here without a
/// RealityKit scene: lengths, roundness of arcs, even spacing, the helix and Catmull-Rom builders, and that
/// the walking lookup the ribbon uses every frame gives exactly what the bisection gives.
final class V4RibbonSplineTests: XCTestCase {
    typealias Spline = V4.RibbonSpline

    func testALineIsSampledByDistanceAndClamped() {
        let spline = Spline(segments: [Spline.line([0, 0, 0], [0.3, 0, 0])])
        XCTAssertEqual(spline.length, 0.3, accuracy: 1e-5)
        XCTAssertEqual(spline.point(atDistance: 0.1).x, 0.1, accuracy: 1e-4)
        XCTAssertEqual(simd_distance(spline.tangent(atDistance: 0.2), [1, 0, 0]), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_length(spline.point(atDistance: -1)), 0, accuracy: 1e-6)
        XCTAssertEqual(spline.point(atDistance: 5).x, 0.3, accuracy: 1e-5)
    }

    func testAQuarterArcIsRoundAndAsLongAsACircleSays() {
        let r: Float = 0.03
        let spline = Spline(segments: Spline.arc(center: .zero, radius: r, u: [1, 0, 0], v: [0, 1, 0], from: 0, to: .pi / 2))
        XCTAssertEqual(spline.segments.count, 1)
        XCTAssertEqual(spline.length, .pi / 2 * r, accuracy: 0.001 * r)
        for k in 0...40 {
            let p = spline.point(atDistance: spline.length * Float(k) / 40)
            XCTAssertEqual(simd_length(p), r, accuracy: 0.0003 * r, "point \(k) is off the circle")
        }
        // The tangent at the start is along v (anticlockwise from u).
        XCTAssertEqual(simd_distance(spline.tangent(atDistance: 0), [0, 1, 0]), 0, accuracy: 1e-4)
    }

    func testLongArcsAreCutIntoQuarterPiecesEitherWayRound() {
        let forward = Spline.arc(center: .zero, radius: 0.1, u: [1, 0, 0], v: [0, 0, 1], from: 0, to: 1.5 * .pi)
        XCTAssertEqual(forward.count, 3)
        let backward = Spline(segments: Spline.arc(center: .zero, radius: 0.1, u: [1, 0, 0], v: [0, 0, 1],
                                                   from: .pi, to: 0))
        XCTAssertEqual(backward.length, .pi * 0.1, accuracy: 0.0002)
        XCTAssertEqual(simd_distance(backward.end, [0.1, 0, 0]), 0, accuracy: 1e-5)
    }

    /// Equal steps of distance must be equal steps along the curve, or a head flying a Catmull-Rom chain
    /// would speed up and slow down with its control points.
    func testEqualDistancesAreEqualChords() {
        let chain = Spline(segments: Spline.catmullRom([[0, 0, 0], [0.05, 0.02, 0], [0.06, 0.09, 0.03],
                                                        [0.2, 0.1, -0.02], [0.25, 0.25, 0]]))
        let steps = 60
        let step = chain.length / Float(steps)
        var chords: [Float] = []
        for k in 0..<steps {
            chords.append(simd_distance(chain.point(atDistance: Float(k) * step),
                                        chain.point(atDistance: Float(k + 1) * step)))
        }
        let lo = chords.min() ?? 0, hi = chords.max() ?? 0
        // Within 3 % one way (a chord is shorter than its arc on the bends) and 0.3 % the other (the table sums
        // 32 chords per segment, so it reads a hair short where the curvature changes fastest).
        XCTAssertGreaterThan(lo, 0.97 * step)
        XCTAssertLessThanOrEqual(hi, 1.003 * step)
    }

    func testTheSampledHelixHugsTheHelix() {
        let r: Float = 0.1, rise: Float = 0.18, sweep = 2 * Float.pi
        func f(_ a: Float) -> SIMD3<Float> { [r * cos(a), rise * a / sweep, r * sin(a)] }
        func df(_ a: Float) -> SIMD3<Float> { [-r * sin(a), rise / sweep, r * cos(a)] }
        let spline = Spline(segments: Spline.sampled(pieces: 8, over: 0...sweep, f, derivative: df))
        var worst: Float = 0
        for k in 0...400 {
            let p = spline.point(atDistance: spline.length * Float(k) / 400)
            let radial = simd_length(SIMD2<Float>(p.x, p.z))
            worst = max(worst, abs(radial - r))
        }
        XCTAssertLessThan(worst, 0.0002, "8 Hermite pieces per turn stay within 0.2 mm of a 10 cm helix")
    }

    func testCatmullRomPassesThroughItsPointsAndIsSmoothAtTheJoins() {
        let points: [SIMD3<Float>] = [[0, 0, 0], [0.1, 0.05, 0], [0.12, 0.2, 0.05], [0.3, 0.22, 0]]
        let segments = Spline.catmullRom(points)
        XCTAssertEqual(segments.count, 3)
        for (i, segment) in segments.enumerated() {
            XCTAssertEqual(simd_distance(segment.p0, points[i]), 0, accuracy: 1e-6)
            XCTAssertEqual(simd_distance(segment.p3, points[i + 1]), 0, accuracy: 1e-6)
        }
        for i in 0..<(segments.count - 1) {
            let out = simd_normalize(segments[i].derivative(1)), into = simd_normalize(segments[i + 1].derivative(0))
            XCTAssertGreaterThan(simd_dot(out, into), 0.9999, "join \(i) has a kink")
        }
        // Closed chains come back to the first point with a continuous tangent.
        let loop = Spline.catmullRom(points, closed: true)
        XCTAssertEqual(loop.count, 4)
        XCTAssertGreaterThan(simd_dot(simd_normalize(loop[3].derivative(1)), simd_normalize(loop[0].derivative(0))), 0.9999)
    }

    /// The ribbon asks for ≈ 200 decreasing distances a frame with a walking hint; it must agree with the
    /// bisection everywhere, including from a cold hint and across segment joins.
    func testTheWalkingLookupMatchesTheBisection() {
        let timeline = V4.RecognitionTimeline()
        let path = timeline.path
        var hint = -1
        var s = path.length
        while s > 0 {
            let walked = path.frame(atDistance: s, hint: &hint)
            XCTAssertEqual(simd_distance(walked.point, path.point(atDistance: s)), 0, accuracy: 1e-5, "at \(s)")
            XCTAssertEqual(simd_distance(walked.tangent, path.tangent(atDistance: s)), 0, accuracy: 1e-3, "at \(s)")
            s -= 0.0037
        }
        // A hint far off in the wrong direction still lands on the right place.
        var stale = 5
        let p = path.frame(atDistance: path.length * 0.8, hint: &stale).point
        XCTAssertEqual(simd_distance(p, path.point(atDistance: path.length * 0.8)), 0, accuracy: 1e-5)
    }

    func testAppendingJoinsLengths() {
        let a = Spline(segments: [Spline.line([0, 0, 0], [0.1, 0, 0])])
        let b = Spline(segments: [Spline.line([0.1, 0, 0], [0.1, 0.2, 0])])
        let joined = a.appending(b)
        XCTAssertEqual(joined.length, 0.3, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(joined.point(atDistance: 0.2), [0.1, 0.1, 0]), 0, accuracy: 1e-4)
    }
}
