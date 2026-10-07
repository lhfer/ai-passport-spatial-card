import XCTest
import simd

/// **v4 A2.** The ribbon's width and brightness along its length, its sampling, and the camera-facing strip:
/// the brief's "never broken, twisted or flipped, from any angle" as numbers — checked on the real recognition
/// flight from cameras all round it, on a circle seen edge-on (whose tangent points straight at the camera
/// twice) and on a hairpin tighter than the ribbon is wide.
final class V4RibbonStripTests: XCTestCase {
    typealias Strip = V4.RibbonStrip

    // MARK: - Profiles

    func testTheFairyProfileIsTheArtBiblesRibbon() {
        let profile = V4.RibbonProfile.fairy
        XCTAssertGreaterThanOrEqual(profile.tail, 0.4)
        XCTAssertLessThanOrEqual(profile.tail, 0.8)
        var widest: Float = 0
        var lastIntensity: Float = 2
        for k in 0...200 {
            let age = profile.tail * Float(k) / 200
            widest = max(widest, profile.width(age: age))
            let intensity = profile.intensity(age: age)
            XCTAssertLessThanOrEqual(intensity, lastIntensity + 1e-6, "brightness only falls along the tail")
            lastIntensity = intensity
        }
        XCTAssertGreaterThanOrEqual(widest, 0.006, "head 6–12 mm")
        XCTAssertLessThanOrEqual(widest, 0.012, "head 6–12 mm")
        XCTAssertEqual(profile.intensity(age: 0), 1, accuracy: 1e-5)
        XCTAssertEqual(profile.width(age: profile.tail), 0, accuracy: 1e-6)
        XCTAssertEqual(profile.intensity(age: profile.tail), 0, accuracy: 1e-6)
        XCTAssertEqual(profile.intensity(age: 5), 0, accuracy: 1e-6)
    }

    func testTheStrokeCoolsToASteadyLine() {
        let profile = V4.RibbonProfile.stroke
        XCTAssertEqual(profile.intensity(age: 0), 1, accuracy: 1e-5)
        XCTAssertEqual(profile.intensity(age: 3), profile.steady, accuracy: 1e-3)
        XCTAssertGreaterThan(profile.width(age: 0), profile.width(age: 3))
        XCTAssertEqual(profile.width(age: 3), profile.width, accuracy: 1e-5)
    }

    // MARK: - Bodies

    func testTheTrailIsTheLastTailOfTheFlight() {
        let timeline = V4.RecognitionTimeline()
        var samples: [V4.RibbonSample] = []
        let t: Float = 0.9
        V4.RibbonBody.trail(spline: timeline.path, timing: timeline.timing, time: t, tail: 0.55,
                            spacing: 0.005, maxSamples: 240, into: &samples)
        XCTAssertGreaterThan(samples.count, 20)
        XCTAssertEqual(simd_distance(samples[0].position, timeline.headPosition(at: t)), 0, accuracy: 1e-4)
        XCTAssertEqual(samples[0].age, 0, accuracy: 0.003)
        XCTAssertEqual(samples.last?.age ?? 0, 0.55, accuracy: 0.004)
        var hint = -1
        for i in 1..<samples.count {
            XCTAssertGreaterThanOrEqual(samples[i].age, samples[i - 1].age - 1e-5, "ages grow toward the tail")
            let step = samples[i - 1].distance - samples[i].distance
            // 5 mm at the head, up to 2.5× that at the end of the tail…
            XCTAssertLessThanOrEqual(step, 0.005 * (1 + V4.RibbonBody.tailCoarsening) + 1e-5)
            // …and never more than the path allows where the step starts or lands (every bend stays round).
            let allowed = min(timeline.path.maxStep(atDistance: samples[i - 1].distance, hint: &hint),
                              timeline.path.maxStep(atDistance: samples[i].distance, hint: &hint))
            XCTAssertLessThanOrEqual(step, allowed + 1e-5, "step \(i) cuts a bend")
        }
        // Before the launch there is no ribbon.
        V4.RibbonBody.trail(spline: timeline.path, timing: timeline.timing, time: 0.05, tail: 0.55,
                            spacing: 0.005, maxSamples: 240, into: &samples)
        XCTAssertTrue(samples.isEmpty)
    }

