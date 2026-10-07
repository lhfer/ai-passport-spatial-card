import Foundation
import simd

extension V4 {
    /// One point of a ribbon's centre line, head first. `age` is how long ago the head was here (the ribbon
    /// fades by age), `distance` how far along its path (or, when following a target, its odometer) this
    /// point is — a coordinate that stays glued to the world, for materials that want one.
    struct RibbonSample: Equatable {
        var position: SIMD3<Float>
        var age: Float
        var distance: Float
        /// Unit direction of travel, or zero to have the strip builder derive it from the neighbours.
        var tangent: SIMD3<Float> = .zero
    }

    /// **The ribbon's shape along its length** (v4 A2, art bible §4 丝带光轨): how wide and how bright every
    /// point is, as a function of its age.
    ///
    /// Two kinds, both built by the same strip:
    /// - `fairy` — the light trail itself. 6–12 mm at the head, tapering to nothing at the end of its tail;
    ///   white-hot at the head and fading to transparent over `tail` seconds (0.4–0.8 s by the bible).
    /// - `stroke` — a line the head *draws* and leaves behind (the card outline): constant width, hot where it
    ///   was just drawn, settling to a steady glow after `fresh` seconds, and staying until it is told to fade.
    ///
    /// Brightness is an `intensity` 0…1 rather than a colour because RealityKit's `UnlitMaterial` ignores
    /// per-vertex colour (A2 SDK probe 1): intensity rides in the texture's U coordinate, and the ramp texture
    /// turns it into white-gold → gold → holo tint → transparent.
    struct RibbonProfile: Equatable {
        enum Kind: Equatable {
            case fairy
            case stroke
        }

        var kind: Kind
        /// Fairy: full width at the head (m). Stroke: the settled width of the line.
        var width: Float
        /// Fairy: seconds from the head to the end of the tail.
        var tail: Float
        /// Stroke: seconds a freshly drawn stretch stays hot and slightly wider.
        var fresh: Float = 0.22
        /// Stroke: the intensity a drawn line settles at.
        var steady: Float = 0.55
        /// Travelling shimmer along the ribbon: relative amplitude, wavelength (m) and speed (m/s). Small on
        /// purpose — it is what makes a streak of light read as *alive* rather than as a tube.
        var shimmer: Float = 0.10
        var shimmerWavelength: Float = 0.085
        var shimmerSpeed: Float = 0.30

        /// The recognition's trail: 11 mm at the head (the bible's 6–12 mm), a 0.55 s tail (its 0.4–0.8 s).
        static let fairy = RibbonProfile(kind: .fairy, width: 0.011, tail: 0.55)
        /// The outline it draws: a 3 mm line.
        static let stroke = RibbonProfile(kind: .stroke, width: 0.0030, tail: .infinity, steady: 0.62, shimmer: 0.05)

        /// Where along the tail a point of this age is: 0 at the head, 1 at the end of the tail (fairy only).
        func tailFraction(age: Float) -> Float {
            guard kind == .fairy, tail > 0 else { return 0 }
            return max(0, min(1, age / tail))
        }

        /// Full width at `age`.
        func width(age: Float) -> Float {
            let age = max(0, age)
            switch kind {
            case .fairy:
                let a = tailFraction(age: age)
                // A rounded nose (the head glow sits over it) and a long taper to a point.
                let nose: Float = 0.45 + 0.55 * V4.smoothstep(0, 0.035, a)
                return width * nose * pow(1 - a, 0.7)
            case .stroke:
                return width * (1 + 0.6 * exp(-age / max(0.01, fresh)))
            }
        }

        /// Brightness 0…1 at `age`, before the shimmer.
        func intensity(age: Float) -> Float {
            let age = max(0, age)
            switch kind {
            case .fairy:
                let a = tailFraction(age: age)
                // A hot knot right behind the head, then a long, soft fade to exactly zero — steeper in the last
                // third, where a dim warm light would read as a brown line rather than as light going out.
                return 0.8 * pow(1 - a, 1.8) + 0.2 * exp(-a / 0.05) * (1 - a)
            case .stroke:
                return steady + (1 - steady) * exp(-age / max(0.01, fresh))
            }
        }

