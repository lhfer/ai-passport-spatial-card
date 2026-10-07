import Foundation
import simd

/// Where the ten recent-note cards stand once they have left the frosted card (工作包 D 笔记扇出).
///
/// Pure value types over `simd` + `Foundation` — no RealityKit (`HologramController+Notes` turns a `Slot` into a
/// `Transform`) — so `SpatialCardTests` can check the one thing that decides whether the row reads as a gallery
/// or as a pile: the distance between neighbouring cards.
///
/// **v2 is a gallery, not a fan.** The 152° single arc put ten 10 cm cards on a 30 cm radius, which is 9.7 cm
/// between neighbouring centres — they overlapped and the titles were cut. The cards now stand **平铺**: two
/// staggered rows of five on a gentle arc, hung in the anchor's −Z half (the reader sits on +Z) so the row
/// floats above and beyond the 0.27 m slab instead of in front of it.
///
/// The arc is struck **around the wearer**, not around the card: both rows are circles of radius ≈ 0.90 m
/// centred on `wearerEstimate`, so every card is the same distance from the eye (covers stay the size they were
/// on the old arc) and "turn to face the wearer" falls out as `yaw = −θ` — the layout needs no head pose to be
/// aimed at one. `Slot.outward` is the radial direction *away from the wearer*, which is the axis a preview's
/// "step back" pushes the other cards along.
enum NoteFanLayout {
    // MARK: - Shape

    /// Cards per row. Ten notes are 5 + 5; a shorter list fills one row until it needs a second.
    static let columnsPerRow = 5
    /// The arc **one row** spans, centred on −Z: 5 columns 8° apart. (v1's `spreadDegrees` was the whole fan.)
    static let spreadDegrees: Float = 32
    /// Where the wearer is assumed to stand, in the fan group's space (= `HologramLayout.previewDistance` in
    /// front of the card, at a seated eye height above the desk). Both rows are struck around this point.
    static let wearerEstimate: SIMD3<Float> = [0, 0.45, 0.60]
    /// Distance from `wearerEstimate` to the front row, and to the back row (0.04 m farther away).
    static let nearRadius: Float = 0.90
    static let farRadius: Float = 0.94
    /// How far above the card's own centre the front row hangs.
    static let riseAboveCard: Float = 0.14
    /// The back row is raised this much: 0.16 m against a 0.13 m card leaves a 3 cm gap between the rows.
    static let rowRise: Float = 0.16
    /// The back row is offset sideways by this fraction of a column (half a card), split ∓ between the rows so
    /// the gallery stays centred on −Z: a brick course, not a grid.
    static let rowStagger: Float = 0.5
    /// Crown of the row: the middle of a row sits this much higher than its ends (`cos` over the row's span).
    static let heightAmplitude: Float = 0.015
    /// Fraction of θ each card turns by. −1 = turned all the way toward `wearerEstimate` (θ is measured from
    /// the wearer, so the card's +Z face looks straight back at them); 0 would be a flat wall of parallel cards.
    /// This is a **yaw**, not a billboard — the row does not follow the head around.
    static let yawFactor: Float = -1
    /// The card's own backward lean (`HologramLayout.cardTiltDegrees`), so the gallery agrees with the slab.
    static let pitchDegrees: Float = -6
    /// Physical size of one note card (136 × 177 pt at 1360 pt/m).
    static let cardSize: SIMD2<Float> = [0.10, 0.13]
    /// The distance neighbouring centres must keep for the gallery not to overlap itself
    /// (`NoteFanLayoutTests`): a 10 cm card plus 1.5 cm of air. Measured spacing is 12.6 / 13.1 cm.
    static let minimumNeighbourDistance: Float = 0.115

    /// The angle between two columns, in radians.
    static var columnStep: Float { (spreadDegrees * .pi / 180) / Float(columnsPerRow - 1) }

