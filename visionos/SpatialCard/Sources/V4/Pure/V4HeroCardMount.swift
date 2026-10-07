import Foundation
import simd

extension V4 {
    /// **v4 B1 §3: where A4's hero card sits in v3's card frame.**
    ///
    /// v3's choreography (the desk rest pose, the pick-up morph onto the hinge, the fold into the device, the mini
    /// card in a world, the billboard) all moves one entity, `cardGroup`, whose origin is the card face's centre with
    /// +Z towards the reader. The hero card is mounted **inside** it rather than replacing it, so every one of those
    /// flows keeps working untouched; this type holds the numbers that change because the card is now a 5 : 7
    /// collectible (0.20 × 0.28 m, 12 mm thick) instead of v3's 0.27 m square.
    ///
    /// Pure (simd + Foundation), so the relations that matter — the card's bottom edge on the hinge, the raised deck
    /// card clear of the taller card, the QR behind the thicker slab, the beam's pool below the type — are unit tests.
    struct HeroCardMount: Equatable {
        /// The card's outer size, thickness and corners (A4's layout: slab = card, front face at z 0).
        let size: SIMD2<Float>
        let thickness: Float
        let cornerRadius: Float
        /// The bottom of the type column's box (A4's `layout.panel.minY`): nothing bright may stand above it.
        let panelBottom: Float

        /// v3's square card, for the deltas the hand deck is measured in (`HandDeckLayout` is struck for it).
        static let v3CardHeight: Float = 0.27

        init(layout: HeroCardLayout) {
            size = layout.size
            thickness = HeroCardLayout.thickness
            cornerRadius = layout.cornerRadius
            panelBottom = layout.panel.minY
        }

        // MARK: The rig's pose vs the card frame

        /// Where v3 rests `cardGroup` in the screen frame S: the card's centre 0.22 m above the screen, leaning back 6°
        /// — the same pose A4's timeline lands on (`HeroCardTimeline.restPose`). The rig writes its pose in S, so the
        /// mount between `cardGroup` and the rig carries the inverse of this.
        static let restHeight: Float = HeroCardLayout.riseHeight
        static let restPitch: Float = HeroCardTimeline().finalPitch

        /// The mount's transform under `cardGroup` (rotation, translation): R(−pitch) · T(−rest height).
        static var inverseRest: (rotation: simd_quatf, translation: SIMD3<Float>) {
            let r = simd_quatf(angle: -restPitch, axis: [1, 0, 0])
            return (r, r.act([0, -restHeight, 0]))
        }

        // MARK: The hand

        /// The card's centre on the hinge arm: its bottom edge on the hinge (the arm's origin), half a card up.
        func hingeCardPosition(handScale: Float) -> SIMD3<Float> { [0, size.y * handScale / 2, 0] }

        /// The card's top edge above the hinge.
        func handTop(handScale: Float) -> Float { size.y * handScale }

        /// How far the whole hand deck is raised so it keeps v3's relation to the (taller) card: its exposed band
        /// above the top edge and the raised card's 5 mm gap (`HandDeckLayout` is written for the 0.27 m card).
        func deckLift(handScale: Float) -> Float { (size.y - Self.v3CardHeight) * handScale }

        // MARK: The card's own furniture (card frame, metres)

        /// The QR back: behind the 12 mm slab **and** A4's opaque shadow caster 0.5 mm behind it, turned round.
        var backZ: Float { -(thickness + 0.0015) }

        /// The beam's landing pool (v3 E2, gold since v4): a soft band along the bottom edge, below the type column
        /// (A4's column ends ≈ 3 mm above its panel's lower edge) and inside the slab. In front of the face, because the
        /// placeholder's frost is opaque.
        var landingSize: SIMD2<Float> { [size.x * 0.8, (panelBottom - (-size.y / 2)) * 0.9] }
        var landingCenter: SIMD3<Float> { [0, (panelBottom + (-size.y / 2)) / 2, 0.003] }

        /// The tap target (v3 keeps it: the card's own pinch, and the mini card's exit from a world).
        var tapSize: SIMD2<Float> { size }
        var tapCollision: SIMD3<Float> { [size.x + 0.01, size.y + 0.01, 0.02] }
        static let tapZ: Float = -0.006

        /// Where the projector's rays land: along the bottom edge, inside the slab (its mid-plane).
        var rayHalfWidth: Float { size.x * 0.46 }
        var rayBottom: Float { -size.y / 2 }
        var rayTargetZ: Float { -thickness / 2 }
        /// The shaft's height (v3: the card's lower edge + 2 cm).
        var shaftHeight: Float { Self.restHeight - size.y / 2 + 0.02 }
    }
}
