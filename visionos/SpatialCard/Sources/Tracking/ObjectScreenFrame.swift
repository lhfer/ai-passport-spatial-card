import Foundation
import simd

/// Where the **screen** is on the trained object, derived from the object anchor's own bounding box (v3 H1).
///
/// 工作包 G mapped the object tracker into the screen frame by *calibration*: watch both trackers see the same
/// device, average `inverse(object) · image`, and until that converged the card sat on
/// `ObjectScreenCalibration.boundingBoxOffset` — the top face of the box, with no idea which way round the
/// device was. The first Extended device round showed why that is not enough: image tracking was dead for the
/// whole session (0.0/s in 15 of 16 windows), the calibration never converged, and the object source was
/// therefore only ever allowed to place a card that was lying flat. v3 drops the wait: the screen frame is
/// *read off the scan*, so the object source can place the card from its very first observation, in any pose.
///
/// The frame `S` (what everything below `ingest` has always been given: the centre of the screen, +Y its
/// normal, +Z its bottom edge — the image-anchor convention):
///
/// - **normal axis** = `argmin(extent)`. The scan of the AI Passport is a 58.6 × 94 × 5.2 mm slab, so this is
///   expected to be Y — but the axis is *measured*, never assumed, and logged.
/// - **origin** = the centre of that axis' **top** face (`center ± extent/2` along the normal), because the
///   screen is a face of the slab, not its middle.
/// - **+Z** = the longer of the two remaining axes (the screen's long edge — 94 mm here), **+X** = `Y × Z`.
///
/// Two signs cannot be read off a box, because a box is symmetric: which face carries the screen, and which end
/// of the long axis is the bottom. They are decided **once**, from the wearer's head (see `flips(box:…)`),
/// persisted per reference object, and overridable with `--screen-side` / `--screen-yaw`.
///
/// Pure value type over `simd` + `Foundation` (no ARKit): the axis choice, both flips, the composed offset and
/// the persistence round-trip are checked in `ObjectScreenFrameTests` rather than on the wearer's headset.
struct ObjectScreenFrame: Equatable {
    /// `ObjectAnchor.boundingBox`, in the trained object's own frame.
    struct Box: Equatable {
        var center: SIMD3<Float>
        var extent: SIMD3<Float>

        init(center: SIMD3<Float>, extent: SIMD3<Float>) {
            self.center = center
            self.extent = extent
        }

        /// The synthetic box `--fake-track` object segments are mapped through under `--fake-box scan`: the slab
        /// as it was measured *offline* inside the `.referenceobject` (object.usdz), thin axis +Y.
        static let aiPassport = Box(center: .zero, extent: [0.0586, 0.0052, 0.094])

        /// **What the headset actually reports** (2026-09-21 trial, and therefore the `--fake-box` default):
        /// `[obj] box centre (0.0, 0.0, 0.0) mm extent (60.0, 95.0, 8.5) mm`. The runtime `ObjectAnchor.boundingBox`
        /// is **Z-thin** — +Z is the screen normal and +Y the 95 mm long axis — which is a different frame from the
        /// offline usdz analysis above. Anything that assumes "the object's +Y is the screen normal" is wrong on
        /// this box, which is exactly how V3-1 stood the passport on end on the desk (see `TrackingFusion.gravityAligned`).
        static let aiPassportHeadset = Box(center: .zero, extent: [0.060, 0.095, 0.0085])

        /// **v4 B1**: the same Z-thin frame at the case's size **by ruler** (2026-09-25: 60 × 96 × 8 mm) — the
        /// `--fake-track` default, so the simulator exercises the geometry the case frame C is built from. (The
        /// headset's own anchor still reports `aiPassportHeadset`; `--fake-box headset` reproduces it.)
        static let aiPassportMeasured = Box(center: .zero, extent: [0.060, 0.096, 0.008])
    }

    enum Axis: Int, Equatable {
        case x = 0, y = 1, z = 2

        var label: String { self == .x ? "X" : (self == .y ? "Y" : "Z") }

