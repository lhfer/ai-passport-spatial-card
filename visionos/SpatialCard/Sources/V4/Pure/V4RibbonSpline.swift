import Foundation
import simd

extension V4 {
    /// **A path a ribbon can fly** (v4 A2): a chain of cubic Bézier segments with an arc-length table, so it
    /// is sampled *by distance*. A ribbon head has to move at the speed its timing asks for, not at whatever
    /// speed the control points happen to be spaced at — and the ribbon's body has to be sampled evenly along
    /// the curve (≈ 4 mm apart), or a fast stretch turns into visible straight facets.
    ///
    /// Why cubic Bézier and not one specific spline: every shape the choreographies need converts into it
    /// exactly or to far below a millimetre — a line, a circular arc (≤ 90° per piece), a Hermite piece of an
    /// analytic curve (the recognition spiral), a centripetal Catmull-Rom chain through key points — so one
    /// representation composes all of them, and joining two paths is appending segments.
    ///
    /// Units are whatever the caller's space is (metres in S for the recognition). Pure simd + Foundation.
    struct RibbonSpline {
        struct Segment: Equatable {
            var p0: SIMD3<Float>
            var p1: SIMD3<Float>
            var p2: SIMD3<Float>
            var p3: SIMD3<Float>

            func point(_ t: Float) -> SIMD3<Float> {
                let u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                return a * p0 + b * p1 + c * p2 + d * p3
            }

            /// d/dt of `point`.
            func derivative(_ t: Float) -> SIMD3<Float> {
                let u = 1 - t
                return 3 * u * u * (p1 - p0) + 6 * u * t * (p2 - p1) + 3 * t * t * (p3 - p2)
            }

            /// Point and derivative in one pass (the ribbon asks for both at every sample, every frame).
            func pointAndDerivative(_ t: Float) -> (SIMD3<Float>, SIMD3<Float>) {
                let u = 1 - t
                let q0 = u * p0 + t * p1, q1 = u * p1 + t * p2, q2 = u * p2 + t * p3
                let r0 = u * q0 + t * q1, r1 = u * q1 + t * q2
                return (u * r0 + t * r1, 3 * (r1 - r0))
            }
        }

        /// Table entries per segment. 32 chords keep the distance → parameter error of a 90° arc piece under
        /// 0.1 % of its length, i.e. well under a millimetre on everything the choreographies draw.
        static let stepsPerSegment = 32

        let segments: [Segment]
        /// Cumulative chord length at every table entry: entry k is segment k / steps at parameter
        /// (k mod steps) / steps; the last entry is the whole length.
        private let table: [Float]
        /// Per segment, the longest step a ribbon may take along it and still look round: the chord whose
        /// sagitta on the segment's tightest bend is 0.1 mm (a 30 mm corner → 4.9 mm, the recognition's spiral
        /// → ≈ 8 mm), capped at `maxStepCap` on the straights.
        private let segmentSteps: [Float]
        static let maxStepCap: Float = 0.015
        static let minStep: Float = 0.002
        static let sagitta: Float = 0.0001

        var length: Float { table.last ?? 0 }
        var isEmpty: Bool { segments.isEmpty }
        var start: SIMD3<Float> { segments.first?.p0 ?? .zero }
        var end: SIMD3<Float> { segments.last?.p3 ?? .zero }

        init(segments: [Segment]) {
            self.segments = segments
            let steps = Self.stepsPerSegment
            var table: [Float] = [0]
            table.reserveCapacity(segments.count * steps + 1)
            var total: Float = 0
            var segmentSteps: [Float] = []
            segmentSteps.reserveCapacity(segments.count)
            for segment in segments {
                var previous = segment.p0
                var previousDirection: SIMD3<Float>?
                var tightest: Float = .greatestFiniteMagnitude       // smallest radius of curvature seen
                for k in 1...steps {
                    let p = segment.point(Float(k) / Float(steps))
                    let chord = p - previous
                    let length = simd_length(chord)
                    total += length
                    if length > 1e-7 {
                        let direction = chord / length
                        if let previousDirection {
                            let turn = acos(max(-1, min(1, simd_dot(direction, previousDirection))))
                            if turn > 1e-5 { tightest = min(tightest, length / turn) }
                        }
                        previousDirection = direction
                    }
                    previous = p
                    table.append(total)
                }
                // sagitta = R (1 − cos(θ/2)) ≈ step² / 8R  →  step = √(8 R · sagitta)
                let step = tightest == .greatestFiniteMagnitude ? Self.maxStepCap : sqrt(8 * tightest * Self.sagitta)
                segmentSteps.append(max(Self.minStep, min(Self.maxStepCap, step)))
            }
            self.table = table
            self.segmentSteps = segmentSteps
        }

