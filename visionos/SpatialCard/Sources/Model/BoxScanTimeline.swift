import Foundation
import simd

/// **The recognition scan's clock** (V3-2a2 S1 / plan §4 E1).
///
/// The first time the passport is seen — and again on every summon — twelve light rods are drawn along the
/// real shell's own edges, a bright band sweeps the long axis, and the wireframe then contracts onto the
/// screen rectangle and hands over to the card's entrance. The *when* of all that is here, as a pure value
/// type, because three separate things have to agree on it: the rig that draws the edges, the BLE `glow`
/// that has to reach the real LCD while the virtual band is over it, and the entrance that must not start
/// before the convergence beat.
///
/// Times are seconds from the start of the scan.
///
/// | beat | full (first detection) | summon |
/// | --- | --- | --- |
/// | edges drawn in | 0 → 0.25 | 0 → 0.12 |
/// | band sweeps +Z → −Z | 0.20 → 0.80 | 0.15 → 0.40 |
/// | `glow sweep` to the device | 0.35 | 0.15 |
/// | wireframe contracts onto the screen | 0.80 → 1.05 | 0.40 → 0.60 |
/// | **convergence** (chip, device cue, entrance) | 1.05 | 0.60 |
/// | rig gone | 1.20 | 0.60 |
struct BoxScanTimeline: Equatable {
    /// The whole 1.2 s version (a first detection), or the 0.6 s one (a summon).
    var full: Bool

    init(full: Bool) { self.full = full }

    static let fullVersion = BoxScanTimeline(full: true)
    static let summonVersion = BoxScanTimeline(full: false)

    /// Between neighbouring edges as they are drawn in.
    static let edgeStagger: Float = 0.020
    /// How bright a drawn edge sits at, and how bright it flashes when the band crosses it.
    static let edgeLevel: Float = 0.85
    static let edgeFlashLevel: Float = 1.0
    static let edgeFlashDuration: Float = 0.1

    /// The last edge has finished being drawn.
    var edgesIn: Float { full ? 0.25 : 0.12 }
    var bandStart: Float { full ? 0.20 : 0.15 }
    var bandEnd: Float { full ? 0.80 : 0.40 }
    /// When the `glow` line goes out over BLE. One trip is ≈ 60 ms, so the real LCD's own bar runs from
    /// ≈ 0.41 s — inside the 0.40–0.60 s window in which the virtual band is over the screen rectangle.
    var glowAt: Float { full ? 0.35 : 0.15 }
    var contractStart: Float { bandEnd }
    /// **The convergence beat**: the socket light is up, the well is open, and the entrance may start.
    var converge: Float { full ? 1.05 : 0.60 }
    /// How long the whole rig is on screen (the fade-out outlives the beat in the full version).
    var total: Float { full ? 1.20 : 0.60 }
    /// How long the socket ring and the light well take to come up under the contracting wireframe.
    var handover: Float { 0.15 }
    /// The label the log uses.
    var label: String { full ? String(format: "%.1f s", total) : String(format: "summon, %.1f s", total) }

    // MARK: - The band

    /// Where the sweeping band stands at `t`, along S +Z: it starts on the reader edge (+length/2) and runs
    /// to the top edge (−length/2), easeInOutCubic.
    func bandZ(at t: Float, length: Float) -> Float {
        let half = length / 2
        guard t > bandStart else { return half }
        guard t < bandEnd else { return -half }
        let raw = (t - bandStart) / max(0.001, bandEnd - bandStart)
        return half - Easing.easeInOutCubic.apply(raw) * length
    }