    func testTheStrokeStaysOnceDrawn() {
        let timeline = V4.RecognitionTimeline()
        var samples: [V4.RibbonSample] = []
        V4.RibbonBody.stroke(spline: timeline.path, timing: timeline.timing, time: 2.3,
                             start: timeline.outlineStart, end: timeline.outlineEnd,
                             spacing: 0.015, maxSamples: 240, into: &samples)
        XCTAssertEqual(samples.first?.distance ?? 0, timeline.outlineEnd, accuracy: 1e-4)
        XCTAssertEqual(samples.last?.distance ?? 0, timeline.outlineStart, accuracy: 1e-4)
        // The corners stay round (≤ 0.1 mm sagitta on the 30 mm radius: every step there ≤ 5 mm), the
        // straights are cheap.
        var worstSagitta: Float = 0
        for i in 1..<samples.count {
            let a = samples[i - 1], b = samples[i]
            let mid = timeline.path.point(atDistance: (a.distance + b.distance) / 2)
            let chordMid = (a.position + b.position) / 2
            worstSagitta = max(worstSagitta, simd_distance(mid, chordMid))
        }
        XCTAssertLessThan(worstSagitta, 0.00012)
        XCTAssertLessThan(samples.count, 120, "\(samples.count) samples for a 1.03 m outline")
        // Half-way through the drawing only the drawn part exists.
        V4.RibbonBody.stroke(spline: timeline.path, timing: timeline.timing, time: 1.55,
                             start: timeline.outlineStart, end: timeline.outlineEnd,
                             spacing: 0.015, maxSamples: 240, into: &samples)
        XCTAssertEqual(samples.first?.distance ?? 0, timeline.headDistance(at: 1.55), accuracy: 1e-4)
    }

    func testFollowingAMovingTargetDrawsTheCurveItFlew() {
        var history = V4.TrailHistory(maxAge: 0.6)
        let radius: Float = 0.15, speed: Float = 0.6
        var t: Float = 0
        var last: Float = 0
        while t < 1.0 {
            let angle = speed / radius * t
            history.record([radius * cos(angle), 0.3, radius * sin(angle)], at: t)
            last = t
            t += 1 / 90
        }
        var samples: [V4.RibbonSample] = []
        history.samples(at: last, tail: 0.5, spacing: 0.004, maxSamples: 240, into: &samples)
        XCTAssertGreaterThan(samples.count, 30)
        XCTAssertEqual(samples[0].age, 0, accuracy: 1e-4)
        XCTAssertEqual(samples.last?.age ?? 0, 0.5, accuracy: 0.002)
        for i in 0..<samples.count {
            let p = samples[i].position
            XCTAssertEqual(simd_length(SIMD2<Float>(p.x, p.z)), radius, accuracy: 0.0005, "sample \(i) off the circle")
            if i > 0 {
                XCTAssertGreaterThanOrEqual(samples[i].age, samples[i - 1].age - 1e-5)
                XCTAssertLessThan(simd_distance(p, samples[i - 1].position), 0.0068)   // 6.7 mm chords at 90 Hz
            }
        }
    }

    // MARK: - The strip

    /// Frames for `path` sampled every `spacing`, head at the path's end, as seen from `camera`.
    private func frames(along path: V4.RibbonSpline, camera: SIMD3<Float>, profile: V4.RibbonProfile = .stroke,
                        age: Float = 1, spacing: Float = 0.004) -> [Strip.Frame] {
        var samples: [V4.RibbonSample] = []
        var s = path.length
        while s >= 0 {
            samples.append(V4.RibbonSample(position: path.point(atDistance: s), age: age, distance: s,
                                           tangent: path.tangent(atDistance: s)))
            s -= spacing
        }
        var frames: [Strip.Frame] = []
        Strip.build(samples: samples, profile: profile, camera: camera, previousHeadSide: nil, time: 0, into: &frames)
        return frames
    }

