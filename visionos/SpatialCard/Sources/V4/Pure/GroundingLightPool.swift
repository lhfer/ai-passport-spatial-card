import Foundation
import simd

extension V4 {
    /// How the warm pool of light on the desk answers a glowing card's height and brightness (A3 目标 1.3).
    ///
    /// The card is an area light whose lowest edge floats `height` above the desk. At the pool's centre its
    /// irradiance falls like a disc source's, E(h) = h½² / (h½² + h²): nearly flat while the card almost touches the
    /// desk, 1/h² once it is far away — `halfHeight` is the height at which the centre has dimmed to half its
    /// contact value. The lit footprint widens linearly with height because the rays fan out. Brightness (the
    /// card's own glow: 0 while it is dark, 1 at rest, a little more during a flash) scales the intensity linearly.
    ///
    /// Pure (simd + Foundation), so "a card that lifts dims and spreads its pool" is checked by a unit test instead of
    /// being a judgement made on the headset.
    struct LightPool: Equatable, Sendable {
        /// Height of the card's lowest edge at which the pool's centre is half as bright as at contact (metres).
        var halfHeight: Float = 0.09
        /// Pool half-extent when the card touches the desk: x across the card, y along S +Z (towards the reader).
        /// Sized for the 0.20 m portrait hero card.
        var contactHalfExtent: SIMD2<Float> = [0.12, 0.08]
        /// Growth of the half-extent per metre of height.
        var spread: SIMD2<Float> = [0.9, 0.7]
        /// Intensity (the additive material's opacity) at contact for brightness 1.
        var peak: Float = 0.85
        /// Largest half-extent the pool may reach (the mesh's bounds).
        var maxHalfExtent: SIMD2<Float> = [0.30, 0.22]

        /// Additive intensity for a card whose lowest edge is `height` above the desk.
        func intensity(height: Float, brightness: Float) -> Float {
            let h = max(0, height)
            let h2 = halfHeight * halfHeight
            return peak * max(0, brightness) * h2 / (h2 + h * h)
        }

        /// Half-extent of the lit footprint (x, S z) for a card whose lowest edge is `height` above the desk.
        func halfExtent(height: Float) -> SIMD2<Float> {
            simd_min(contactHalfExtent + spread * max(0, height), maxHalfExtent)
        }

        /// Where a desk point `p` (x, S z, relative to the pool's centre) samples the radial gradient texture when the
        /// pool spans `halfExtent`: the texture's 0…1 runs across ±halfExtent, v grows towards −z (the texture's top
        /// is the far side of the desk).
        static func gradientUV(at p: SIMD2<Float>, halfExtent: SIMD2<Float>) -> SIMD2<Float> {
            let h = simd_max(halfExtent, SIMD2<Float>(repeating: 1e-4))
            return [0.5 + p.x / (2 * h.x), 0.5 - p.y / (2 * h.y)]
        }
    }

    /// The pool's mesh as plain numbers: a flat ring between the device's footprint (a rounded rectangle that stays
    /// clear — the art bible's H0 rule, *no persistent virtual geometry over the device*) and the pool's own ellipse.
    /// Positions are (x, S z) in the device's screen frame; the ring never has a vertex, and so never a triangle,
    /// inside the hole.
    ///
    /// The gradient's UVs are an affine function of position, so a single band of triangles from the hole to the
    /// ellipse interpolates them exactly — no inner rings are needed however far apart the two outlines are. The outer
    /// outline is re-fitted to the pool every time it changes size (`fitted(to:)`): it then lies exactly where the
    /// gradient reaches zero, so every UV stays inside the texture — the first build relied on clamp-to-edge sampling
    /// instead, the sampler setting did not reach `UnlitMaterial`, and the gradient tiled out to the mesh's edge.
    struct LightPoolRing: Equatable, Sendable {
        /// Inner outline first (`count` points, counter-clockwise), then the outer ellipse (`count` points).
        var positions: [SIMD2<Float>]
        /// Triangles, counter-clockwise seen from +Y (the desk's up), two per segment.
        var indices: [UInt32]
        /// Unit directions of the rays both outlines are sampled on (one per outline point), kept so re-fitting the
        /// outer outline per frame costs one square root a vertex and no trigonometry.
        var directions: [SIMD2<Float>]
        /// Points per outline.
        var count: Int { positions.count / 2 }

        /// - Parameters:
        ///   - holeHalf: half-extent of the clear rectangle (the device footprint plus its margin).
        ///   - holeRadius: its corner radius.
        ///   - outerHalf: semi-axes of the outer ellipse.
        ///   - segments: points per outline, at uniform angles around the centre.
        ///
        /// Both outlines are sampled along the **same rays** from the centre: the hole by ray-casting its rounded
        /// rectangle, the pool on its ellipse. (The first version took the rounded rectangle's own vertices — all on
        /// its corner arcs — so each straight side became one ray pair, and the outer ellipse degenerated into four
        /// long chords: a lit *rectangle* with hard sides instead of a round pool.)
        static func make(holeHalf: SIMD2<Float>, holeRadius: Float, outerHalf: SIMD2<Float>,
                         segments: Int = 96) -> LightPoolRing {
            let n = max(8, segments)
            var positions: [SIMD2<Float>] = []
            positions.reserveCapacity(2 * n)
            let angles = (0..<n).map { Float($0) / Float(n) * 2 * .pi }
            let directions = angles.map { SIMD2<Float>(cos($0), sin($0)) }
            for angle in angles { positions.append(holePoint(half: holeHalf, radius: holeRadius, angle: angle)) }
            for angle in angles { positions.append(ellipsePoint(half: outerHalf, angle: angle)) }
            var indices: [UInt32] = []
            indices.reserveCapacity(n * 6)
            for i in 0..<n {
                let a = UInt32(i), b = UInt32((i + 1) % n)
                let oa = UInt32(n) + a, ob = UInt32(n) + b
                // Counter-clockwise in (x, z) seen from above means clockwise in (x, y) of a plane lying in x–z:
                // the winding is chosen so the face normal is +Y after (x, z) → (x, 0, z).
                indices += [a, ob, oa, a, b, ob]
            }
            return LightPoolRing(positions: positions, indices: indices, directions: directions)
        }