        /// The shimmer factor at a point `distance` along the path at `time`.
        func shimmer(distance: Float, time: Float) -> Float {
            guard shimmer > 0, shimmerWavelength > 0 else { return 1 }
            let phase = (distance - time * shimmerSpeed) / shimmerWavelength
            return 1 + shimmer * sin(2 * .pi * phase)
        }
    }

    // MARK: - Sampling a ribbon's centre line

    enum RibbonBody {
        /// How much coarser the fairy's sampling gets toward the end of its tail (× 1 at the head, × 2.5 at the
        /// end): the tail is thin and dim, and the spline's own per-segment cap still keeps every bend round.
        static let tailCoarsening: Float = 1.5

        /// The **fairy** ribbon at `time`: the stretch of `spline` the head covered in the last `tail` seconds,
        /// head first. Sampled every `spacing` metres at the head, coarser toward the tail, never coarser than
        /// the spline allows on its bends. Empty before the head has moved.
        static func trail(spline: RibbonSpline, timing: RibbonTiming, time: Float, tail: Float,
                          spacing: Float, maxSamples: Int, into samples: inout [RibbonSample]) {
            let head = timing.distance(at: time)
            let tailEnd = timing.distance(at: time - tail)
            sample(spline: spline, timing: timing, time: time, from: head, to: tailEnd,
                   spacing: spacing, coarsenOver: tail, maxSamples: maxSamples, into: &samples)
        }

        /// The **stroke** at `time`: everything drawn so far between `start` and `end` (distances along the
        /// spline), head first. Once the head has passed `end` the whole range stays. Straights sample every
        /// `spacing` metres, bends as finely as the spline asks.
        static func stroke(spline: RibbonSpline, timing: RibbonTiming, time: Float, start: Float, end: Float,
                           spacing: Float, maxSamples: Int, into samples: inout [RibbonSample]) {
            let head = min(end, timing.distance(at: time))
            sample(spline: spline, timing: timing, time: time, from: head, to: start,
                   spacing: spacing, coarsenOver: nil, maxSamples: maxSamples, into: &samples)
        }

        /// Samples from distance `from` (the head end) back to `to`. The step at each sample is the smaller of
        /// the requested spacing (grown toward the tail when `coarsenOver` is set, and for strokes allowed up to
        /// the spline's cap on straights) and the spline's round-enough step here *and* where the step would
        /// land — so a step never jumps from a straight into the middle of a corner. The last sample is always
        /// exactly at `to`; should `maxSamples` run out first, the remainder is one final segment.
        private static func sample(spline: RibbonSpline, timing: RibbonTiming, time: Float, from: Float, to: Float,
                                   spacing: Float, coarsenOver tail: Float?, maxSamples: Int,
                                   into samples: inout [RibbonSample]) {
            samples.removeAll(keepingCapacity: true)
            guard from - to > 1e-5, maxSamples >= 2 else { return }
            // Distances only decrease along the samples, so every lookup walks instead of bisecting.
            var splineHint = -1, timingHint = -1, stepHint = -1, aheadHint = -1
            var s = from
            while true {
                let passed = timing.time(atDistance: s, hint: &timingHint)
                let age = max(0, time - passed)
                let frame = spline.frame(atDistance: s, hint: &splineHint)
                samples.append(RibbonSample(position: frame.point, age: age, distance: s, tangent: frame.tangent))
                if s <= to + 1e-6 { break }
                if samples.count >= maxSamples - 1 {
                    s = to
                    continue
                }
                let wanted: Float
                if let tail {
                    wanted = spacing * (1 + tailCoarsening * min(1, age / max(1e-3, tail)))
                } else {
                    wanted = spacing
                }
                var step = min(wanted, spline.maxStep(atDistance: s, hint: &stepHint))
                step = min(step, spline.maxStep(atDistance: s - step, hint: &aheadHint))
                s = max(to, s - max(RibbonSpline.minStep, step))
            }
        }
    }

    // MARK: - Following a moving target

