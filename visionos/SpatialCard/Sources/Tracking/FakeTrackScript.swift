import Foundation
import simd

/// One segment of a `--fake-track` script (see `README.md` next to `--fake-device`).
///
/// Poses are emitted at `rateHz` starting at `fromSeconds` (inclusive) while the emission time is still below
/// `toSeconds`, so a segment shorter than one period emits **exactly one** observation — that is how the script
/// expresses "a single detection 30 cm away". Time not covered by any segment emits nothing at all, which is what
/// an occlusion looks like when ARKit simply stops reporting (`held(.stale)`); `"tracked": false` instead emits
/// *untracked* observations, which is what the headset actually did on every loss of device round 1
/// (`held(.untracked)`).
struct FakeTrackSegment: Decodable {
    var fromSeconds: Double
    var toSeconds: Double
    /// Anchor position at `fromSeconds` (metres, world space).
    var position: SIMD3<Float>
    /// Position at `toSeconds`; absent = the card does not move inside the segment. Interpolated linearly, so a
    /// slide is a continuous stream of small steps rather than one jump.
    var toPosition: SIMD3<Float>?
    /// Image-plane orientation in degrees (applied X, then Y, then Z). All zeros — the default — is a device lying
    /// flat on the desk: the anchor's +Y is the image normal (`HologramLayout`).
    var eulerDeg: SIMD3<Float>?
    var toEulerDeg: SIMD3<Float>?
    /// `false` emits untracked observations (ARKit still reports the anchor, flagged as not tracked).
    var tracked: Bool?
    /// Which provider this segment stands in for: `"image"` (the default) or `"object"` (工作包 G). Two segments
    /// may cover the same seconds — that is what a co-observation is, and it is how the calibration gets its
    /// samples in the simulator.
    var source: String?
    /// **Object segments only.** The true `objectToScreen` this harness pretends the trained reference object
    /// has: `position` / `eulerDeg` always describe the *screen* (so image and object segments are written in the
    /// same coordinates and can be compared by eye), and the object pose actually emitted is
    /// `screenPose · inverse(objectToScreen)`. The app then has to recover exactly this number by co-observation —
    /// which is the only reason `[obj] calibrated: offset …` can be checked against a known answer.
    ///
    /// **V3-1b: leave it out and the harness derives it from `--fake-box`** (`ObjectScreenFrame(box:).offset`,
    /// unflipped), so the *same* script drives the Y-thin scan box and the Z-thin box the headset really reports
    /// and the app recovers the scripted screen pose exactly in both. Written out, it still means what it always
    /// did — "the object frame is *this*, go and find it" — which is what the calibration harness
    /// (`fake-track-object.json`) needs and what makes that script box-independent by design.
    var objectOffset: SIMD3<Float>?
    var objectOffsetEulerDeg: SIMD3<Float>?
    var rateHz: Double?
    /// Gaussian position noise, given as the **RMS step between consecutive poses** — the number `[gate] Σ jitter`
    /// prints (the headset measured 0.0–0.1 mm at rest).
    var jitterMm: Float?
    /// Desk height under the card; omitted = the tracker's own fallback (image plane − device thickness).
    var surfaceY: Float?
    /// Printed once when the segment starts, so the console says which beat is running.
    var note: String?
    /// **V3-2b B6.** The wearer's hand during this segment. The simulator has no hand tracking at all, so a
    /// script is the only way to exercise the bridge (plan H4) before the headset: the harness emits a hand
    /// observation alongside every pose this segment produces, and `CardTracker` feeds it to `HandBridge`
    /// through the same entry point the real `HandTrackingProvider` uses.
    var hand: FakeHandSegment?
    /// **v4 B4 §3.3.** Where the wearer's head is during this segment (world metres; `toHead` = where it ends up,
    /// interpolated like `toPosition`). Absent = the harness's fixed reader at (0, 1.59, 0). A sideways head move turns
    /// the head → card direction — what made B3's desk drop and rebuild its prebuilt worlds.
    var head: SIMD3<Float>?
    var toHead: SIMD3<Float>?
}

/// One hand, scripted (V3-2b B6). Poses are the wrist / middle-knuckle midpoint in world space — the same
/// point `readHandAnchors` computes on the headset.
struct FakeHandSegment: Decodable {
    /// `"left"` (the default) or `"right"`.
    var side: String?
    var position: SIMD3<Float>
    var toPosition: SIMD3<Float>?
    var eulerDeg: SIMD3<Float>?
    var toEulerDeg: SIMD3<Float>?
    /// `false` = the hand is reported but not tracked (a wrist out of view): the bridge may not use it.
    var tracked: Bool?
}

/// A scripted hand observation, carried alongside the pose sample of the same instant.
struct FakeHandSample {
    var side: String
    var pose: simd_float4x4
    var isTracked: Bool
}

/// One observation a script produces.
struct FakeTrackSample {
    var at: TimeInterval
    /// Screen pose for an image sample; the raw pose **in the object's frame** for an object one.
    var pose: simd_float4x4
    var isTracked: Bool
    var source: TrackingFusion.Source = .image
    var surfaceY: Float?
    var note: String?
    /// V3-2b B6: the hand this segment says is holding the device, at this instant.
    var hand: FakeHandSample?
    /// v4 B4 §3.3: the wearer's head at this instant, when the segment scripts it.
    var head: SIMD3<Float>?
}