    /// The invariants every strip must keep: finite unit sides, faces turned to the camera, no flip between
    /// neighbours and a twist about the path no faster than the cap. Returns the first violation, or nil.
    private func violation(_ frames: [Strip.Frame], camera: SIMD3<Float>) -> String? {
        for i in 0..<frames.count {
            let f = frames[i]
            guard f.left.x.isFinite, f.right.y.isFinite, f.side.z.isFinite else { return "NaN at \(i)" }
            guard abs(simd_length(f.side) - 1) < 1e-3 else { return "side not unit at \(i)" }
            let view = simd_normalize(camera - f.center)
            guard simd_dot(f.normal, view) >= -1e-4 else { return "face turned away at \(i)" }
            guard i > 0 else { continue }
            let previous = frames[i - 1]
            guard simd_dot(f.side, previous.side) > 0 else { return "flip between \(i - 1) and \(i)" }
            // Twist = the side's turn about the path (bending the path turns it too, legitimately).
            let axis = simd_normalize(simd_cross(f.normal, f.side))
            if let carried = Strip.transport(previous.side, onto: axis) {
                let step = max(1e-4, simd_distance(f.center, previous.center))
                let twist = abs(Strip.signedAngle(from: carried, to: f.side, about: axis))
                if twist > Strip.maxTwistPerMetre * step * 1.10 + 2e-3 {
                    return String(format: "twist %.3f rad over %.1f mm at %d", twist, step * 1000, i)
                }
            }
        }
        return nil
    }

    private func assertWellFormed(_ frames: [Strip.Frame], camera: SIMD3<Float>, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        if let problem = violation(frames, camera: camera) {
            XCTFail("\(label): \(problem)", file: file, line: line)
        }
    }

    func testAHelixSeenFromTheSideFacesTheCamera() {
        let r: Float = 0.1, rise: Float = 0.18, sweep = 2 * Float.pi
        let helix = V4.RibbonSpline(segments: V4.RibbonSpline.sampled(
            pieces: 8, over: 0...sweep,
            { a in [r * cos(a), rise * a / sweep, r * sin(a)] },
            derivative: { a in [-r * sin(a), rise / sweep, r * cos(a)] }))
        let camera = SIMD3<Float>(0, 0.25, 0.7)
        let frames = frames(along: helix, camera: camera)
        assertWellFormed(frames, camera: camera, "helix")
        var facing = 0
        for f in frames {
            let view = simd_normalize(camera - f.center)
            // Where the path is clearly across the line of sight, the side lies in the view plane.
            let t = simd_normalize(simd_cross(f.side, f.normal))
            if simd_length(simd_cross(t, view)) > 0.35 {
                XCTAssertLessThan(abs(simd_dot(f.side, view)), 0.03)
                facing += 1
            }
        }
        XCTAssertGreaterThan(facing, frames.count / 2)
    }

    /// A circle in the vertical plane that contains the camera: at its near and far points the tangent points
    /// straight at the camera — the textbook flip. It must not flip, twist faster than the cap or go NaN.
    func testACircleSeenEdgeOnNeverFlips() {
        let circle = V4.RibbonSpline(segments: V4.RibbonSpline.arc(center: [0, 1.3, -0.7], radius: 0.12,
                                                                   u: [0, 0, 1], v: [0, 1, 0], from: 0, to: 2 * .pi))
        let camera = SIMD3<Float>(0, 1.3, 0)
        assertWellFormed(frames(along: circle, camera: camera), camera: camera, "edge-on circle")
    }

