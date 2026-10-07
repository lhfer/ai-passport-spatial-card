import Foundation
import simd

/// **The V3-2a H0 rule, made measurable.**
///
/// The final deliverable is a video of a real device, so the one thing no state may do is bury the hardware:
/// *no persistent virtual geometry inside the device's footprint, in any state* (desk, hand, folded, world).
/// The footprint is the object anchor's box expressed in the screen frame S (`anchorRoot`) — x ±width/2,
/// z ±length/2 — grown by a 3 mm margin, and the volume the rule protects is the prism over that rectangle
/// from y −0.02 to y +0.03 (2 cm into the device, 3 cm of air above its screen).
///
/// **V3-2a2 S0** splits that rectangle in two. The card now hinges on the device's top edge itself
/// (`hingeClearance` 0), and its 12 mm slab overhangs the hinge by ~3 mm — which lands over the device's top
/// *bezel*, 23 mm of dark plastic above the LCD. Burying 3 mm of bezel is not burying the hardware, so:
///
/// - the **LCD hard zone** (36.7 × 49 mm centred, + the same margin) takes nothing, ever, except the timed
///   FX the rule exempts by name;
/// - the **bezel soft zone** (the rest of the footprint) takes the hinged card's overhang and nothing else.
///
/// Pure value type, so `FootprintAuditTests` can check the geometry without a RealityKit scene.
///
/// **v4 B1: the frame is the case's.** The rectangle is the *case* (x ±width/2, z ±length/2 around the case
/// frame C's origin) and the LCD hard zone sits at `lcdCenter` inside it — the lit area is 11.5 mm off the case's
/// middle on the real AI Passport (`V4.ScreenOffset`). With `lcdCenter` zero this is exactly v3's single frame.
struct DeviceFootprint: Equatable {
    /// The device's full width (along +X) and length (along +Z), in metres.
    var size: SIMD2<Float>
    /// The **screen's** active area inside that rectangle (36.7 × 49 mm on the AI Passport), centred on
    /// `lcdCenter`. Nothing persistent is tolerated over it in any state — this is the part of the device the
    /// camera has to be able to read.
    var lcd: SIMD2<Float> = [0.0367, 0.049]
    /// Where the LCD's lit area is centred relative to the case's centre (x across, z along), metres —
    /// `V4.ScreenOffset`. Zero = v3's "the screen is the middle of the case".
    var lcdCenter: SIMD2<Float> = .zero
    /// Grown on every side of the rectangle before the test (the brief's 3 mm).
    var margin: Float = 0.003
    /// How far into the device the prism reaches.
    var yMin: Float = -0.02
    /// How far above the screen it reaches.
    var yMax: Float = 0.03

    /// The AI Passport's case by ruler (v4, 2026-09-25): 60 × 96 mm (8 mm thick). The headset's
    /// `ObjectAnchor.boundingBox` says 60 × 95 × 8.5; whenever an anchor has been seen its own box still wins
    /// (`HologramController.setDeviceFootprint`), this is the default until then (`--preview`, image tracking).
    static let aiPassport = DeviceFootprint(size: [0.060, 0.096])

    /// Half extent of the protected rectangle, margin included.
    var half: SIMD2<Float> { [size.x / 2 + margin, size.y / 2 + margin] }

    /// Half extent of the LCD hard zone, same margin.
    var lcdHalf: SIMD2<Float> { [lcd.x / 2 + margin, lcd.y / 2 + margin] }

    /// Where the device's top edge is (the hinge's own z): −length/2, **without** the margin, because the
    /// hinge is placed on the real edge and the overhang is measured from it.
    var topEdgeZ: Float { -size.y / 2 }

    /// Axis-aligned overlap between the **LCD hard zone**'s prism and a box given in the case frame.
    func intersectsLCD(min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> Bool {
        let h = lcdHalf, c = lcdCenter
        return lo.x <= c.x + h.x && hi.x >= c.x - h.x
            && lo.z <= c.y + h.y && hi.z >= c.y - h.y
            && lo.y <= yMax && hi.y >= yMin
    }

    /// **The bezel soft zone's one tolerance** (S0): a shape hinged on the device's top edge may hang this
    /// far back over the bezel and no further, and may not reach the LCD hard zone at all.
    ///
    /// `lo` / `hi` are the shape's axis-aligned bounds in S. It is *tolerated* when everything of it that is
    /// inside the prism at all lies within `maxDepth` of the top edge — i.e. the card really is standing on
    /// the hinge rather than lying over the screen. V3-1's 35 mm hover form reaches z ≈ +67 mm and is caught
    /// by exactly this test, which is what the oracle A/B proves.
    func toleratesOverhang(min lo: SIMD3<Float>, max hi: SIMD3<Float>, maxDepth: Float) -> Bool {
        guard !intersectsLCD(min: lo, max: hi) else { return false }
        return hi.z <= topEdgeZ + maxDepth
    }

    /// The four corners of the protected rectangle, at the given height.
    func corners(y: Float) -> [SIMD3<Float>] {
        let h = half
        return [[-h.x, y, -h.y], [h.x, y, -h.y], [h.x, y, h.y], [-h.x, y, h.y]]
    }

    func contains(_ p: SIMD3<Float>) -> Bool {
        let h = half
        return abs(p.x) <= h.x && abs(p.z) <= h.y && p.y >= yMin && p.y <= yMax
    }

    /// Axis-aligned overlap between the prism and a box given in S.
    func intersects(min lo: SIMD3<Float>, max hi: SIMD3<Float>) -> Bool {
        let h = half
        return lo.x <= h.x && hi.x >= -h.x
            && lo.z <= h.y && hi.z >= -h.y
            && lo.y <= yMax && hi.y >= yMin
    }

    /// Half the diagonal of the protected rectangle: the radius a round hole has to beat to clear it.
    var cornerRadius: Float { simd_length(half) }

    /// Does the protected rectangle fit through a clear opening of this half extent, centred on S?
    ///
    /// A ring, an annulus or a lofted shell has no geometry over the middle at all, so an axis-aligned box
    /// test — which is all `visualBounds` can give — would report every one of them as "inside" forever. A
    /// shape that declares its opening is judged on the opening instead: it is inside only when the footprint
    /// does **not** fit through it.
    func fitsThrough(hole: SIMD2<Float>) -> Bool {
        fitsThrough(hole: hole, center: .zero)
    }

    /// **v4 B1.** The same, for an opening centred at `center` (x, z) instead of on the frame's origin. Once the
    /// case and the screen are two frames, a hollow shape is no longer guaranteed to be centred where the prism
    /// is — the desk halo stands under the screen, the socket ring around the case — so the audit asks where the
    /// shape actually is: the opening has to contain the whole protected rectangle.
    func fitsThrough(hole: SIMD2<Float>, center: SIMD2<Float>) -> Bool {
        let h = half
        return center.x - hole.x <= -h.x && center.x + hole.x >= h.x
            && center.y - hole.y <= -h.y && center.y + hole.y >= h.y
    }

    /// Does a round opening of this radius, centred at `center` (x, z), clear the protected rectangle? Every
    /// corner has to be inside the circle (the rectangle is convex, so its corners are its farthest points).
    func fitsThrough(circularHole radius: Float, center: SIMD2<Float>) -> Bool {
        corners(y: 0).allSatisfy { simd_length(SIMD2<Float>($0.x, $0.z) - center) <= radius }
    }

    /// Is a height inside the prism's slab of air (a hollow shape lying elsewhere — the desk halo under a
    /// passport held in the air — cannot be burying the device)?
    func containsHeight(_ y: Float) -> Bool { y >= yMin && y <= yMax }
}