        /// Where the ray from the centre at `angle` leaves the rounded rectangle (bisection on its signed distance —
        /// the shape is convex and contains the centre, so the distance grows monotonically along the ray).
        static func holePoint(half: SIMD2<Float>, radius: Float, angle: Float) -> SIMD2<Float> {
            let direction = SIMD2<Float>(cos(angle), sin(angle))
            var lo: Float = 0, hi = simd_length(half) + 1e-3
            for _ in 0..<40 {
                let mid = (lo + hi) / 2
                if signedDistance(direction * mid, half: half, radius: radius) < 0 { lo = mid } else { hi = mid }
            }
            return direction * hi
        }

        /// Signed distance to a rounded rectangle centred on the origin (negative inside).
        static func signedDistance(_ p: SIMD2<Float>, half: SIMD2<Float>, radius: Float) -> Float {
            let r = max(0, min(radius, min(half.x, half.y)))
            let q = simd_abs(p) - (half - SIMD2<Float>(repeating: r))
            return simd_length(simd_max(q, .zero)) + min(max(q.x, q.y), 0) - r
        }

        /// The ring fitted to a pool of `halfExtent`: the hole's outline unchanged, the outer outline moved onto the
        /// pool's ellipse (same directions from the centre). Pairs each position with its gradient UV.
        func fitted(to halfExtent: SIMD2<Float>) -> [(position: SIMD2<Float>, uv: SIMD2<Float>)] {
            var out: [(position: SIMD2<Float>, uv: SIMD2<Float>)] = []
            out.reserveCapacity(positions.count)
            forEachFitted(to: halfExtent) { _, position, uv in out.append((position, uv)) }
            return out
        }

        /// The same, without allocating: `body(index, position, uv)` for every vertex, in buffer order. This is what
        /// runs per frame (`DeskLightPool`); the outer directions are unit vectors, so each outer vertex costs one
        /// square root.
        func forEachFitted(to halfExtent: SIMD2<Float>, _ body: (Int, SIMD2<Float>, SIMD2<Float>) -> Void) {
            let n = count
            let h = simd_max(halfExtent, SIMD2<Float>(repeating: 1e-4))
            let inverse = 1 / (2 * h)
            for i in 0..<n {
                let p = positions[i]
                body(i, p, [0.5 + p.x * inverse.x, 0.5 - p.y * inverse.y])
            }
            for i in 0..<n {
                let d = directions[i]
                let r = h.x * h.y / max(1e-6, ((h.y * d.x) * (h.y * d.x) + (h.x * d.y) * (h.x * d.y)).squareRoot())
                let p = d * r
                body(n + i, p, [0.5 + p.x * inverse.x, 0.5 - p.y * inverse.y])
            }
        }


        /// The point of the ellipse with semi-axes `half` in direction `angle` from its centre.
        static func ellipsePoint(half: SIMD2<Float>, angle: Float) -> SIMD2<Float> {
            let c = cos(angle), s = sin(angle)
            let r = half.x * half.y / max(1e-6, sqrt((half.y * c) * (half.y * c) + (half.x * s) * (half.x * s)))
            return [r * c, r * s]
        }

        /// Whether a point lies strictly inside the rounded hole (used by the tests; the ring must never cover it).
        static func isInsideHole(_ p: SIMD2<Float>, half: SIMD2<Float>, radius: Float) -> Bool {
            signedDistance(p, half: half, radius: radius) < -1e-5
        }
    }

    /// Rolling cost of one per-frame callback, for the brief's "每帧自有 CPU ≤ 0.5 ms" line in the report.
    ///
    /// Keeps the last `capacity` samples (milliseconds) in a ring and answers mean / p95 / max over them.
    struct GroundingTickStats: Equatable, Sendable {
        private(set) var samples: [Double] = []
        private var next = 0
        let capacity: Int

        init(capacity: Int = 600) { self.capacity = Swift.max(1, capacity) }

        mutating func add(_ milliseconds: Double) {
            if samples.count < capacity {
                samples.append(milliseconds)
            } else {
                samples[next] = milliseconds
            }
            next = (next + 1) % capacity
        }

        var count: Int { samples.count }
        var mean: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }
        var max: Double { samples.max() ?? 0 }

        /// Nearest-rank percentile (0…100).
        func percentile(_ p: Double) -> Double {
            guard !samples.isEmpty else { return 0 }
            let sorted = samples.sorted()
            let rank = Int((p / 100 * Double(sorted.count)).rounded(.up)) - 1
            return sorted[Swift.max(0, Swift.min(sorted.count - 1, rank))]
        }
    }
}