    /// **A head's recent positions** (follow mode): what a ribbon chasing a moving target — a shooting star
    /// landing in the passport, a card flying out of the deck — is drawn through. Positions are recorded once
    /// per frame; the body is resampled through a centripetal Catmull-Rom so a fast head (15 mm a frame at
    /// 1.4 m/s) still draws a curve rather than a polyline.
    struct TrailHistory {
        struct Entry: Equatable {
            var time: Float
            var position: SIMD3<Float>
            /// Total distance the head had travelled when it was here (its odometer).
            var odometer: Float
        }

        /// How much history is kept (the tail, plus a little for the spline's end tangents).
        var maxAge: Float
        private(set) var entries: [Entry] = []

        init(maxAge: Float) { self.maxAge = maxAge }

        var head: Entry? { entries.last }

        mutating func reset() { entries.removeAll(keepingCapacity: true) }

        /// Records the head at `time`. A head that has not moved (< 0.1 mm) only refreshes the newest entry's
        /// time, so a parked target does not fill the buffer with duplicates.
        mutating func record(_ position: SIMD3<Float>, at time: Float) {
            if let last = entries.last {
                let step = simd_length(position - last.position)
                if step < 0.0001, entries.count >= 2 {
                    entries[entries.count - 1].time = time
                    return
                }
                entries.append(Entry(time: time, position: position, odometer: last.odometer + step))
            } else {
                entries.append(Entry(time: time, position: position, odometer: 0))
            }
            // Keep one entry older than `maxAge` so the tail end can be interpolated exactly.
            while entries.count > 2, time - entries[1].time > maxAge + 0.05 {
                entries.removeFirst()
            }
        }

        /// The ribbon's centre line at `time`, head first, cut at `tail` seconds of age.
        func samples(at time: Float, tail: Float, spacing: Float, maxSamples: Int, into samples: inout [RibbonSample]) {
            samples.removeAll(keepingCapacity: true)
            guard entries.count >= 2 else { return }
            let n = entries.count
            func entry(_ i: Int) -> Entry { entries[max(0, min(n - 1, i))] }
            // Total length inside the tail, to choose the spacing.
            var budgetLength: Float = 0
            for i in stride(from: n - 1, to: 0, by: -1) {
                if time - entries[i].time > tail { break }
                budgetLength += simd_length(entries[i].position - entries[i - 1].position)
            }
            let step = max(spacing, budgetLength / Float(max(1, maxSamples - 2)))
            // Walk from the newest pair backwards.
            outer: for i in stride(from: n - 1, to: 0, by: -1) {
                let a = entry(i), b = entry(i - 1)            // a newer, b older
                let chord = simd_length(a.position - b.position)
                let pieces = max(1, Int(ceil(chord / step)))
                // Past either end the neighbour is mirrored (a duplicated end would give a zero tangent).
                let p1 = a.position, p2 = b.position
                let p0 = i + 1 < n ? entry(i + 1).position : 2 * p1 - p2
                let p3 = i - 2 >= 0 ? entry(i - 2).position : 2 * p2 - p1
                for k in 0..<pieces {
                    let f = Float(k) / Float(pieces)
                    let t = a.time + (b.time - a.time) * f
                    let age = time - t
                    if age > tail {
                        // Close the ribbon exactly at the end of its tail: where time − t = tail.
                        let fCut = max(0, min(1, (a.time - (time - tail)) / max(1e-6, a.time - b.time)))
                        samples.append(RibbonSample(position: V4.catmullRom(p0, p1, p2, p3, fCut),
                                                    age: tail,
                                                    distance: a.odometer + (b.odometer - a.odometer) * fCut))
                        break outer
                    }
                    samples.append(RibbonSample(position: V4.catmullRom(p0, p1, p2, p3, f),
                                                age: max(0, age),
                                                distance: a.odometer + (b.odometer - a.odometer) * f))
                    if samples.count >= maxSamples { break outer }
                }
                if i == 1 {
                    samples.append(RibbonSample(position: b.position, age: max(0, time - b.time), distance: b.odometer))
                }
            }
            if samples.count == 1 { samples.removeAll(keepingCapacity: true) }
        }
    }

