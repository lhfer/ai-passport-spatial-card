import XCTest
import simd

/// **A3 目标 1.3.** The desk light pool under a glowing card: it dims and spreads as the card rises, it never
/// covers the device (H0), and its gradient lands where the pool is.
final class V4GroundingLightPoolTests: XCTestCase {
    private let pool = V4.LightPool()

    /// The disc-source falloff: contact is the peak, `halfHeight` is exactly half of it, and the lab's ±3 cm bob
    /// (lowest edge 4.9 → 10.9 cm) changes the centre by roughly a factor of two — visible, not a flicker.
    func testIntensityFallsLikeADiscSource() {
        XCTAssertEqual(pool.intensity(height: 0, brightness: 1), pool.peak, accuracy: 1e-6)
        XCTAssertEqual(pool.intensity(height: pool.halfHeight, brightness: 1), pool.peak / 2, accuracy: 1e-6)
        let low = pool.intensity(height: 0.049, brightness: 1)
        let high = pool.intensity(height: 0.109, brightness: 1)
        XCTAssertGreaterThan(low / high, 1.6)
        XCTAssertLessThan(low / high, 2.4)
        var previous = pool.intensity(height: 0, brightness: 1)
        for cm in stride(from: Float(1), through: 60, by: 1) {
            let value = pool.intensity(height: cm / 100, brightness: 1)
            XCTAssertLessThan(value, previous)
            previous = value
        }
    }

    /// Brightness scales linearly; a dark card throws no light; a card "in the desk" (negative height, a tracking
    /// glitch) is treated as touching it rather than blowing up.
    func testBrightnessAndDegenerateHeights() {
        XCTAssertEqual(pool.intensity(height: 0.05, brightness: 0), 0)
        XCTAssertEqual(pool.intensity(height: 0.05, brightness: 0.5), pool.intensity(height: 0.05, brightness: 1) / 2,
                       accuracy: 1e-6)
        XCTAssertEqual(pool.intensity(height: -0.2, brightness: 1), pool.peak, accuracy: 1e-6)
        XCTAssertEqual(pool.intensity(height: 0.05, brightness: -1), 0)
        XCTAssertEqual(pool.halfExtent(height: -1), pool.contactHalfExtent)
    }

    /// The footprint widens with height on both axes and is capped at what the mesh covers.
    func testExtentSpreadsAndIsCapped() {
        var previous = pool.halfExtent(height: 0)
        for cm in stride(from: Float(1), through: 20, by: 1) {
            let extent = pool.halfExtent(height: cm / 100)
            XCTAssertGreaterThan(extent.x, previous.x)
            XCTAssertGreaterThan(extent.y, previous.y)
            previous = extent
        }
        XCTAssertEqual(pool.halfExtent(height: 5), pool.maxHalfExtent)
    }

    /// The gradient's centre sits on the pool's centre and its 0 / 1 edges on ±halfExtent; the far side of the
    /// desk (−z) is the texture's top (v → 1).
    func testGradientUVSpansThePool() {
        let half = SIMD2<Float>(0.2, 0.1)
        XCTAssertEqual(V4.LightPool.gradientUV(at: .zero, halfExtent: half), [0.5, 0.5])
        let right = V4.LightPool.gradientUV(at: [0.2, 0], halfExtent: half)
        XCTAssertEqual(right.x, 1, accuracy: 1e-6)
        let far = V4.LightPool.gradientUV(at: [0, -0.1], halfExtent: half)
        XCTAssertEqual(far.y, 1, accuracy: 1e-6)
        let outside = V4.LightPool.gradientUV(at: [0.4, 0.3], halfExtent: half)
        XCTAssertGreaterThan(outside.x, 1)
        XCTAssertLessThan(outside.y, 0)
    }

