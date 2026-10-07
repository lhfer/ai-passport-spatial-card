import Foundation
import simd

extension V4 {
    /// **v4 B2 §3.2 — a loss that can explain itself.**
    ///
    /// v4's first headset round put the passport down, and 1.2 s later `expanded → held(untracked)`; then `Σ obj=0.0/s`
    /// for tens of seconds while the device lay on the desk in plain view, with nothing in the log to say whether the
    /// camera could see it at all, how far away it was, whether a hand was on it, what its bottom strip showed or what
    /// its backlight was doing. Two things answer that, both pure so the rule is a unit test:
    ///
    /// 1. **In view but untracked.** The last pose the tracker had is inside the head's view cone (`maxAngle` off the
    ///    gaze), nearer than `maxDistance`, and no tracked object observation has arrived for more than `after`
    ///    seconds: `[track] in view but untracked N s (dist …, angle …, hand …cm, strip …, bl …)`, again every
    ///    `every` seconds while it lasts, and one line with the total when it ends.
    /// 2. **Desk / hand segments.** From one presence family to the next (a `carrying` run is a hand segment, a resting
    ///    run a desk one; a hold belongs to the segment it froze in): the tracked share of the object stream, the
    ///    tracked rate with its one-second samples, how many times it was lost and how long each took to find again.
    ///    `[track] segment hand 40.6 s: objTracked 100 %, obj 29.9/s (1 s samples 27–31), 1 loss (re-found in 0.8 s)`.
    struct TrackingWatch: Equatable {
        /// The view cone's half-angle around the gaze (the view gate's own 42° / 55° hysteresis, taken in the middle).
        static let maxAngle: Float = 45 * .pi / 180
        static let maxDistance: Float = 1.2
        /// Untracked this long, in view, before the first line.
        static let after: TimeInterval = 1.0
        /// …and then a line every this often while it lasts.
        static let every: TimeInterval = 5.0
        /// A gap between two tracked observations longer than this is a loss (30 Hz is 33 ms apart).
        static let lossGap: TimeInterval = 0.3

        enum Segment: String, Equatable {
            case desk, hand
        }

        /// What the tracker knows at a tick.
        struct Context: Equatable {
            /// The wearer's head (world), or nil before the first head pose.
            var head: simd_float4x4?
            /// Where the passport was last seen (world).
            var lastPose: simd_float4x4?
            /// When the last **tracked** object observation arrived (nil = never).
            var lastTracked: TimeInterval?
            /// The nearest tracked wrist to that pose (m), nil = no hand data.
            var handDistance: Float?
            /// What the device's bottom strip shows: an override (`♥62`), or nil for the follower count.
            var strip: String?
            /// The backlight the device last reported / acked (%).
            var backlight: Int?
            /// A world holds the tracker paused: the stream is off, not lost.
            var paused: Bool = false
        }

        // MARK: In view but untracked

        private(set) var episodeStart: TimeInterval?
        private var nextReport: TimeInterval = 0

        /// Distance (m) and angle off the gaze (rad) from the head to a pose, or nil without both. The angle is how far
        /// off the centre of the view the device is (the gaze is the head's −Z): 0° = looked straight at.
        static func geometry(head: simd_float4x4?, pose: simd_float4x4?) -> (distance: Float, angle: Float)? {
            guard let head, let pose else { return nil }
            let eye = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
            let forward = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
            let target = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z) - eye
            let distance = simd_length(target)
            let fl = simd_length(forward)
            guard distance > 1e-4, fl > 1e-4, distance.isFinite else { return nil }
            let angle = acos(max(-1, min(1, simd_dot(forward / fl, target / distance))))
            return (distance, angle)
        }

        /// **v4 B4 §4.** The angle (rad) between the line of sight and the device's screen normal (the screen pose's +Y):
        /// 0° = the screen faces the eyes square-on, 90° = seen edge-on. A passport lying flat on a desk 0.7 m away and
        /// 0.3 m below the eyes is seen ≈ 67° off its normal; held up to the face, ≈ 0–30°. The question round 2 left
        /// open: are desk losses a matter of distance, or of seeing a flat device at a grazing angle?
        static func viewAngle(head: simd_float4x4?, pose: simd_float4x4?) -> Float? {
            guard let head, let pose else { return nil }
            let eye = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
            let toEye = eye - SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
            let normal = SIMD3<Float>(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z)
            let d = simd_length(toEye), n = simd_length(normal)
            guard d > 1e-4, n > 1e-4, d.isFinite, n.isFinite else { return nil }
            return acos(max(-1, min(1, simd_dot(toEye / d, normal / n))))
        }