    // MARK: - The camera-facing strip

    /// **Turns a centre line into a ribbon that faces the viewer** — and never flips, twists or breaks.
    ///
    /// The width direction ("side") of a camera-facing strip is tangent × (direction to the camera); that is
    /// the brief's "法线 = 路径切线 × 指向相机的方向", which names the strip's *width* axis — the face normal
    /// then points at the camera. The textbook version has two failure modes, and both show up on the
    /// recognition spiral, whose right-hand side heads almost straight at a seated reader:
    ///
    /// 1. **Flip.** Where the tangent swings through the view direction the cross product changes sign, and
    ///    the strip turns over — a visible half-twist with a pinch in the middle. Fixed by keeping every side
    ///    on the same side as its neighbour (and the head's on the same side as last frame's head).
    /// 2. **Pinch / spin.** Near that point the cross product is tiny and its direction is noise, so the
    ///    strip spins about its own centre line. Fixed by *parallel transport*: the neighbour's side, projected
    ///    off the new tangent, is carried along, and the camera-facing direction only takes over as it becomes
    ///    trustworthy (sin of the tangent–view angle 0.05 → 0.30, ≈ 3° → 17°). A ribbon seen end-on therefore
    ///    keeps its width and turns smoothly, like a real ribbon, instead of snapping.
    ///
    /// The texture is symmetric across the width, so which of the two faces is "front" never shows.
    enum RibbonStrip {
        struct Frame: Equatable {
            var center: SIMD3<Float>
            /// Unit width direction (⟂ tangent).
            var side: SIMD3<Float>
            /// Unit face normal, turned toward the camera.
            var normal: SIMD3<Float>
            var halfWidth: Float
            /// 0…1 brightness (the texture's U).
            var intensity: Float
            var age: Float
            var distance: Float
            /// The two edges' actual offsets: `halfWidth`, except on the inside of a turn tighter than the ribbon
            /// is wide, where the fold guard pulls that edge in (see `build`).
            var leftWidth: Float
            var rightWidth: Float

            var left: SIMD3<Float> { center + side * leftWidth }
            var right: SIMD3<Float> { center - side * rightWidth }
        }

        /// Where the camera-facing side starts to be trusted, and where it fully is (sin of the angle between
        /// tangent and view direction).
        static let trustFloor: Float = 0.05
        static let trustCeiling: Float = 0.30
        /// How fast the side may turn about the tangent, in radians per metre of ribbon (≈ 2° per mm). Where the
        /// path swings through the view direction the camera-facing side wants to turn up to 90° within a few
        /// samples — which draws as a crease. Capped, the turn spreads along the ribbon and reads as a ribbon
        /// rotating (it thins, then opens again) — the A2 lab's yaw-240 view is the case.
        static let maxTwistPerMetre: Float = 35
        /// The fold guard keeps an edge's offset under this share of the local radius of curvature, measured in
        /// the plane the viewer sees: past it, the inside edge of a hairpin would run backwards and cross itself.
        static let foldMargin: Float = 0.85

