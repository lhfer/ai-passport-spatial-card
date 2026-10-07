import Foundation
import RealityKit
import UIKit

/// **The name card's material stack** (A1's recommendation, ready to replace v3's `slab` + `rim`):
/// a CrystalSlab plate, the HoloFoil over the card face and the GoldEdge line, in the v3 card frame — `root` is
/// the card's centre, +Z towards the reader, the slab's front face at z −1 mm exactly where v3's rim draws, so the
/// SwiftUI sheets (+2 … +10 mm) keep floating in front of it unchanged.
///
/// Four entities, three materials, no per-frame allocation: `setSweep`, `setReveal`, … only change parameter values,
/// and `commit()` pushes the ones that changed (a reveal swaps the slab's *preloaded* material at its two ends).
@MainActor
final class NameCardMaterialStack {
    struct Geometry {
        var slabSize: SIMD2<Float>
        var slabCornerRadius: Float
        var thickness: Float
        var cardSize: SIMD2<Float>
        var cardCornerRadius: Float

        /// `HologramLayout`'s name card: 0.27 m card, 6 mm border, 30 mm corners, 12 mm thick.
        static let nameCard = Geometry(slabSize: [0.282, 0.282], slabCornerRadius: 0.036, thickness: 0.012,
                                       cardSize: [0.27, 0.27], cardCornerRadius: 0.030)
    }

    let root = Entity()
    let slab: ModelEntity
    let foil: ModelEntity
    let edge: ModelEntity
    let geometry: Geometry

    private(set) var crystal: CrystalSlabMaterial
    private(set) var dissolve: MagicDissolveMaterial
    private(set) var foilMaterial: HoloFoilMaterial
    private(set) var edgeMaterial: GoldEdgeMaterial
    /// nil = the card is whole (the slab renders CrystalSlab); a value = mid-reveal (MagicDissolve at that progress).
    private(set) var reveal: Float?
    private var dirty: (slab: Bool, foil: Bool, edge: Bool) = (true, true, true)

    /// Depths in the card frame (v3: slab centre −7 mm, so its front face is at −1 mm).
    static let slabZ: Float = -0.007
    static let foilZ: Float = -0.0007
    static let edgeZ: Float = -0.0005

    static func make(_ geometry: Geometry = .nameCard, sortGroup: ModelSortGroup = ModelSortGroup(depthPass: nil),
                     firstOrder: Int32 = 0) async throws -> NameCardMaterialStack {
        var crystal = try await CrystalSlabMaterial.load()
        var dissolve = try await MagicDissolveMaterial.load()
        var foil = try await HoloFoilMaterial.load()
        var edge = try await GoldEdgeMaterial.load()
        let slabHalf = geometry.slabSize / 2
        crystal.setOutline(halfSize: slabHalf, cornerRadius: geometry.slabCornerRadius)
        crystal.setThickness(geometry.thickness)
        dissolve.setOutline(halfSize: slabHalf, cornerRadius: geometry.slabCornerRadius)
        dissolve.setThickness(geometry.thickness)
        foil.setHalfSize(geometry.cardSize / 2)
        foil.setStrength(restFoilStrength)
        edge.setOutline(halfSize: slabHalf, cornerRadius: geometry.slabCornerRadius)
        return NameCardMaterialStack(geometry: geometry, crystal: crystal, dissolve: dissolve, foilMaterial: foil,
                                     edgeMaterial: edge, sortGroup: sortGroup, firstOrder: firstOrder)
    }

    private init(geometry: Geometry, crystal: CrystalSlabMaterial, dissolve: MagicDissolveMaterial,
                 foilMaterial: HoloFoilMaterial, edgeMaterial: GoldEdgeMaterial, sortGroup: ModelSortGroup, firstOrder: Int32) {
        self.geometry = geometry
        self.crystal = crystal
        self.dissolve = dissolve
        self.foilMaterial = foilMaterial
        self.edgeMaterial = edgeMaterial
        slab = ModelEntity(mesh: MagicMeshes.slab(width: geometry.slabSize.x, height: geometry.slabSize.y,
                                                  depth: geometry.thickness, radius: geometry.slabCornerRadius),
                           materials: [crystal.material])
        foil = ModelEntity(mesh: MagicMeshes.roundedPlane(width: geometry.cardSize.x, height: geometry.cardSize.y,
                                                          radius: geometry.cardCornerRadius),
                           materials: [foilMaterial.material])
        // 7 mm in (the 1.5 mm inset, the ~1 mm line, its halo), 6 mm out (the light spilling past the outline).
        edge = ModelEntity(mesh: MagicMeshes.goldEdgeRing(width: geometry.slabSize.x, height: geometry.slabSize.y,
                                                          radius: geometry.slabCornerRadius),
                           materials: [edgeMaterial.material])
        root.name = "v4.nameCardStack"
        slab.name = "v4.card.slab"
        foil.name = "v4.card.foil"
        edge.name = "v4.card.edge"
        slab.position = [0, 0, Self.slabZ]
        foil.position = [0, 0, Self.foilZ]
        edge.position = [0, 0, Self.edgeZ]
        // Back to front: plate, foil, line. (The caller's SwiftUI sheets come after `firstOrder + 2`.)
        slab.components.set(ModelSortGroupComponent(group: sortGroup, order: firstOrder))
        foil.components.set(ModelSortGroupComponent(group: sortGroup, order: firstOrder + 1))
        edge.components.set(ModelSortGroupComponent(group: sortGroup, order: firstOrder + 2))
        // Only the magic light blooms (bible §2); the plate's own light stays below 1.
        edge.components.set(BloomComponent(scope: .hierarchical))
        root.addChild(slab)
        root.addChild(foil)
        root.addChild(edge)
    }