        /// Both angles at once (rad): off the gaze, and off the screen's normal.
        struct Angles: Equatable {
            var offGaze: Float
            var offNormal: Float
        }

        static func angles(head: simd_float4x4?, pose: simd_float4x4?) -> Angles? {
            guard let g = geometry(head: head, pose: pose), let n = viewAngle(head: head, pose: pose) else { return nil }
            return Angles(offGaze: g.angle, offNormal: n)
        }

        /// Is the passport's last pose one the camera should be seeing?
        static func isInView(head: simd_float4x4?, pose: simd_float4x4?) -> Bool {
            guard let g = geometry(head: head, pose: pose) else { return false }
            return g.distance < maxDistance && g.angle <= maxAngle
        }

        /// One tick: the lines to print (none most of the time).
        mutating func tick(_ context: Context, at time: TimeInterval) -> [String] {
            let quiet = context.lastTracked.map { time - $0 }
            let candidate = !context.paused && (quiet ?? 0) > TrackingWatch.after
                && TrackingWatch.isInView(head: context.head, pose: context.lastPose)
            if candidate, let quiet, let last = context.lastTracked {
                if episodeStart == nil {
                    // Dated from the moment the passport went quiet, not from when the rule noticed.
                    episodeStart = last
                    nextReport = time
                }
                guard time >= nextReport else { return [] }
                nextReport = time + TrackingWatch.every
                return [TrackingWatch.line(untracked: quiet, context)]
            }
            guard let start = episodeStart else { return [] }
            episodeStart = nil
            // Over: a tracked observation (the usual end), a world pausing the tracker, or the head turning away.
            let why: String
            let total: TimeInterval
            if let last = context.lastTracked, last > start {
                why = "tracked again"
                total = last - start
            } else if context.paused {
                why = "a world paused the tracker"
                total = time - start
            } else {
                why = "out of view"
                total = time - start
            }
            return [String(format: "[track] in view but untracked ended after %.1f s (%@)", total, why)]
        }

        /// The session is ending with an episode running: its total, and why it stopped being watched.
        mutating func endEpisode(at time: TimeInterval, reason: String) -> String? {
            guard let start = episodeStart else { return nil }
            episodeStart = nil
            return String(format: "[track] in view but untracked ended after %.1f s (%@)", max(0, time - start), reason)
        }

        /// `angle`: off the centre of the view (the gaze); `normal`: the line of sight off the screen's normal (v4 B4 §4).
        static func line(untracked: TimeInterval, _ context: Context) -> String {
            let g = geometry(head: context.head, pose: context.lastPose)
            let dist = g.map { String(format: "%.2f m", $0.distance) } ?? "-"
            let angle = g.map { String(format: "%.0f°", $0.angle * 180 / .pi) } ?? "-"
            let normal = viewAngle(head: context.head, pose: context.lastPose).map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "-"
            let hand = context.handDistance.map { String(format: "%.0f cm", $0 * 100) } ?? "-"
            let strip = context.strip ?? "followers"
            let bl = context.backlight.map { "\($0) %" } ?? "-"
            return String(format: "[track] in view but untracked %.1f s (dist %@, angle %@, normal %@, hand %@, strip %@, bl %@)",
                          untracked, dist, angle, normal, hand, strip, bl)
        }

        // MARK: Segments

        private(set) var segment: Segment?
        private var segmentStart: TimeInterval = 0
        private var observations = 0
        private var trackedObservations = 0
        private var lastTrackedAt: TimeInterval?
        private(set) var losses: [TimeInterval] = []
        /// **v4 B4 §4.** The two angles at the moment of each loss (the last tracked observation before the gap).
        private(set) var lossAngles: [Angles] = []
        /// The angles at the last tracked observation (they become a loss's if a gap follows).
        private var lastTrackedAngles: Angles?
        /// Tracked observations per whole second of the segment (`obj/s` samples).
        private var secondBuckets: [Int] = []

        /// One object observation (tracked or not). `angles`: the view of the device at this observation (v4 B4 §4).
        mutating func observe(tracked: Bool, at time: TimeInterval, angles: Angles? = nil) {
            guard segment != nil else { return }
            observations += 1
            guard tracked else { return }
            trackedObservations += 1
            if let last = lastTrackedAt, time - last > TrackingWatch.lossGap {
                losses.append(time - last)
                if let lastTrackedAngles { lossAngles.append(lastTrackedAngles) }
            }
            lastTrackedAt = time
            if let angles { lastTrackedAngles = angles }
            let second = max(0, Int(time - segmentStart))
            if second < 3600 {
                if secondBuckets.count <= second { secondBuckets.append(contentsOf: repeatElement(0, count: second - secondBuckets.count + 1)) }
                secondBuckets[second] += 1
            }
        }

