import Foundation

/// Which layout the card attachment shows: the desk card, the shrunken in-world card (工作包 C), or the
/// half-size card that lives on the device while it is in the wearer's hand (v3 H2).
///
/// (Lives here rather than beside the view since **V3-3 C2**: the card is three attachments now, and what
/// the three have to agree on is a pure value the test target can check.)
enum HologramCardMode {
    case full
    case mini
    case hand
}

/// **V3-3 C2 / plan §4 E14b — which sheet of the card this copy draws.**
///
/// The card used to be one RealityView attachment lying 2 mm off the plate. It is three now, mounted at
/// three depths in the card's own frame, so that turning the passport moves the picture against the type
/// the way it moves against a real embossed badge. All three render the *same* `HologramCardView` with the
/// *same* `mode` and `page` — the only difference is which elements this copy draws and which it leaves
/// invisible, so the three sheets have byte-identical geometry and can never drift apart.
///
/// The rule is one sentence: **the hero image floats highest, the chips float in between, the type and the
/// glass stay on the plate.**
enum HologramCardLayer: String, CaseIterable {
    /// The plate itself (glass, frosting, hairline) and all of the type. The only layer that is tappable.
    case base
    /// The hero image slot: the avatar, the world page's coloured disc, the note page's cover. +8 mm.
    case avatar
    /// The capsule row: the tag pills, 「按 OK 进入」, the ♥ count. +4 mm.
    case tags
}

/// **V3-3 C2.** The contract between the RealityView (which mounts the attachments) and the controller
/// (which mounts their holders): three sheets, three ids, three depths — and one mode.
///
/// It is a value type on purpose. "Every layer gets the same mode" is the invariant that keeps the card from
/// showing its desk avatar over its hand-sized type during a pick-up, and an invariant that is only
/// *written down in two places that look alike* is one review away from breaking. Here it is a fact about
/// one function, which `CardLayerTests` states outright and `ImmersiveView` obeys by iterating it.
enum CardLayers {
    /// Where the base sheet sits: 2 mm off the plate, exactly where the single attachment has always been.
    static let baseZ: Float = 0.002
    /// How far the hero image and the capsules stand off it, in the card's own frame — so the hand card's
    /// 0.5 scale halves them on screen, as it does every other dimension of the card.
    static let avatarLift: Float = 0.008
    static let tagsLift: Float = 0.004

    static let baseAttachmentID = "card"
    static let avatarAttachmentID = "card.avatar"
    static let tagsAttachmentID = "card.tags"
    /// **C3**: the fourth attachment, on the other side of the plate. Not one of the `sheets` — it is not a
    /// parallax layer, it is the card's back.
    static let backAttachmentID = "card.back"

    /// One mounted sheet of the card's face.
    struct Sheet: Equatable {
        var id: String
        var layer: HologramCardLayer
        /// The same for all three, by construction — see the type's note.
        var mode: HologramCardMode
        /// Depth in the card's own frame.
        var z: Float
        /// Only the plate catches a pinch; sheets in front of it would steal every tap meant for the card.
        var tappable: Bool
        /// `--parallax off`: the same for all three. Off, the base sheet draws the whole card and the other
        /// two draw nothing — see `HologramCardView.parallax` for why that beats a partition at z 0.
        var parallax: Bool
    }

    /// How far off the plate a sheet sits. `--parallax off` collapses all three onto the base z, which is
    /// V3-2b's single attachment, pixel for pixel.
    static func lift(_ layer: HologramCardLayer, parallax: Bool = true) -> Float {
        guard parallax else { return 0 }
        switch layer {
        case .base: return 0
        case .avatar: return avatarLift
        case .tags: return tagsLift
        }
    }

    static func z(_ layer: HologramCardLayer, parallax: Bool = true) -> Float {
        baseZ + lift(layer, parallax: parallax)
    }

    static func attachmentID(_ layer: HologramCardLayer) -> String {
        switch layer {
        case .base: return baseAttachmentID
        case .avatar: return avatarAttachmentID
        case .tags: return tagsAttachmentID
        }
    }

    /// The three sheets one card is made of, in back-to-front order.
    static func sheets(mode: HologramCardMode, parallax: Bool = true) -> [Sheet] {
        [HologramCardLayer.base, .tags, .avatar].map { layer in
            Sheet(id: attachmentID(layer), layer: layer, mode: mode,
                  z: z(layer, parallax: parallax), tappable: layer == .base, parallax: parallax)
        }
    }

    /// **C3**: where the back sits — 1 mm behind the slab's own z (the plan's `−0.007 − 0.001`).
    static let backZ: Float = -0.008
}

/// **V3-3 C3 / plan §4 E14c.** Which side of the card the wearer is looking at, decided from the one number
/// the angle tick already has: `dot(card normal, direction to the eyes)`.
///
/// Hysteresis rather than a threshold, and the reason is physical. A passport held edge-on sits at a dot of
/// ≈ 0 with the wearer's own pulse moving it a few degrees either way; a single threshold there would
/// cross-fade the card's two faces at 3 Hz. So the back needs the card to be pointing **more than 100°**
/// away before it comes up (cos 100° = −0.174) and the front needs it back inside **≈ 93°** before it
/// returns — 7° of dead band, which is more than a hand shakes and less than a wrist turns.
struct BackFaceFlip: Equatable {
    /// cos 100°, rounded the safe way.
    static let enter: Float = -0.17
    /// cos ≈ 93°.
    static let leave: Float = -0.05

    private(set) var showsBack = false

    enum Change: Equatable {
        case toBack
        case toFront
    }

    /// One frame. Returns a change only when the side actually flipped — which is what makes
    /// `[reveal] back face` print **once per flip** rather than once per frame.
    mutating func update(facing dot: Float) -> Change? {
        guard dot.isFinite else { return nil }
        if !showsBack, dot < BackFaceFlip.enter {
            showsBack = true
            return .toBack
        }
        if showsBack, dot > BackFaceFlip.leave {
            showsBack = false
            return .toFront
        }
        return nil
    }

    /// The card has been squared away (a fold, a world, a reveal): whatever it was showing, it comes back
    /// on its front. Returns `.toFront` only if it was actually on its back, so the log stays paired.
    mutating func reset() -> Change? {
        guard showsBack else { return nil }
        showsBack = false
        return .toFront
    }
}