enum FakeTrackScript {
    /// The headset reports tracked image anchors at 22–30 Hz, not the 6 Hz the design assumed.
    static let defaultRateHz: Double = 30
    static let defaultJitterMm: Float = 0.1

    static func load(_ url: URL?) -> [FakeTrackSegment] {
        guard let url else { return [] }
        guard let data = try? Data(contentsOf: url) else {
            print("[track] cannot read \(url.path)")
            return []
        }
        do {
            let segments = try JSONDecoder().decode([FakeTrackSegment].self, from: data)
            print("[track] \(segments.count) segments from \(url.lastPathComponent)")
            return segments
        } catch {
            print("[track] script invalid: \(error)")
            return []
        }
    }

    /// Expands a script into the exact observation stream it stands for, so the runner is a plain "sleep until t,
    /// ingest" loop and the same script always produces the same log.
    static func expand(_ segments: [FakeTrackSegment],
                       box: ObjectScreenFrame.Box = .aiPassportHeadset) -> [FakeTrackSample] {
        var noise = Noise()
        var samples: [FakeTrackSample] = []
        for segment in segments.sorted(by: { $0.fromSeconds < $1.fromSeconds }) {
            let period = 1 / max(0.1, segment.rateHz ?? defaultRateHz)
            let span = max(0, segment.toSeconds - segment.fromSeconds)
            // Per-axis σ from the RMS step the field is named after: independent noise on two consecutive poses
            // gives E|Δ|² = 6σ², so σ = jitter / √6 — otherwise `Σ jitter` would read ≈ 2.4× the number written here.
            let sigma = (segment.jitterMm ?? defaultJitterMm) / 1000 / (6 as Float).squareRoot()
            var k = 0
            while true {
                let t = segment.fromSeconds + Double(k) * period
                guard t < segment.toSeconds - 1e-9 else { break }
                let u = SIMD3<Float>(repeating: span > 0 ? Float(min(1, max(0, (t - segment.fromSeconds) / span))) : 0)
                var p = simd_mix(segment.position, segment.toPosition ?? segment.position, u)
                if sigma > 0 { p += SIMD3<Float>(noise.normal(), noise.normal(), noise.normal()) * sigma }
                let from = segment.eulerDeg ?? .zero
                let euler = simd_mix(from, segment.toEulerDeg ?? from, u)
                // The script always writes the *screen* pose. An object segment then reports it the way the
                // provider would: in the trained object's own frame, i.e. `screen · inverse(objectToScreen)`.
                var emitted = pose(position: p, eulerDeg: euler)
                let source: TrackingFusion.Source = segment.source == "object" ? .object : .image
                if source == .object {
                    emitted = emitted * objectToScreen(of: segment, box: box).inverse
                }
                var hand: FakeHandSample?
                if let scripted = segment.hand {
                    let from = scripted.eulerDeg ?? .zero
                    let handPose = pose(position: simd_mix(scripted.position, scripted.toPosition ?? scripted.position, u),
                                        eulerDeg: simd_mix(from, scripted.toEulerDeg ?? from, u))
                    hand = FakeHandSample(side: scripted.side ?? "left", pose: handPose,
                                          isTracked: scripted.tracked ?? true)
                }
                let head = segment.head.map { simd_mix($0, segment.toHead ?? $0, u) }
                samples.append(FakeTrackSample(at: t, pose: emitted,
                                               isTracked: segment.tracked ?? true,
                                               source: source,
                                               surfaceY: segment.surfaceY,
                                               note: k == 0 ? segment.note : nil,
                                               hand: hand,
                                               head: head))
                k += 1
            }
        }
        return samples.sorted { $0.at < $1.at }
    }

    /// The true `objectToScreen` an object segment stands for: the one it writes out, or — when it writes none —
    /// the frame the selected `--fake-box` implies, so the script does not have to know which box it is driving.
    static func objectToScreen(of segment: FakeTrackSegment, box: ObjectScreenFrame.Box) -> simd_float4x4 {
        guard segment.objectOffset == nil, segment.objectOffsetEulerDeg == nil else { return offset(of: segment) }
        return ObjectScreenFrame(box: box).offset(for: ObjectScreenFrame.Flips())
    }

    /// The offset a segment writes out (identity when it writes none).
    static func offset(of segment: FakeTrackSegment) -> simd_float4x4 {
        pose(position: segment.objectOffset ?? .zero, eulerDeg: segment.objectOffsetEulerDeg ?? .zero)
    }

    /// Anchor pose from a position and Euler angles in degrees.
    static func pose(position: SIMD3<Float>, eulerDeg: SIMD3<Float>) -> simd_float4x4 {
        let r = eulerDeg * (.pi / 180)
        let q = simd_quatf(angle: r.z, axis: [0, 0, 1])
            * simd_quatf(angle: r.y, axis: [0, 1, 0])
            * simd_quatf(angle: r.x, axis: [1, 0, 0])
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return m
    }

    /// Deterministic noise: two runs of the same script produce the same stream, so two `[gate] Σ` lines can be
    /// compared directly.
    private struct Noise {
        private var state: UInt64 = 0x5DEECE66D
        mutating func normal() -> Float {
            let u1 = max(1e-7, uniform()), u2 = uniform()
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
        private mutating func uniform() -> Float {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Float(state >> 40) / Float(1 << 24)
        }
    }
}
