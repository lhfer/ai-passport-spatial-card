import Foundation
import simd

/// **Button feedback 2.0 — the edge wave** (V3-4 §1).
///
/// V3-2a2's button glint was a 6 mm dot at the key itself. On the headset it fired 37 times out of 37 and the
/// wearer saw **none** of them: visionOS draws the real hand over virtual content (and the app is not allowed
/// to set `upperLimbVisibility` — the hand in shot is the whole premise), so a 6 mm dot at x ±36 mm, z −4 mm
/// lives exactly under the thumb that is pressing the key.
///
/// So the feedback has to *leave* the thumb. This type is the geometry of the answer: a ring of thin segments
/// around the device's outline — the same circle the light well's edge glow hugs — and, for each of them, how
/// long the light takes to reach it from the key that was pressed. Two wavefronts leave the key in opposite
/// directions at `speed` and meet on the far side, so the wearer sees the light come out from under their own
/// thumb and run round the hardware.
///
/// Pure value type (simd + Foundation), so `ButtonWaveTests` can check the contour, the delays and the H0
/// clearance without a RealityKit scene — which matters because the simulator can show the wave but only the
/// headset can say whether it reads.
enum ButtonWaveLayout {
    /// How many segments the ring is cut into.
    static let segmentCount = 24
    /// A segment is 14 mm along the contour …
    static let segmentLength: Float = 0.014
    /// … and 6 mm across it.
    static let segmentWidth: Float = 0.006
    /// Clear gap between the audited prism (footprint + 3 mm) and the ring's **inner** edge. 5 mm — the same
    /// circle `LightWell.edgeGap` starts the edge glow at, so the wave runs inside the glow ring's own band
    /// rather than drawing a second, competing outline.
    static let gap: Float = 0.005
    /// How fast the light travels along the contour.
    static let speed: Float = 1.0
    /// Corner radius of the contour. The device's own corners are rounded; a sharp-cornered ring would make
    /// two segments jump 90° of yaw between neighbours.
    static let cornerRadius: Float = 0.010
    /// The ring's height above the screen plane: the light well's edge ring sits at +1.6 mm, and the wave
    /// rides 0.2 mm over it so the two never z-fight.
    static let y: Float = 0.0018
    /// One segment's rise / hold / fall, in seconds. They live here rather than on the rig so `envelope`
    /// and its test can be driven by the shipped numbers.
    ///
    /// **V3-5 §7c: 0.25 s → 0.35 s**, in V3-4's proportions. With the in-hand edge ring turned down to 0.35
    /// the wave has to be the brighter of the two, and a quarter of a second of it — through a ring the
    /// wearer is looking straight at — was not enough on camera to read as a light *running round* the
    /// device rather than as a flicker. (The lap itself is unchanged: `speed` still carries the front round
    /// the contour at 1 m/s and the two halves still meet at 0.19 s.)
    static let rise: Float = 0.08
    static let hold: Float = 0.07
    static let fall: Float = 0.20

    /// One segment of the ring.
    struct Segment: Equatable {
        /// Centre, in the screen frame S.
        var position: SIMD3<Float>
        /// Rotation about +Y that puts the segment's own +X along the contour.
        var yaw: Float
        /// Distance from the contour's origin, along the contour.
        var arc: Float
    }

    // MARK: - The contour

    /// Half extent of the **centre line** of the ring: the prism, plus the gap, plus half the segment's width.
    /// A segment centred here has its inner edge exactly on `gap` and is outside the prism by construction.
    static func halfExtent(_ footprint: DeviceFootprint) -> SIMD2<Float> {
        let h = footprint.half
        return [h.x + gap + segmentWidth / 2, h.y + gap + segmentWidth / 2]
    }

    /// The corner radius actually used: never more than half of the shorter side.
    static func radius(_ footprint: DeviceFootprint) -> Float {
        let h = halfExtent(footprint)
        return max(0, min(cornerRadius, min(h.x, h.y)))
    }

    /// Length of one straight run along the device's **long** sides (constant x) …
    static func longRun(_ footprint: DeviceFootprint) -> Float { 2 * (halfExtent(footprint).y - radius(footprint)) }
    /// … and along its **short** ones (constant z).
    static func shortRun(_ footprint: DeviceFootprint) -> Float { 2 * (halfExtent(footprint).x - radius(footprint)) }

    static func perimeter(_ footprint: DeviceFootprint) -> Float {
        2 * longRun(footprint) + 2 * shortRun(footprint) + 2 * .pi * radius(footprint)
    }

    /// How long the two wavefronts take to meet on the far side of the device.
    static func meetSeconds(_ footprint: DeviceFootprint, speed: Float = ButtonWaveLayout.speed) -> Float {
        guard speed > 0 else { return 0 }
        return perimeter(footprint) / 2 / speed
    }