        /// The longest step a ribbon sample may take at distance `s` (see `segmentSteps`), walking `hint`.
        func maxStep(atDistance s: Float, hint: inout Int) -> Float {
            guard !segments.isEmpty else { return Self.maxStepCap }
            let (index, _) = location(atDistance: s, hint: &hint)
            return segmentSteps[index]
        }

        /// Segment index and local parameter at distance `s` along the path (clamped to the path).
        func location(atDistance s: Float) -> (segment: Int, t: Float) {
            guard !segments.isEmpty else { return (0, 0) }
            let steps = Self.stepsPerSegment
            let clamped = max(0, min(length, s))
            // Largest k with table[k] <= s.
            var lo = 0, hi = table.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if table[mid] <= clamped { lo = mid } else { hi = mid }
            }
            let span = table[hi] - table[lo]
            let fraction = span > 1e-9 ? (clamped - table[lo]) / span : 0
            let entry = Float(lo) + fraction
            let segment = min(segments.count - 1, Int(entry) / steps)
            let t = (entry - Float(segment * steps)) / Float(steps)
            return (segment, max(0, min(1, t)))
        }

        /// Segment index and local parameter at distance `s`, walking from `hint` (a table index) instead of
        /// bisecting: a ribbon asks for distances that move monotonically from one sample to the next, so the
        /// walk is a step or two. `hint` is updated for the next call.
        func location(atDistance s: Float, hint: inout Int) -> (segment: Int, t: Float) {
            guard !segments.isEmpty else { return (0, 0) }
            let steps = Self.stepsPerSegment
            let clamped = max(0, min(length, s))
            var lo: Int
            if hint < 0 || hint > table.count - 2 {
                // No usable hint (the first call): bisect for the largest k with table[k] <= s.
                lo = 0
                var hi = table.count - 1
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if table[mid] <= clamped { lo = mid } else { hi = mid }
                }
                lo = min(lo, table.count - 2)
            } else {
                lo = hint
            }
            while lo > 0, table[lo] > clamped { lo -= 1 }
            while lo < table.count - 2, table[lo + 1] <= clamped { lo += 1 }
            hint = lo
            let hi = lo + 1
            let span = table[hi] - table[lo]
            let fraction = span > 1e-9 ? (clamped - table[lo]) / span : 0
            let entry = Float(lo) + fraction
            let segment = min(segments.count - 1, Int(entry) / steps)
            let t = (entry - Float(segment * steps)) / Float(steps)
            return (segment, max(0, min(1, t)))
        }

        /// Point and unit tangent at distance `s`, with a walking `hint` (see `location(atDistance:hint:)`).
        func frame(atDistance s: Float, hint: inout Int) -> (point: SIMD3<Float>, tangent: SIMD3<Float>) {
            guard !segments.isEmpty else { return (.zero, [0, 1, 0]) }
            let (index, t) = location(atDistance: s, hint: &hint)
            let (p, d) = segments[index].pointAndDerivative(t)
            let len = simd_length(d)
            if len > 1e-6 { return (p, d / len) }
            return (p, tangent(atDistance: s))
        }

        func point(atDistance s: Float) -> SIMD3<Float> {
            guard !segments.isEmpty else { return .zero }
            let (index, t) = location(atDistance: s)
            return segments[index].point(t)
        }

        /// Unit tangent at distance `s` (the direction of travel). Falls back to a short chord where the
        /// Bézier derivative vanishes (coincident control points), and to +Y on a degenerate path.
        func tangent(atDistance s: Float) -> SIMD3<Float> {
            guard !segments.isEmpty else { return [0, 1, 0] }
            let (index, t) = location(atDistance: s)
            let d = segments[index].derivative(t)
            let len = simd_length(d)
            if len > 1e-6 { return d / len }
            let a = point(atDistance: s - 0.0005), b = point(atDistance: s + 0.0005)
            let chord = b - a
            let chordLength = simd_length(chord)
            return chordLength > 1e-7 ? chord / chordLength : [0, 1, 0]
        }

        /// The path followed by `other` (whose first point should be this one's last point).
        func appending(_ other: RibbonSpline) -> RibbonSpline {
            RibbonSpline(segments: segments + other.segments)
        }

        // MARK: - Builders

        /// A straight piece.
        static func line(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Segment {
            let d = b - a
            return Segment(p0: a, p1: a + d / 3, p2: a + 2 * d / 3, p3: b)
        }

        /// A cubic Hermite piece: from `a` leaving with derivative `da` to `b` arriving with derivative `db`
        /// (derivatives with respect to the piece's own 0…1 parameter — roughly "direction × length").
        static func hermite(_ a: SIMD3<Float>, _ da: SIMD3<Float>, _ b: SIMD3<Float>, _ db: SIMD3<Float>) -> Segment {
            Segment(p0: a, p1: a + da / 3, p2: b - db / 3, p3: b)
        }

        /// A circular arc of `radius` around `center` in the plane spanned by the unit vectors `u` and `v`,
        /// from angle `from` to angle `to` (radians, measured from `u` toward `v`; either direction). Split into
        /// pieces of ≤ 90°, each with the standard 4/3·tan(Δ/4) handles (radial error < 0.03 % of the radius).
        static func arc(center: SIMD3<Float>, radius: Float, u: SIMD3<Float>, v: SIMD3<Float>,
                        from: Float, to: Float) -> [Segment] {
            let sweep = to - from
            let pieces = max(1, Int(ceil(abs(sweep) / (Float.pi / 2) - 1e-4)))
            let delta = sweep / Float(pieces)
            let k = 4 / 3 * tan(delta / 4) * radius
            var result: [Segment] = []
            for i in 0..<pieces {
                let a0 = from + Float(i) * delta, a1 = a0 + delta
                let p0 = center + radius * (cos(a0) * u + sin(a0) * v)
                let p3 = center + radius * (cos(a1) * u + sin(a1) * v)
                let d0 = -sin(a0) * u + cos(a0) * v
                let d1 = -sin(a1) * u + cos(a1) * v
                result.append(Segment(p0: p0, p1: p0 + k * d0, p2: p3 - k * d1, p3: p3))
            }
            return result
        }

        /// An analytic curve `f` over `range`, cut into `pieces` Hermite pieces that match `f` and its
        /// derivative `df` at every cut — so the chain is C¹ and hugs `f` (a helix quarter-turn is within
        /// ≈ 0.1 mm with 8 pieces per turn).
        static func sampled(pieces: Int, over range: ClosedRange<Float>,
                            _ f: (Float) -> SIMD3<Float>, derivative df: (Float) -> SIMD3<Float>) -> [Segment] {
            let n = max(1, pieces)
            let span = (range.upperBound - range.lowerBound) / Float(n)
            return (0..<n).map { i in
                let x0 = range.lowerBound + Float(i) * span, x1 = x0 + span
                return hermite(f(x0), df(x0) * span, f(x1), df(x1) * span)
            }
        }

        /// A centripetal Catmull-Rom chain through `points` (α = 0.5: no cusps or self-loops between close
        /// key points, unlike the uniform variant). Open chains get mirrored end points; `closed` joins the
        /// last point back to the first with a continuous tangent.
        static func catmullRom(_ points: [SIMD3<Float>], closed: Bool = false, alpha: Float = 0.5) -> [Segment] {
            let count = points.count
            guard count >= 2 else { return [] }
            func point(_ i: Int) -> SIMD3<Float> {
                if closed { return points[((i % count) + count) % count] }
                if i < 0 { return 2 * points[0] - points[1] }
                if i >= count { return 2 * points[count - 1] - points[count - 2] }
                return points[i]
            }
            func knot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
                max(1e-5, pow(simd_length(b - a), alpha))
            }
            let segmentCount = closed ? count : count - 1
            return (0..<segmentCount).map { i in
                let p0 = point(i - 1), p1 = point(i), p2 = point(i + 1), p3 = point(i + 2)
                let t01 = knot(p0, p1), t12 = knot(p1, p2), t23 = knot(p2, p3)
                // Barry–Goldman tangents of the centripetal parametrisation, rescaled to the segment's span.
                let m1 = ((p1 - p0) / t01 - (p2 - p0) / (t01 + t12) + (p2 - p1) / t12) * t12
                let m2 = ((p2 - p1) / t12 - (p3 - p1) / (t12 + t23) + (p3 - p2) / t23) * t12
                return hermite(p1, m1, p2, m2)
            }
        }
    }
}