        /// Frames for `samples` (head first) as seen from `camera` (same space as the samples).
        ///
        /// - Parameters:
        ///   - previousHeadSide: last frame's head side, so the ribbon keeps its sides from frame to frame.
        ///   - intensityScale / widthScale: whole-ribbon multipliers (a dissolve, a flare).
        ///   - time: for the shimmer.
        /// - Returns: this frame's head side (feed it back next frame).
        @discardableResult
        static func build(samples: [RibbonSample], profile: RibbonProfile, camera: SIMD3<Float>,
                          previousHeadSide: SIMD3<Float>?, time: Float,
                          intensityScale: Float = 1, widthScale: Float = 1,
                          into frames: inout [Frame]) -> SIMD3<Float>? {
            frames.removeAll(keepingCapacity: true)
            let n = samples.count
            guard n >= 2 else { return previousHeadSide }
            var previousSide: SIMD3<Float>? = previousHeadSide
            var previousTangent: SIMD3<Float>? = nil
            for i in 0..<n {
                let sample = samples[i]
                let tangent = Self.tangent(samples, i, fallback: previousTangent)
                previousTangent = tangent
                var view = camera - sample.position
                let viewLength = simd_length(view)
                view = viewLength > 1e-6 ? view / viewLength : [0, 0, 1]

                let raw = simd_cross(tangent, view)
                let rawLength = simd_length(raw)
                var side: SIMD3<Float>
                if let reference = previousSide.flatMap({ Self.transport($0, onto: tangent) }) {
                    if rawLength > 1e-6 {
                        var facing = raw / rawLength
                        if simd_dot(facing, reference) < 0 { facing = -facing }
                        let trust = V4.smoothstep(trustFloor, trustCeiling, rawLength)
                        side = Self.normalized(reference * (1 - trust) + facing * trust, fallback: reference)
                    } else {
                        side = reference
                    }
                    // Along the ribbon (not at the head, whose reference is last frame's), cap the turn rate.
                    if i > 0 {
                        let step = simd_length(sample.position - samples[i - 1].position)
                        let limit = maxTwistPerMetre * max(step, 1e-4)
                        let angle = Self.signedAngle(from: reference, to: side, about: tangent)
                        if abs(angle) > limit {
                            side = Self.rotate(reference, about: tangent, by: angle > 0 ? limit : -limit)
                        }
                    }
                } else if rawLength > 1e-6 {
                    side = raw / rawLength
                } else {
                    side = Self.anyPerpendicular(to: tangent)
                }
                previousSide = side

                var normal = simd_cross(side, tangent)
                if simd_dot(normal, view) < 0 { normal = -normal }

                let width = max(0, profile.width(age: sample.age) * widthScale)
                let glow = profile.intensity(age: sample.age) * profile.shimmer(distance: sample.distance, time: time)
                frames.append(Frame(center: sample.position, side: side, normal: normal,
                                    halfWidth: width / 2,
                                    intensity: max(0, min(1, glow * intensityScale)),
                                    age: sample.age, distance: sample.distance,
                                    leftWidth: width / 2, rightWidth: width / 2))
            }
            guardFolds(&frames, camera: camera)
            return frames.first?.side
        }

        /// **The fold guard.** Where the centre line, *as the viewer sees it*, turns tighter than the ribbon is
        /// wide — a path swinging toward the camera draws a hairpin on screen even when its 3D curve is gentle —
        /// the inside edge would run backwards and cross itself (a bow-tie at the apex). Measured per sample in
        /// the plane across the line of sight: the circle through a sample and its two neighbours gives the local
        /// radius; the edge on that circle's side is kept under `foldMargin` × radius, and the limit relaxes over
        /// the neighbouring samples so the edge stays a smooth curve.
        static func guardFolds(_ frames: inout [Frame], camera: SIMD3<Float>) {
            let n = frames.count
            guard n >= 3 else { return }
            // The edge widths themselves carry the limits (no per-frame allocation): each starts at the half
            // width and is pulled in where the turn is too tight on its side.
            for i in 1..<(n - 1) {
                let p = frames[i].center
                var view = camera - p
                let viewLength = simd_length(view)
                guard viewLength > 1e-6 else { continue }
                view /= viewLength
                var a = frames[i - 1].center - p, b = frames[i + 1].center - p
                a -= simd_dot(a, view) * view
                b -= simd_dot(b, view) * view
                let la = simd_length(a), lb = simd_length(b), lab = simd_length(a - b)
                let twiceArea = simd_length(simd_cross(a, b))
                guard la > 1e-6, lb > 1e-6, twiceArea > 1e-10 else { continue }
                let radius = la * lb * lab / (2 * twiceArea)
                let limit = foldMargin * radius
                // The centre of that circle lies toward a + b: that is the inside of the turn.
                if simd_dot(a + b, frames[i].side) > 0 {
                    frames[i].leftWidth = min(frames[i].leftWidth, limit)
                } else {
                    frames[i].rightWidth = min(frames[i].rightWidth, limit)
                }
            }
            // Let a pulled-in edge ease in and out: no edge may be wider than its neighbour plus half a sample
            // step, both ways. (The ribbon's own taper changes far slower than that, so only folds are touched.)
            for i in 1..<n {
                let step = 0.5 * simd_length(frames[i].center - frames[i - 1].center)
                frames[i].leftWidth = min(frames[i].leftWidth, frames[i - 1].leftWidth + step)
                frames[i].rightWidth = min(frames[i].rightWidth, frames[i - 1].rightWidth + step)
            }
            for i in stride(from: n - 2, through: 0, by: -1) {
                let step = 0.5 * simd_length(frames[i].center - frames[i + 1].center)
                frames[i].leftWidth = min(frames[i].leftWidth, frames[i + 1].leftWidth + step)
                frames[i].rightWidth = min(frames[i].rightWidth, frames[i + 1].rightWidth + step)
            }
        }