    /// A point on the contour at arc length `s` from the origin, with the tangent's yaw.
    ///
    /// The contour starts on the +X side at z = −(hz − r) and runs toward +Z, i.e. from the device's top edge
    /// toward the reader: +X straight, +Z corner, +Z straight, −X corner, −X straight, −Z corner, −Z straight,
    /// +X corner, back to the start.
    static func point(atArc s: Float, footprint: DeviceFootprint) -> (position: SIMD3<Float>, yaw: Float) {
        let h = halfExtent(footprint)
        let r = radius(footprint)
        let long = longRun(footprint), short = shortRun(footprint)
        let quarter = .pi * r / 2
        let total = perimeter(footprint)
        var t = total > 0 ? s.truncatingRemainder(dividingBy: total) : 0
        if t < 0 { t += total }

        func straight(_ x: Float, _ z: Float, tangent: SIMD3<Float>) -> (SIMD3<Float>, Float) {
            ([x, y, z], yaw(of: tangent))
        }
        // The four corner centres, in contour order.
        func corner(_ centre: SIMD2<Float>, from a0: Float, progress: Float) -> (SIMD3<Float>, Float) {
            let a = a0 + progress * (.pi / 2)
            let p = SIMD3<Float>(centre.x + r * cos(a), y, centre.y + r * sin(a))
            // Tangent of a counter-clockwise circle in the XZ plane at angle a.
            let tangent = SIMD3<Float>(-sin(a), 0, cos(a))
            return (p, yaw(of: tangent))
        }

        var cursor = t
        if cursor < long { return straight(h.x, -(h.y - r) + cursor, tangent: [0, 0, 1]) }
        cursor -= long
        if cursor < quarter { return corner([h.x - r, h.y - r], from: 0, progress: cursor / max(1e-6, quarter)) }
        cursor -= quarter
        if cursor < short { return straight(h.x - r - cursor, h.y, tangent: [-1, 0, 0]) }
        cursor -= short
        if cursor < quarter { return corner([-(h.x - r), h.y - r], from: .pi / 2, progress: cursor / max(1e-6, quarter)) }
        cursor -= quarter
        if cursor < long { return straight(-h.x, (h.y - r) - cursor, tangent: [0, 0, -1]) }
        cursor -= long
        if cursor < quarter { return corner([-(h.x - r), -(h.y - r)], from: .pi, progress: cursor / max(1e-6, quarter)) }
        cursor -= quarter
        if cursor < short { return straight(-(h.x - r) + cursor, -h.y, tangent: [1, 0, 0]) }
        cursor -= short
        return corner([h.x - r, -(h.y - r)], from: 3 * .pi / 2, progress: cursor / max(1e-6, quarter))
    }

    /// A rotation about +Y takes local +X = (1, 0, 0) to (cos θ, 0, −sin θ), so a tangent (tx, 0, tz) wants
    /// θ = atan2(−tz, tx).
    static func yaw(of tangent: SIMD3<Float>) -> Float { atan2(-tangent.z, tangent.x) }

    /// The whole ring, evenly spaced, starting half a step in so no segment straddles the contour's origin.
    static func segments(footprint: DeviceFootprint, count: Int = ButtonWaveLayout.segmentCount) -> [Segment] {
        guard count > 0 else { return [] }
        let total = perimeter(footprint)
        let step = total / Float(count)
        return (0..<count).map { index in
            let arc = (Float(index) + 0.5) * step
            let p = point(atArc: arc, footprint: footprint)
            return Segment(position: p.position, yaw: p.yaw, arc: arc)
        }
    }

    // MARK: - Where a key sits on it

    /// The arc length of the contour point nearest a key. The keys are on one long side, so this is always a
    /// point on one of the two straight runs at constant x.
    static func keyArc(_ key: ButtonGlintLayout.Key, edge: ButtonGlintLayout.Edge,
                       footprint: DeviceFootprint) -> Float {
        let h = halfExtent(footprint)
        let r = radius(footprint)
        let long = longRun(footprint), short = shortRun(footprint)
        let quarter = .pi * r / 2
        // Clamp to the straight run: a key beyond the corner is projected onto the run's end.
        let z = max(-(h.y - r), min(h.y - r, key.z))
        switch edge {
        case .plusX:
            return z + (h.y - r)
        case .minusX:
            return long + quarter + short + quarter + ((h.y - r) - z)
        }
    }