    /// When the band crosses this z (nil when it never does). The four vertical edges use it for their
    /// 0.1 s flash.
    func bandCrosses(z: Float, length: Float) -> Float? {
        let half = length / 2
        guard z <= half + 1e-6, z >= -half - 1e-6 else { return nil }
        let eased = max(0, min(1, (half - z) / max(0.0001, length)))
        // easeInOutCubic is monotonic: invert it by bisection, which is exact enough for a 0.1 s flash and
        // keeps this file free of a cube-root special case.
        var lo: Float = 0, hi: Float = 1
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            if Easing.easeInOutCubic.apply(mid) < eased { lo = mid } else { hi = mid }
        }
        return bandStart + (lo + hi) / 2 * (bandEnd - bandStart)
    }

    // MARK: - The twelve edges

    /// One rod of the wireframe, in the screen frame S (origin = the top face's centre, +Y the screen
    /// normal, +Z the reader edge).
    struct Edge: Equatable {
        enum Along: Equatable { case x, y, z }
        var along: Along
        /// Midpoint in S.
        var mid: SIMD3<Float>
        var length: Float
    }

    /// The twelve edges of the anchor box, in a fixed order: the four that run across the device (top face
    /// first), the four that run along it, then the four vertical ones at the corners.
    static func edges(width: Float, length: Float, thickness: Float) -> [Edge] {
        let hw = width / 2, hl = length / 2
        var list: [Edge] = []
        for y in [Float(0), -thickness] {
            for z in [-hl, hl] {
                list.append(Edge(along: .x, mid: [0, y, z], length: width))
            }
        }
        for y in [Float(0), -thickness] {
            for x in [-hw, hw] {
                list.append(Edge(along: .z, mid: [x, y, 0], length: length))
            }
        }
        for x in [-hw, hw] {
            for z in [-hl, hl] {
                list.append(Edge(along: .y, mid: [x, -thickness / 2, z], length: thickness))
            }
        }
        return list
    }

    /// The corner the wireframe is drawn *from*: the reader edge (+Z) on the wearer's right, on the top
    /// face. Everything else is staggered by how far its midpoint is from it, so the outline appears to run
    /// out of the corner nearest the reader.
    static func readerCorner(width: Float, length: Float) -> SIMD3<Float> {
        [width / 2, 0, length / 2]
    }

    /// Edge indices in the order they are drawn: nearest the reader corner first, ties by index.
    static func drawOrder(width: Float, length: Float, thickness: Float) -> [Int] {
        let corner = readerCorner(width: width, length: length)
        let list = edges(width: width, length: length, thickness: thickness)
        return list.indices.sorted { a, b in
            let da = simd_length(list[a].mid - corner), db = simd_length(list[b].mid - corner)
            if abs(da - db) > 1e-6 { return da < db }
            return a < b
        }
    }

    /// How long edge `index` waits before it is drawn.
    static func drawDelay(index: Int, width: Float, length: Float, thickness: Float) -> Float {
        let order = drawOrder(width: width, length: length, thickness: thickness)
        guard let rank = order.firstIndex(of: index) else { return 0 }
        return Float(rank) * edgeStagger
    }

    // MARK: - The entrance the scan is holding

    /// What the card was about to do when the scan started. On the headset `acquiring → carrying` follows
    /// the first detection by 34 ms, so without this the unfold would run *underneath* the wireframe.
    enum Intro: String, Equatable {
        case cinematic
        case reentry
        case unfold
    }

    /// A presence transition arriving while a scan is running.
    enum Arrival: Equatable {
        case intro(Intro)
        /// The pose was lost: the scan is anchored to the frozen pose and simply finishes there.
        case freeze
        /// The card is going away: the wireframe fades and whatever was held is dropped.
        case hide

        /// The entrance this arrival carries, if it is one.
        var intro: Intro? {
            guard case .intro(let value) = self else { return nil }
            return value
        }
    }

    enum Verdict: Equatable {
        /// Do not run it now — the convergence beat will.
        case hold
        /// Run it now; the scan is unaffected.
        case pass
        /// Fade the wireframe out and forget the held entrance.
        case drop
    }

    /// The scan's memory of the entrance it is holding back.
    struct Pending: Equatable {
        private(set) var intro: Intro?

        init(intro: Intro? = nil) { self.intro = intro }

        mutating func handle(_ arrival: Arrival) -> Verdict {
            switch arrival {
            case .intro(let value):
                // The latest one wins: a `.carry` that overtakes a `.cinematic` is where the card is going.
                intro = value
                return .hold
            case .freeze:
                return .pass
            case .hide:
                intro = nil
                return .drop
            }
        }

        /// The convergence beat takes it, once.
        mutating func take() -> Intro? {
            defer { intro = nil }
            return intro
        }
    }
}