    /// One card's place in the gallery, in the space of the fan group (which hangs off the hologram, i.e. the
    /// frozen anchor pose): +X right of the reader, +Y up, −Z away from them.
    struct Slot: Equatable {
        var index: Int
        /// Radians from −Z **as seen from the wearer**, positive toward +X.
        var angle: Float
        /// Distance from `wearerEstimate` (the row's radius), not from the card.
        var radius: Float
        var position: SIMD3<Float>
        var yaw: Float
        var pitch: Float
        /// Which row the card stands in (0 = front and low, 1 = back and high).
        var row: Int = 0

        /// Unit vector from the wearer toward this slot, on the horizontal plane (the direction the "step back"
        /// of a preview pushes the other cards along).
        var outward: SIMD3<Float> { [sin(angle), 0, -cos(angle)] }
    }

    // MARK: - Grid

    /// How many cards stand in one row: everything on one row until the list outgrows it, then split in two.
    static func columns(count: Int) -> Int {
        guard count > columnsPerRow else { return max(1, count) }
        return (count + 1) / 2
    }

    static func rows(count: Int) -> Int { count > columnsPerRow ? 2 : 1 }

    static func row(index: Int, count: Int) -> Int {
        let cols = columns(count: count)
        return cols > 0 ? min(rows(count: count) - 1, index / cols) : 0
    }

    /// θ of card `index` of `count`, in radians (0 = straight back from the wearer, the middle of the gallery).
    static func angle(index: Int, count: Int) -> Float {
        let cols = columns(count: count)
        guard cols > 1 || rows(count: count) > 1 else { return 0 }
        let column = Float(index % max(1, cols))
        let centred = column - Float(cols - 1) / 2
        // ∓ half a stagger per row keeps the pair of rows centred on θ = 0 while offsetting them from each other.
        let stagger = rows(count: count) > 1 ? (row(index: index, count: count) == 0 ? -0.5 : 0.5) * rowStagger : 0
        return (centred + stagger) * columnStep
    }

    static func radius(index: Int, count: Int) -> Float {
        row(index: index, count: count) == 0 ? nearRadius : farRadius
    }

    /// The widest |θ| any card of this list reaches — the scale the crown is measured against.
    static func halfSpan(count: Int) -> Float {
        let cols = columns(count: count)
        let stagger = rows(count: count) > 1 ? rowStagger / 2 : 0
        return (Float(cols - 1) / 2 + stagger) * columnStep
    }

    /// How much higher this card sits than the ends of its row (a `cos` over the row's span, 0 at the ends).
    static func crown(index: Int, count: Int) -> Float {
        let span = halfSpan(count: count)
        guard span > 1e-6 else { return heightAmplitude }
        let u = max(-1, min(1, angle(index: index, count: count) / span))
        return heightAmplitude * cos(u * .pi / 2)
    }

    // MARK: - Slots

    /// The slot of card `index`. `cardCenterHeight` is the hologram card's own centre height
    /// (`HologramLayout.cardCenterHeight`), passed in so this file stays free of the bundle-backed layout.
    static func slot(index: Int, count: Int, cardCenterHeight: Float) -> Slot {
        let theta = angle(index: index, count: count)
        let r = radius(index: index, count: count)
        let rowIndex = row(index: index, count: count)
        let y = cardCenterHeight + riseAboveCard + Float(rowIndex) * rowRise + crown(index: index, count: count)
        // Struck around the wearer: x = r sin θ, z = wearer.z − r cos θ. Both rows stay in the −Z half.
        let ground = SIMD3<Float>(wearerEstimate.x + sin(theta) * r, y, wearerEstimate.z - cos(theta) * r)
        return Slot(index: index, angle: theta, radius: r, position: ground,
                    yaw: theta * yawFactor, pitch: pitchDegrees * .pi / 180, row: rowIndex)
    }

    static func slots(count: Int, cardCenterHeight: Float) -> [Slot] {
        (0..<max(0, count)).map { slot(index: $0, count: count, cardCenterHeight: cardCenterHeight) }
    }
}