    // MARK: Parameters

    /// The diagonal sweep, shared by the glass glint, the foil and the gold line so they read as one light crossing
    /// the card (bible §2: every 8–12 s).
    func setSweep(_ sweep: Float) {
        crystal.setSweep(sweep)
        foilMaterial.setSweep(sweep)
        edgeMaterial.setSweep(sweep)
        dirty.slab = reveal == nil || dirty.slab
        dirty.foil = true
        dirty.edge = true
    }

    /// The foil at rest. 1 = its full angle cap (≤ 0.12 square-on, ≤ 0.45 edge-on): since the 2026-09-26 review the
    /// foil is a pastel sheen that is quiet square-on by construction, so it no longer needs holding back — on the
    /// pale crystal anything lower disappears.
    private(set) var foilStrength: Float = NameCardMaterialStack.restFoilStrength
    static let restFoilStrength: Float = 1
    /// The gold line at rest.
    private(set) var edgeIntensity: Float = 1

    func setFoilStrength(_ strength: Float) {
        foilStrength = strength
        foilMaterial.setStrength(reveal.map { V4.MagicMaterialRules.revealFoilStrength($0) * strength } ?? strength)
        dirty.foil = true
    }

    func setEdgeIntensity(_ intensity: Float) {
        edgeIntensity = intensity
        edgeMaterial.setIntensity(reveal.map { V4.MagicMaterialRules.revealEdgeIntensity($0) * intensity } ?? intensity)
        dirty.edge = true
    }

    func setSlabOpacity(_ opacity: Float) {
        crystal.setOpacity(opacity)
        dissolve.setOpacity(opacity)
        dirty.slab = true
    }

    func setRim(facing: Float, grazing: Float) {
        crystal.setRimFacing(facing)
        crystal.setRimGrazing(grazing)
        dissolve.setRim(facing: facing, grazing: grazing)
        dirty.slab = true
    }

    /// A world's colour reaches the rim only (v3 rule), blended over the warm white.
    func setRimColor(_ color: UIColor) {
        crystal.setRimColor(color)
        dissolve.setRimColor(color)
        dirty.slab = true
    }

    /// The reveal: `progress` 0…1 fills the plate from its outline inward (MagicDissolve) while the line and the foil
    /// come up behind the front; nil (or 1) is the finished card. Swaps the slab between two preloaded materials only
    /// when crossing into / out of a reveal.
    func setReveal(_ progress: Float?) {
        let clamped = progress.map { min(1, max(0, $0)) }
        let finished = clamped == nil || clamped == 1
        if finished {
            if reveal != nil { dirty.slab = true }
            reveal = nil
            edgeMaterial.setIntensity(edgeIntensity)
            foilMaterial.setStrength(foilStrength)
        } else if let p = clamped {
            if reveal == nil { dirty.slab = true }
            reveal = p
            dissolve.setProgress(p)
            dirty.slab = true
            // The line arrives with the last third of the fill, the foil after it.
            edgeMaterial.setIntensity(V4.MagicMaterialRules.revealEdgeIntensity(p) * edgeIntensity)
            foilMaterial.setStrength(V4.MagicMaterialRules.revealFoilStrength(p) * foilStrength)
        }
        dirty.foil = true
        dirty.edge = true
    }

    /// The bible's idle sweep (one every 8–12 s, seeded): call once per frame while the card rests, then `commit()`.
    /// A caller that choreographs its own sweep (a reveal flourish, the lab's 3 s cycle) uses `setSweep` instead.
    var idleSweep = V4.SweepSchedule()

    func advanceIdle(by dt: Float) {
        setSweep(idleSweep.advance(by: Double(dt)))
    }

    /// Pushes changed materials to their entities; call once per frame after the setters.
    func commit() {
        if dirty.slab {
            if reveal != nil { dissolve.commit(to: slab) } else { crystal.commit(to: slab) }
        }
        if dirty.foil { foilMaterial.commit(to: foil) }
        if dirty.edge { edgeMaterial.commit(to: edge) }
        dirty = (false, false, false)
    }
}