        var unit: SIMD3<Float> {
            switch self {
            case .x: return [1, 0, 0]
            case .y: return [0, 1, 0]
            case .z: return [0, 0, 1]
            }
        }
    }

    /// The two signs a bounding box cannot tell us. `side` appends a 180° rotation about X (the screen is on
    /// the other face); `yaw` appends 180° about Y (the bottom edge is at the other end).
    struct Flips: Equatable {
        var side = false
        var yaw = false

        init(side: Bool = false, yaw: Bool = false) {
            self.side = side
            self.yaw = yaw
        }
    }

    /// Which end of the long axis the head decided on, and how sure the two dot products were — for the log.
    struct Decision: Equatable {
        var flips: Flips
        /// `dot(normal, head − anchor)`, normalised: > 0 = the screen already faces the wearer.
        var headDot: Float
        /// `dot(+Z, reader direction)` (flat) or `dot(+Z, down)` (held up), after the side flip.
        var readerDot: Float
        /// The object's tilt when the decision was taken (rad): ≥ `heldUpTilt` = held up, not lying flat.
        var tilt: Float
    }

    let box: Box
    let axis: Axis
    private(set) var flips: Flips
    /// The flips are the ones a head pose (or a stored record / a flag) actually chose, not the defaults.
    private(set) var isDecided: Bool

    /// Above this tilt the device is being held up rather than lying on a desk, and the "+Z points at the
    /// reader" test is replaced by "+Z points down" (the bottom edge of a screen held up is the low one).
    static let heldUpTilt: Float = 30 * .pi / 180

    init(box: Box, flips: Flips = Flips(), isDecided: Bool = false) {
        self.box = box
        self.axis = ObjectScreenFrame.normalAxis(extent: box.extent)
        self.flips = flips
        self.isDecided = isDecided
    }

    /// **V3-4 §7** `--screen-offset <x mm> <z mm>`, persisted per reference object.
    ///
    /// The object anchor's bounding box gives the *shell's* centre; the LCD is not exactly in the middle of
    /// the shell, and "偶尔有点偏" / "手持时和 LCD 的贴合不精确" is what a systematic 2–3 mm of that looks
    /// like on the headset. There is no way to measure it from the anchor — it is a fact about the physical
    /// device — so it is a number the wearer takes with a ruler (shell top edge → LCD top edge, shell left
    /// edge → LCD left edge) and hands to the app once.
    ///
    /// In metres, in S: +X across the device, +Z toward the reader.
    static var userOffset: SIMD2<Float> = .zero

    /// `UserDefaults` key the measurement is remembered under, per reference object.
    static func offsetDefaultsKey(object: String) -> String { "spatialcard.screenOffset.\(object)" }

    /// The thin axis: the screen's normal. Ties (a cube, a zero extent) go to Y, which is what the trained
    /// AI Passport reports and the convention everything downstream is written against.
    static func normalAxis(extent: SIMD3<Float>) -> Axis {
        let e = SIMD3<Float>(abs(extent.x), abs(extent.y), abs(extent.z))
        guard e.x.isFinite, e.y.isFinite, e.z.isFinite, simd_length(e) > 0 else { return .y }
        if e.y <= e.x && e.y <= e.z { return .y }
        return e.x <= e.z ? .x : .z
    }

    /// The long one of the two axes that are not the normal: the screen's +Z (its bottom edge).
    static func readerAxis(extent: SIMD3<Float>, normal: Axis) -> Axis {
        let others = [Axis.x, .y, .z].filter { $0 != normal }
        let a = others[0], b = others[1]
        return abs(extent[a.rawValue]) >= abs(extent[b.rawValue]) ? a : b
    }

    // MARK: - The mapping

    /// `objectToScreen`: `screenPose = objectPose · offset`.
    var offset: simd_float4x4 { offset(for: flips) }