    /// H0: not one triangle of the pool lies over the device footprint, the band closes on itself, and every
    /// triangle faces up.
    func testRingKeepsTheDeviceClear() {
        let hole = SIMD2<Float>(0.030 + 0.002, 0.0475 + 0.002)
        let ring = V4.LightPoolRing.make(holeHalf: hole, holeRadius: 0.006, outerHalf: pool.maxHalfExtent, segments: 96)
        XCTAssertEqual(ring.count, 96)
        // The hole's outline lies on the rounded rectangle itself…
        for p in ring.positions[..<ring.count] {
            XCTAssertEqual(V4.LightPoolRing.signedDistance(p, half: hole, radius: 0.006), 0, accuracy: 1e-5)
        }
        // …and the outer outline is a smooth ellipse: no chord spans more than one 3.75° step (the first build's
        // corner-only sampling gave 107° chords and a rectangular pool).
        for i in 0..<ring.count {
            let a = ring.positions[ring.count + i], b = ring.positions[ring.count + (i + 1) % ring.count]
            let step = acos(max(-1, min(1, simd_dot(simd_normalize(a), simd_normalize(b)))))
            XCTAssertLessThan(step, 2 * Float.pi / 96 * 1.6)
        }
        XCTAssertEqual(ring.indices.count, ring.count * 6)
        XCTAssertEqual(ring.positions.count, ring.count * 2)
        for p in ring.positions {
            XCTAssertFalse(V4.LightPoolRing.isInsideHole(p, half: hole, radius: 0.006), "vertex \(p) inside the hole")
        }
        for t in stride(from: 0, to: ring.indices.count, by: 3) {
            let a = ring.positions[Int(ring.indices[t])]
            let b = ring.positions[Int(ring.indices[t + 1])]
            let c = ring.positions[Int(ring.indices[t + 2])]
            let centroid = (a + b + c) / 3
            XCTAssertFalse(V4.LightPoolRing.isInsideHole(centroid, half: hole, radius: 0.006))
            // Lifted to (x, 0, z): the geometric normal must point up (+Y).
            let u = SIMD3<Float>(b.x - a.x, 0, b.y - a.y)
            let v = SIMD3<Float>(c.x - a.x, 0, c.y - a.y)
            XCTAssertGreaterThan(simd_cross(u, v).y, 0)
        }
        // Outer points sit on the ellipse.
        for p in ring.positions[ring.count...] {
            let e = (p.x / pool.maxHalfExtent.x) * (p.x / pool.maxHalfExtent.x)
                + (p.y / pool.maxHalfExtent.y) * (p.y / pool.maxHalfExtent.y)
            XCTAssertEqual(e, 1, accuracy: 1e-3)
        }
    }

    /// Re-fitted to a pool, the ring's outer edge sits exactly where the gradient reaches zero (the texture's
    /// inscribed circle) and every UV stays inside the texture — nothing depends on clamp-to-edge sampling.
    func testFittedRingStaysInsideTheTexture() {
        let hole = SIMD2<Float>(0.032, 0.0495)
        let ring = V4.LightPoolRing.make(holeHalf: hole, holeRadius: 0.006, outerHalf: pool.maxHalfExtent)
        for height: Float in [0, 0.06, 0.09, 0.12, 0.5] {
            let extent = pool.halfExtent(height: height)
            let vertices = ring.fitted(to: extent)
            XCTAssertEqual(vertices.count, ring.positions.count)
            for (i, vertex) in vertices.enumerated() {
                XCTAssertGreaterThanOrEqual(vertex.uv.x, -1e-5)
                XCTAssertLessThanOrEqual(vertex.uv.x, 1 + 1e-5)
                XCTAssertGreaterThanOrEqual(vertex.uv.y, -1e-5)
                XCTAssertLessThanOrEqual(vertex.uv.y, 1 + 1e-5)
                XCTAssertFalse(V4.LightPoolRing.isInsideHole(vertex.position, half: hole, radius: 0.006))
                if i < ring.count {
                    XCTAssertEqual(vertex.position, ring.positions[i], "the hole's outline never moves")
                } else {
                    XCTAssertEqual(simd_length((vertex.uv - 0.5) * 2), 1, accuracy: 1e-3, "outer edge on the zero circle")
                }
            }
        }
    }

    /// The perf meter's arithmetic: mean, nearest-rank p95, max, and the ring overwriting its oldest samples.
    func testTickStats() {
        var stats = V4.GroundingTickStats(capacity: 4)
        XCTAssertEqual(stats.mean, 0)
        for value in [1.0, 2.0, 3.0, 4.0] { stats.add(value) }
        XCTAssertEqual(stats.mean, 2.5, accuracy: 1e-9)
        XCTAssertEqual(stats.percentile(95), 4)
        XCTAssertEqual(stats.percentile(50), 2)
        stats.add(10)
        XCTAssertEqual(stats.count, 4)
        XCTAssertEqual(stats.max, 10)
        XCTAssertEqual(stats.mean, (2 + 3 + 4 + 10) / 4, accuracy: 1e-9)
    }
}