        /// The presence moved into `kind` (nil = no segment: absent, or a world). Returns the summary of the segment
        /// that just ended, if one did.
        mutating func enter(_ kind: Segment?, at time: TimeInterval) -> String? {
            guard kind != segment else { return nil }
            let summary = segment.map { summaryLine($0, until: time) }
            segment = kind
            segmentStart = time
            observations = 0
            trackedObservations = 0
            lastTrackedAt = kind == nil ? nil : lastTrackedAt
            losses = []
            lossAngles = []
            secondBuckets = []
            return summary
        }

        /// The session is over: whatever segment is running reports.
        mutating func finish(at time: TimeInterval) -> String? { enter(nil, at: time) }

        func summaryLine(_ kind: Segment, until time: TimeInterval) -> String {
            let duration = max(0, time - segmentStart)
            let rate = observations > 0 ? String(format: "%.0f %%", 100 * Double(trackedObservations) / Double(observations)) : "-"
            let perSecond = duration > 0 ? Double(trackedObservations) / duration : 0
            // Whole seconds only: the last, partial one would read as a drop.
            let whole = secondBuckets.prefix(max(0, Int(duration)))
            let samples = whole.isEmpty ? "" : " (1 s samples \(whole.min()!)–\(whole.max()!))"
            var line = String(format: "[track] segment %@ %.1f s: objTracked %@, obj %.1f/s%@, %d loss%@",
                              kind.rawValue, duration, rate, perSecond, samples, losses.count, losses.count == 1 ? "" : "es")
            if !losses.isEmpty {
                line += " (re-found in " + losses.map { String(format: "%.1f", $0) }.joined(separator: " / ") + " s)"
            }
            var atLoss = lossAngles
            if let last = lastTrackedAt, time - last > TrackingWatch.lossGap {
                line += String(format: ", untracked for the last %.1f s", time - last)
                if let lastTrackedAngles { atLoss.append(lastTrackedAngles) }
            } else if lastTrackedAt == nil {
                line += ", never tracked"
            }
            // v4 B4 §4: how the device was seen when it went — off the gaze, and off its screen's normal.
            if !atLoss.isEmpty {
                let n = Float(atLoss.count)
                let gaze = atLoss.map(\.offGaze).reduce(0, +) / n * 180 / .pi
                let normal = atLoss.map(\.offNormal).reduce(0, +) / n * 180 / .pi
                line += String(format: "; at the loss%@: angle %.0f°, normal %.0f°", atLoss.count > 1 ? "es (avg)" : "", gaze, normal)
            }
            return line
        }

        /// Which segment a presence belongs to: carrying is the hand, resting (acquiring / expanded / settling) the desk,
        /// a hold (a loss, a button, a theme) stays in the segment it froze in, and a world (the stream is off, not lost)
        /// or `absent` is none.
        static func segment(carrying: Bool, resting: Bool, held: Bool, world: Bool, current: Segment?) -> Segment? {
            if world { return nil }
            if carrying { return .hand }
            if resting { return .desk }
            if held { return current }
            return nil
        }
    }
}

extension V4 {
    /// **v4 B5 §6 — the angle the device is seen at while it is tracked, for the `Σ` line.**
    ///
    /// B4 put the line-of-sight-to-screen-normal angle into the loss lines (`normal N°`), which says how the device was
    /// seen when it went — but not how it is seen the rest of the time. The user keeps the desk's tracking as it is
    /// (10-06) and wants the data to keep coming: every tracked observation in a 5 s `Σ` window adds its angle here, and
    /// the line ends `normal=58° (52–63°)`, or `normal=-` for a window with nothing tracked. Logging only.
    struct ViewAngleWindow: Equatable {
        private(set) var count = 0
        private(set) var sum: Float = 0
        private(set) var low: Float = .infinity
        private(set) var high: Float = -.infinity

        init() {}

        /// One tracked observation's angle off the screen's normal (rad).
        mutating func add(_ radians: Float) {
            guard radians.isFinite else { return }
            count += 1
            sum += radians
            low = min(low, radians)
            high = max(high, radians)
        }

        /// `normal=58° (52–63°)`, or `normal=-`.
        var field: String {
            guard count > 0 else { return "normal=-" }
            let deg: (Float) -> Int = { Int(($0 * 180 / .pi).rounded()) }
            return "normal=\(deg(sum / Float(count)))° (\(deg(low))–\(deg(high))°)"
        }
    }
}