    func offset(for flips: Flips) -> simd_float4x4 {
        let normal = axis
        let reader = ObjectScreenFrame.readerAxis(extent: box.extent, normal: normal)
        let n = normal.unit
        var z = reader.unit
        var x = simd_cross(n, z)
        // A degenerate box (two equal axes reported as the same one) would give a zero cross product; fall
        // back to any axis perpendicular to the normal rather than emitting a singular matrix.
        if simd_length(x) < 1e-5 {
            z = abs(n.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)
            z = simd_normalize(z - n * simd_dot(n, z))
            x = simd_cross(n, z)
        }
        let s: Float = flips.side ? -1 : 1
        let y: Float = flips.yaw ? -1 : 1
        // side = 180° about X (Y and Z flip), yaw = 180° about Y (X and Z flip); composed in that order.
        let axisY = n * s
        let axisZ = z * (s * y)
        let axisX = simd_normalize(x) * y
        // The screen is a *face* of the slab, so the origin follows the side the normal points at.
        let origin = box.center + n * (s * abs(box.extent[normal.rawValue]) / 2)
        let frame = simd_float4x4(columns: (SIMD4<Float>(axisX.x, axisX.y, axisX.z, 0),
                                            SIMD4<Float>(axisY.x, axisY.y, axisY.z, 0),
                                            SIMD4<Float>(axisZ.x, axisZ.y, axisZ.z, 0),
                                            SIMD4<Float>(origin.x, origin.y, origin.z, 1)))
        // **V3-4 §7.** The measured correction, applied *after* the frame, i.e. in S itself: the whole
        // screen frame slides, so the edge ring, the socket, the hinge, the LCD hard zone and the key glints
        // all move together. Post-multiplying also means the two sign flips above cannot turn a +2 mm
        // correction into a −2 mm one, which is exactly what pre-multiplying would do on a device seen from
        // the other side.
        guard ObjectScreenFrame.userOffset != .zero else { return frame }
        var shift = matrix_identity_float4x4
        shift.columns.3 = SIMD4<Float>(ObjectScreenFrame.userOffset.x, 0, ObjectScreenFrame.userOffset.y, 1)
        return frame * shift
    }

    // MARK: - Deciding the two signs

    /// Both signs, from one tracked observation and the wearer's head.
    ///
    /// **side**: the screen faces the wearer, so `dot(normal_world, head − anchor) < 0` means the frame is
    /// currently pointing away and has to be turned over.
    /// **yaw**: on a device lying flat, the bottom edge (+Z) is the one nearer the reader; on a device held up
    /// (tilt ≥ `heldUpTilt`), the bottom edge is the one pointing down. Either way, a negative dot flips it.
    static func decision(box: Box, objectPose: simd_float4x4, headPosition: SIMD3<Float>) -> Decision {
        let frame = ObjectScreenFrame(box: box)
        let anchor = SIMD3<Float>(objectPose.columns.3.x, objectPose.columns.3.y, objectPose.columns.3.z)
        var toHead = headPosition - anchor
        if simd_length(toHead) < 1e-5 { toHead = [0, 1, 0] }
        toHead = simd_normalize(toHead)

        let unflipped = objectPose * frame.offset(for: Flips())
        let normal = simd_normalize(SIMD3<Float>(unflipped.columns.1.x, unflipped.columns.1.y, unflipped.columns.1.z))
        let headDot = simd_dot(normal, toHead)
        let side = headDot < 0

        // …then the yaw, judged on the frame the side flip actually produced (Rx(π) turns +Z round too).
        let sided = objectPose * frame.offset(for: Flips(side: side, yaw: false))
        let z = simd_normalize(SIMD3<Float>(sided.columns.2.x, sided.columns.2.y, sided.columns.2.z))
        let tilt = ObjectScreenFrame.tilt(of: sided)
        let readerDot: Float
        if tilt < heldUpTilt {
            var horizontal = SIMD3<Float>(toHead.x, 0, toHead.z)
            if simd_length(horizontal) < 1e-4 {
                // The wearer is straight above the device: nothing to read a heading from, keep the frame.
                return Decision(flips: Flips(side: side, yaw: false), headDot: headDot, readerDot: 1, tilt: tilt)
            }
            horizontal = simd_normalize(horizontal)
            readerDot = simd_dot(SIMD3<Float>(z.x, 0, z.z), horizontal)
        } else {
            readerDot = simd_dot(z, SIMD3<Float>(0, -1, 0))
        }
        return Decision(flips: Flips(side: side, yaw: readerDot < 0), headDot: headDot, readerDot: readerDot, tilt: tilt)
    }

