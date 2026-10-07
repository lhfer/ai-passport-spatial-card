import Foundation

/// All hologram dimensions in one place (meters, relative to the tracked card's anchor).
///
/// The anchor's origin is the center of the e-paper image; the image lies in the anchor's
/// X-Z plane and +Y is the normal pointing away from the screen. With the device lying flat on
/// a desk, +Y is straight up and +Z points toward the bottom edge of the image (the reader).
enum HologramLayout {
    /// RealityView attachments lay out SwiftUI views in points; visionOS maps 1360 pt to 1 m.
    /// If the glass card and its RealityKit panel visibly disagree in size, tune this number.
    static let pointsPerMeter: Float = 1360

    /// 0.27 m ≈ 367 pt: wide enough for three single-line tag chips in Chinese or English.
    static let cardWidth: Float = 0.27
    static let cardHeight: Float = 0.27
    /// Height of the card's center above the device surface.
    static let cardCenterHeight: Float = 0.22
    /// Small backward tilt so the card reads like it is leaning away from the device.
    static let cardTiltDegrees: Float = -6

    /// Corner radius of the slab's face. Everything that draws a card-shaped outline uses it: the SwiftUI
    /// shape (× `pointsPerMeter`), the tap target, the rim ring and `PixelCloud.frameCornerRadius`.
    static let cardCornerRadius: Float = 0.030
    /// Physical thickness of the frosted slab — a 12 mm acrylic card, not a pane of glass.
    static let cardThickness: Float = 0.012
    /// How far the slab overhangs the SwiftUI card on every side, so the frosted edge and the rim light are
    /// visible even head-on (`BillboardComponent` hides the thickness when the card faces the reader).
    static let slabBorder: Float = 0.006
    /// Outer size / corner radius of the slab: the card plus `slabBorder` all round.
    static var slabWidth: Float { cardWidth + 2 * slabBorder }
    static var slabHeight: Float { cardHeight + 2 * slabBorder }
    static var slabCornerRadius: Float { cardCornerRadius + slabBorder }
    /// Scale of the card when it shrinks into a corner mini-card (worlds, 工作包 C) or rides a carried device.
    static let miniCardScale: Float = 0.35

    /// How bright the light well stays once the card is idle (0…1). The shaft under the device is the strongest
    /// 3D cue on the desk, so it no longer seals at the end of the reveal — only its light dims. 0 restores v1.
    /// `--well-level <0..1>` overrides it: the real LCD is self-lit and may wash the portal out, which is a
    /// judgement that can only be made on the headset.
    static var wellIdleLevel: Float = 0.35

    static let beamBaseHeight: Float = 0.004
    static var beamTopHeight: Float { cardCenterHeight - cardHeight / 2 + 0.01 }

    static let detailWidth: Float = 0.40
    static let detailHeight: Float = 0.50
    static let detailCenterHeight: Float = 0.34

    /// Preview mode: a virtual device ~0.6 m in front of the user, roughly desk height for a seated person.
    static let previewDistance: Float = 0.6
    static let previewSurfaceHeight: Float = 0.95

    /// Device footprint (AI Passport active area, 36.72 mm × 48.96 mm): the single source is
    /// `passport-manifest.json`, written by the hub's `pnpm screens` from `card.json.device.activeAreaMm`.
    static var defaultDeviceSize: SIMD2<Float> { PassportManifest.shared.footprint }

    static func points(_ meters: Float) -> CGFloat {
        CGFloat(meters * pointsPerMeter)
    }
}