    /// The delay, in seconds, before each segment lights up: the shorter of the two ways round the contour
    /// from the key, divided by `speed`. Two wavefronts, meeting at `meetSeconds`.
    static func delays(footprint: DeviceFootprint, key: ButtonGlintLayout.Key, edge: ButtonGlintLayout.Edge,
                       count: Int = ButtonWaveLayout.segmentCount,
                       speed: Float = ButtonWaveLayout.speed) -> [Float] {
        let total = perimeter(footprint)
        let origin = keyArc(key, edge: edge, footprint: footprint)
        return segments(footprint: footprint, count: count).map { segment in
            var d = abs(segment.arc - origin).truncatingRemainder(dividingBy: total)
            if d < 0 { d += total }
            d = min(d, total - d)
            return speed > 0 ? d / speed : 0
        }
    }

    // MARK: - What the footprint audit is handed (V3-5 §3)

    /// The four corners of one segment's 14 × 6 mm rectangle, in the segment's **own** space.
    ///
    /// **V3-5 §3.** The second headset round reported `[footprint] buttonWave.11 / .18 inside for 2–3 s`.
    /// Neither segment was ever over the device: 11 and 18 are two of the four **corner** segments (6, 11,
    /// 18 and 23 at 24 slots), and a 14 mm segment lying at 45° on the corner arc has an *axis-aligned*
    /// bounding box ±5 mm bigger than itself — which is all `visualBounds` can give the auditor, and it
    /// crosses the prism's own corner by 0.3–2.1 mm. The rectangle does not: its nearest point is 7 mm from
    /// the corner arc's centre and the prism's corner is 2.8 mm from it.
    ///
    /// So the rig hands the auditor these four points instead (`FootprintProbeComponent.points`, which
    /// converts them into S and asks `DeviceFootprint.contains`). That is an **exact** test of the rotated
    /// rectangle, not an exemption: point sampling can only miss an overlap that pokes in between the
    /// samples, and the prism is a 66 × 101 mm rectangle whose nearest corner is 4.2 mm clear of the
    /// segment's inner edge, so there is nothing to poke in with.
    static let localCorners: [SIMD3<Float>] = [
        [segmentLength / 2, 0, segmentWidth / 2],
        [segmentLength / 2, 0, -segmentWidth / 2],
        [-segmentLength / 2, 0, segmentWidth / 2],
        [-segmentLength / 2, 0, -segmentWidth / 2],
    ]

    /// The same four corners in the screen frame S (tests, diagnostics).
    static func corners(of segment: Segment) -> [SIMD3<Float>] {
        let q = simd_quatf(angle: segment.yaw, axis: [0, 1, 0])
        return localCorners.map { segment.position + q.act($0) }
    }

    /// The **axis-aligned** bounds of one segment in S — what `visualBounds` reports, i.e. what the auditor
    /// judged before V3-5 §3. Kept so the false positive itself is an assertion rather than an argument.
    static func bounds(of segment: Segment) -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        let corners = corners(of: segment)
        var lo = corners[0], hi = corners[0]
        for c in corners.dropFirst() {
            lo = simd_min(lo, c)
            hi = simd_max(hi, c)
        }
        return (lo, hi)
    }

    // MARK: - One segment's envelope

    /// One segment's opacity `t` seconds after the wavefront reached it: 0 → `peak` over `rise`, held for
    /// `hold`, back to 0 over `fall`. **Nil once the fall is over** — the system's signal to write exactly
    /// `OpacityComponent(opacity: 0)` and drop the component, so a finished wave leaves nothing lit behind
    /// it (the second candidate cause of the V3-5 §3 audit finding; it is ruled out here rather than argued).
    static func envelope(t: Float, rise: Float, hold: Float, fall: Float, peak: Float) -> Float? {
        guard t >= 0 else { return 0 }
        if t < rise {
            let k = rise > 0 ? t / rise : 1
            return peak * (1 - (1 - k) * (1 - k))          // ease-out in
        }
        if t < rise + hold { return peak }
        let k = fall > 0 ? (t - rise - hold) / fall : 1
        guard k < 1 else { return nil }
        return peak * (1 - k) * (1 - k)                    // ease-in out
    }

    /// The one line the log prints when a key is pressed:
    /// `[fx] button wave down (+x, z +20 mm, 24 segments, meet at 0.19 s)`.
    static func logSuffix(_ key: ButtonGlintLayout.Key, edge: ButtonGlintLayout.Edge,
                          footprint: DeviceFootprint, count: Int = ButtonWaveLayout.segmentCount,
                          speed: Float = ButtonWaveLayout.speed) -> String {
        String(format: "%@ (%@, z %+.0f mm, %d segments, meet at %.2f s)",
               key.label, edge.rawValue, key.z * 1000, count, meetSeconds(footprint, speed: speed))
    }
}