    /// Adopt a decision (or a stored / flagged one).
    mutating func adopt(_ flips: Flips) {
        self.flips = flips
        isDecided = true
    }

    /// Angle (rad) between a pose's +Y and world up — the same measure `PresenceGate.tilt` takes, repeated here
    /// so this type stays usable without the gate (and so the test target does not need one to check the other).
    static func tilt(of m: simd_float4x4) -> Float {
        let normal = simd_normalize(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        return acos(max(-1, min(1, simd_dot(normal, SIMD3<Float>(0, 1, 0)))))
    }

    // MARK: - Persistence (`spatialcard.screenFrame.v1.<name>`)

    static let defaultsPrefix = "spatialcard.screenFrame.v1."

    static func defaultsKey(_ referenceObjectName: String) -> String { defaultsPrefix + referenceObjectName }

    /// `[side, yaw]`, so a stored record is readable in `defaults read` and survives a struct change.
    static func encode(_ flips: Flips) -> [Int] { [flips.side ? 1 : 0, flips.yaw ? 1 : 0] }

    static func decode(_ raw: [Int]) -> Flips? {
        guard raw.count == 2, raw.allSatisfy({ $0 == 0 || $0 == 1 }) else { return nil }
        return Flips(side: raw[0] == 1, yaw: raw[1] == 1)
    }

    // MARK: - The log line

    /// `[obj] box centre (…) mm extent (…) mm → normal axis Y; screen side +Y (head·n 0.82), yaw 0 (reader at +Z)`
    /// — one line per anchor, and the only evidence on the headset that the frame was read the right way round.
    ///
    /// **V3-1b:** the reader half of the line used to be hard-coded `±Z`, which is only true for the Y-thin scan
    /// box (there the reader axis really is Z). On the headset's Z-thin box the reader axis is **Y**, and a line
    /// that says `reader at -Z` while the frame reads the 95 mm axis is the one piece of evidence that would have
    /// pointed at the frame mismatch on the first trial. It now names the axis the frame actually reads, with the
    /// sign both flips give it (`side` turns +Z round as well as +Y — it is a 180° rotation about X).
    var readerAxis: Axis { ObjectScreenFrame.readerAxis(extent: box.extent, normal: axis) }

    /// The device's footprint **in the screen frame S**: width along S +X, length along S +Z. Neither flip
    /// changes it (both are 180° rotations, which only swap signs), so it is a property of the box alone.
    /// V3-2a H0 measures the "no virtual geometry on the hardware" prism against exactly this rectangle.
    var screenFootprint: SIMD2<Float> {
        let reader = readerAxis
        let side = [Axis.x, .y, .z].first { $0 != axis && $0 != reader } ?? .x
        return [abs(box.extent[side.rawValue]), abs(box.extent[reader.rawValue])]
    }

    /// How thick the device is along the screen's normal (8.5 mm on the AI Passport). V3-2a2 S1's wireframe
    /// is the box, so it needs the third dimension the footprint drops.
    var screenThickness: Float { abs(box.extent[axis.rawValue]) }

    func describe(decision: Decision?) -> String {
        let c = box.center * 1000, e = box.extent * 1000
        let side = flips.side ? "-\(axis.label)" : "+\(axis.label)"
        let head = decision.map { String(format: "head·n %.2f", $0.headDot) } ?? "no head pose"
        let readerSign = (flips.side != flips.yaw) ? "-" : "+"
        let reader = "reader at \(readerSign)\(readerAxis.label)"
        return String(format: "[obj] box centre (%.1f, %.1f, %.1f) mm extent (%.1f, %.1f, %.1f) mm → normal axis %@; screen side %@ (%@), yaw %d (%@)",
                      c.x, c.y, c.z, e.x, e.y, e.z, axis.label, side, head, flips.yaw ? 180 : 0, reader)
    }
}