    /// The recognition's own flight, 30 frames a second of it, from 42 cameras on a sphere round the device —
    /// with the head side carried from frame to frame, as the rig does.
    func testTheRecognitionNeverFlipsFromAnyAngle() {
        let timeline = V4.RecognitionTimeline()
        var cameras: [SIMD3<Float>] = []
        for ring in 0..<6 {
            let elevation = -Float.pi / 2 * 0.8 + Float(ring) * (Float.pi * 0.8 / 5)
            for k in 0..<7 {
                let azimuth = Float(k) * 2 * .pi / 7 + Float(ring) * 0.3
                cameras.append(SIMD3<Float>(cos(elevation) * sin(azimuth), sin(elevation) + 0.2,
                                            cos(elevation) * cos(azimuth)) * 0.7)
            }
        }
        var samples: [V4.RibbonSample] = []
        var frames: [Strip.Frame] = []
        var checked = 0
        var failures: [String] = []
        for camera in cameras {
            var headSide: SIMD3<Float>? = nil
            var t: Float = 0.1
            while t < 2.2 {
                V4.RibbonBody.trail(spline: timeline.path, timing: timeline.timing, time: t, tail: 0.55,
                                    spacing: 0.005, maxSamples: 240, into: &samples)
                let previous = headSide
                headSide = Strip.build(samples: samples, profile: .fairy, camera: camera, previousHeadSide: headSide,
                                       time: t, into: &frames)
                if let problem = violation(frames, camera: camera) {
                    failures.append(String(format: "camera (%.2f, %.2f, %.2f) t %.2f: ", camera.x, camera.y, camera.z, t)
                                    + problem)
                }
                if let previous, let now = frames.first?.side, simd_dot(previous, now) <= 0 {
                    failures.append(String(format: "head flipped between frames at t %.2f", t))
                }
                checked += frames.count
                t += 1.0 / 30
            }
        }
        XCTAssertGreaterThan(checked, 100_000)
        XCTAssertTrue(failures.isEmpty, "\(failures.count) bad frames, first: \(failures.prefix(3))")
    }

    /// A hairpin tighter than the ribbon is wide, seen face-on: without the fold guard the inside edge runs
    /// backwards and crosses itself (a bow-tie at the apex). With it, both edges only ever move forward.
    func testTheFoldGuardKeepsTheInsideEdgeFromCrossingItself() {
        // A U-turn of radius 3 mm in the X-Y plane, camera straight in front, a 9.6 mm ribbon.
        var segments: [V4.RibbonSpline.Segment] = [V4.RibbonSpline.line([-0.05, 0.003, 0], [0, 0.003, 0])]
        segments += V4.RibbonSpline.arc(center: .zero, radius: 0.003, u: [0, 1, 0], v: [1, 0, 0], from: 0, to: .pi)
        segments.append(V4.RibbonSpline.line([0, -0.003, 0], [-0.05, -0.003, 0]))
        let hairpin = V4.RibbonSpline(segments: segments)
        let camera = SIMD3<Float>(0, 0, 0.5)
        let frames = frames(along: hairpin, camera: camera, profile: .fairy, age: 0.1, spacing: 0.001)
        assertWellFormed(frames, camera: camera, "hairpin")
        var pulledIn = false
        for i in 1..<frames.count {
            let forward = frames[i - 1].center - frames[i].center    // samples run head → tail
            for (a, b) in [(frames[i].left, frames[i - 1].left), (frames[i].right, frames[i - 1].right)] {
                XCTAssertGreaterThanOrEqual(simd_dot(b - a, forward), -1e-7, "an edge runs backwards at \(i)")
            }
            if min(frames[i].leftWidth, frames[i].rightWidth) < frames[i].halfWidth * 0.99 { pulledIn = true }
        }
        XCTAssertTrue(pulledIn, "the guard pulled the inside edge in")
    }

    func testGentleCurvesKeepTheirFullWidth() {
        let arc = V4.RibbonSpline(segments: V4.RibbonSpline.arc(center: .zero, radius: 0.1, u: [1, 0, 0],
                                                                v: [0, 1, 0], from: 0, to: .pi))
        for f in frames(along: arc, camera: [0, 0, 0.6], profile: .fairy, age: 0.1) {
            XCTAssertEqual(f.leftWidth, f.halfWidth, accuracy: 1e-6)
            XCTAssertEqual(f.rightWidth, f.halfWidth, accuracy: 1e-6)
        }
    }
}