        /// Signed angle (radians) that turns `a` onto `b` about `axis` (all unit; `a`, `b` ⟂ `axis`).
        static func signedAngle(from a: SIMD3<Float>, to b: SIMD3<Float>, about axis: SIMD3<Float>) -> Float {
            atan2(simd_dot(simd_cross(a, b), axis), simd_dot(a, b))
        }

        /// `v` (⟂ `axis`) turned by `angle` about `axis`.
        static func rotate(_ v: SIMD3<Float>, about axis: SIMD3<Float>, by angle: Float) -> SIMD3<Float> {
            v * cos(angle) + simd_cross(axis, v) * sin(angle)
        }

        /// Direction of travel at sample `i` (toward the head): the sample's own tangent when it has one,
        /// else a central difference, else the neighbour's.
        static func tangent(_ samples: [RibbonSample], _ i: Int, fallback: SIMD3<Float>?) -> SIMD3<Float> {
            let own = samples[i].tangent
            let ownLength = simd_length(own)
            if ownLength > 1e-6 { return own / ownLength }
            let n = samples.count
            let newer = samples[max(0, i - 1)].position, older = samples[min(n - 1, i + 1)].position
            let d = newer - older
            let length = simd_length(d)
            if length > 1e-7 { return d / length }
            return fallback ?? [0, 1, 0]
        }

        /// `side` with its component along `tangent` removed, renormalised (nil if it was parallel).
        static func transport(_ side: SIMD3<Float>, onto tangent: SIMD3<Float>) -> SIMD3<Float>? {
            let projected = side - simd_dot(side, tangent) * tangent
            let length = simd_length(projected)
            return length > 1e-4 ? projected / length : nil
        }

        static func anyPerpendicular(to v: SIMD3<Float>) -> SIMD3<Float> {
            let axis: SIMD3<Float> = abs(v.y) < 0.9 ? [0, 1, 0] : [1, 0, 0]
            return simd_normalize(simd_cross(v, axis))
        }

        private static func normalized(_ v: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
            let length = simd_length(v)
            return length > 1e-6 ? v / length : fallback
        }
    }

    // MARK: - Small shared maths

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// Centripetal Catmull-Rom between `p1` (f = 0) and `p2` (f = 1), with neighbours `p0` and `p3`.
    static func catmullRom(_ p0: SIMD3<Float>, _ p1: SIMD3<Float>, _ p2: SIMD3<Float>, _ p3: SIMD3<Float>,
                           _ f: Float) -> SIMD3<Float> {
        if f <= 0 { return p1 }
        if f >= 1 { return p2 }
        func knot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float { max(1e-5, sqrt(simd_length(b - a))) }
        let t01 = knot(p0, p1), t12 = knot(p1, p2), t23 = knot(p2, p3)
        let m1 = ((p1 - p0) / t01 - (p2 - p0) / (t01 + t12) + (p2 - p1) / t12) * t12
        let m2 = ((p2 - p1) / t12 - (p3 - p1) / (t12 + t23) + (p3 - p2) / t23) * t12
        let f2 = f * f, f3 = f2 * f
        let h00 = 2 * f3 - 3 * f2 + 1, h10 = f3 - 2 * f2 + f, h01 = -2 * f3 + 3 * f2, h11 = f3 - f2
        return h00 * p1 + h10 * m1 + h01 * p2 + h11 * m2
    }
}
