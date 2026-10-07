import Foundation
import simd

/// Where the seven cards of the **hand deck** stand (V3-2a H3 / plan §4 E4).
///
/// On the desk the ten recent notes are a gallery in the air. In the hand there is no air to hang them in —
/// the passport is 60 × 95 mm and the card standing on its top edge is 13.5 cm tall — so the five latest
/// notes and the two world cards become *a hand of cards* fanned out behind the name card, with only their
/// tops showing above it. UP / DOWN raises one of them over the card; OK acts on whatever is raised.
///
/// Space: `handPivot`, which sits on the hinge at the device's top edge and is turned so that **+X is right
/// across the card, +Y runs up the card and +Z comes out of its face**. The card's bottom edge is therefore
/// the origin and its top edge is at `cardTop`.
///
/// Pure value type (simd + Foundation) so `HandDeckLayoutTests` can check the one thing that decides whether
/// the fan reads as a hand of cards or as a pile: how much of each card is left showing.
enum HandDeckLayout {
    // MARK: - Shape

    /// The two world cards live at the two ends of the fan; the notes fill the middle.
    static let worldCards = 2
    /// How many recent notes ride in the hand (`HandPager.noteCount` is the hover form's three).
    static let maxNotes = 5
    /// Every slot at its full complement: neon, five notes, nebula.
    static let fullCount = worldCards + maxNotes

    /// Distance from the hinge to a deck card's centre.
    ///
    /// The plan writes 0.115 m *and* "the middle card shows 29 mm above the card's top edge"; with the real
    /// card (`HologramLayout.cardHeight` 0.27 m at `--hand-scale` 0.5 → a top edge 135 mm up) those two
    /// cannot both be true — 0.115 leaves 19 mm. 0.125 reproduces the plan's own 29 mm and clears the
    /// brief's ≥ 25 mm acceptance, so that is the number here.
    static let radius: Float = 0.125
    /// Angle between neighbouring cards.
    static let angleStepDegrees: Float = 12
    static var angleStep: Float { angleStepDegrees * .pi / 180 }
    /// A deck card is 60 % of a gallery card.
    static let slotScale: Float = 0.6
    /// …and 80 % when it is raised over the name card.
    static let raisedScale: Float = 0.8
    /// The fan's depth: every card sits behind the name card, the middle one closest.
    static let baseDepth: Float = -0.008
    static let depthStep: Float = -0.0015
    /// Where a raised card stands: centred, its bottom edge 5 mm above the card's top edge, 4 mm in front.
    static let raisedPosition: SIMD3<Float> = [0, 0.192, 0.004]
    /// One note card, unscaled (the same cover attachment the desk gallery uses).
    static let cardSize: SIMD2<Float> = [0.10, 0.13]
    /// The name card's top edge above the hinge, at `--hand-scale` 0.5 (`cardHeight` 0.27 × 0.5).
    static let cardTop: Float = 0.135
    /// Each card has to show at least this much of itself that its neighbour does not cover, or the fan is a
    /// pile. Measured as the horizontal step between neighbouring cards in the exposed band.
    static let minimumExposedSliver: Float = 0.020

    /// One card's place in the fan.
    struct Slot: Equatable {
        var index: Int
        /// Radians from straight up, positive toward +X (the wearer's right).
        var angle: Float
        var position: SIMD3<Float>
        var scale: Float
        /// The card's in-plane rotation: it leans with its own angle, like a hand of cards.
        var roll: Float { angle }
        /// Top edge of this card, measured up the card's own plane.
        var top: Float { position.y + cardSize.y * scale / 2 }
    }

    // MARK: - Slots

    /// How many cards the deck has with this many notes available: the two world cards plus up to five
    /// notes. A run whose hub has not answered yet is a two-card deck, not an empty one.
    static func count(notes: Int) -> Int { worldCards + min(maxNotes, max(0, notes)) }

    /// Angle of slot `index`, centred on the fan.
    static func angle(index: Int, count: Int) -> Float {
        guard count > 1 else { return 0 }
        return (Float(index) - Float(count - 1) / 2) * angleStep
    }

    static func slot(index: Int, count: Int) -> Slot {
        let theta = angle(index: index, count: count)
        let middle = Float(count - 1) / 2
        let depth = baseDepth + depthStep * abs(Float(index) - middle)
        return Slot(index: index, angle: theta,
                    position: [sin(theta) * radius, cos(theta) * radius, depth],
                    scale: slotScale)
    }

    static func slots(count: Int) -> [Slot] {
        (0..<max(0, count)).map { slot(index: $0, count: count) }
    }

    /// Where the one raised card stands. Its `index` is the slot it came from.
    static func raised(index: Int) -> Slot {
        Slot(index: index, angle: 0, position: raisedPosition, scale: raisedScale)
    }

    // MARK: - The ring

    /// One thing the deck can hold. The profile is not in here: it is the *absence* of a raised card.
    enum Item: Equatable {
        case world(String)
        case note(String)
    }

    /// The deck in slot order, left to right: the first world card, up to five notes, the second world card.
    /// With fewer than two worlds the remaining world card is simply not there and the notes close up.
    static func items(worlds: [String], notes: [String]) -> [Item] {
        let take = Array(notes.prefix(maxNotes)).map(Item.note)
        switch worlds.count {
        case 0: return take
        case 1: return [.world(worlds[0])] + take
        default: return [.world(worlds[0])] + take + [.world(worlds[1])]
        }
    }

    /// The ring UP / DOWN walks: the profile (nothing raised), then every slot left to right, and round.
    static func pages(worlds: [String], notes: [String]) -> [HandPage] {
        [.profile] + items(worlds: worlds, notes: notes).map { item in
            switch item {
            case .world(let id): return HandPage.world(id)
            case .note(let id): return HandPage.note(id)
            }
        }
    }

    /// Which slot a page of the ring occupies (the profile occupies none).
    static func slotIndex(of page: HandPage, worlds: [String], notes: [String]) -> Int? {
        let all = pages(worlds: worlds, notes: notes)
        guard let index = all.firstIndex(of: page), index > 0 else { return nil }
        return index - 1
    }
}
