import Foundation
import RealityKit
import UIKit

/// **A1's half of A4's `CardSurfaceStyle`** (branch v4/a4-card, `Sources/V4/Card/CardSurfaceStyle.swift`).
///
/// A4's hero card owns the geometry — `HeroCardSurface` holds five entities in the card frame (origin at the centre of
/// the slab's front face, +Z to the reader): `slab`, `rim`, `goldLine`, `foil` (over the opaque midnight panel) and
/// `sweep` — and asks a style for materials once (`apply(to:)`) and for parameters every frame
/// (`update(_:facing:viewInCard:sweep:)`). This class is that style's body, written against plain entities so it
/// compiles on the A1 branch; the adapter on A4's side is the short `MagicCardSurfaceStyle` quoted in the A1 report
/// (§7). What it does with the five:
///
/// - `slab` → CrystalSlab (frosted, edge light and Fresnel computed per pixel, grounding shadow kept).
/// - `rim` → hidden (`OpacityComponent` 0): the edge light already lives in CrystalSlab.
/// - `goldLine` → its mesh becomes `MagicMeshes.goldEdgeRing` (A4's `roundedRectRing` winds clockwise, which a
///   back-culled material never draws) and GoldEdge draws the 1.5 mm-inset line, its halo and the spill past the edge.
/// - `foil` → HoloFoil sized to the panel (pastel, capped by angle in the graph).
/// - `sweep` → SweepGlint (the panel is opaque, so the slab's own glint would be hidden under it).
///
/// Per frame only the sweep changes: the angle (`facing`) and the eye's direction (`viewInCard`) that A4 computes on
/// the CPU are evaluated per pixel on the GPU here, so they are not needed.
@MainActor
final class MagicCardSurfaceMaterials {
    struct Outline {
        /// The slab's outer size, corner radius and thickness (A4: `layout.size`, `layout.cornerRadius`,
        /// `HeroCardLayout.thickness`).
        var size: SIMD2<Float>
        var cornerRadius: Float
        var thickness: Float
        /// The rectangle the foil entity covers, centred on it (A4: `layout.panel` width × height, `panelCornerRadius`).
        var foilSize: SIMD2<Float>
        var foilCornerRadius: Float
        /// The sweep plane's size (A4: the slab inset by the gold line on each side, corner `cornerRadius − goldInset`).
        var sweepSize: SIMD2<Float>
        var sweepCornerRadius: Float
        /// The gold line (A4: `HeroCardLayout.goldInset` 1.5 mm, `goldWidth` 1 mm).
        var goldInset: Float
        var goldWidth: Float
    }

    private(set) var crystal: CrystalSlabMaterial
    private(set) var foil: HoloFoilMaterial
    private(set) var edge: GoldEdgeMaterial
    private(set) var glint: SweepGlintMaterial
    /// The foil at rest, under its angle cap. 0.5 here (1 on the pale name-card stack): over A4's opaque midnight panel
    /// any additive light reads strongly — A4's own placeholder settled at 0.45 of the same curve for that reason.
    var foilStrength: Float = 0.5
    private var lastSweep: Float = .nan

    private init(crystal: CrystalSlabMaterial, foil: HoloFoilMaterial, edge: GoldEdgeMaterial, glint: SweepGlintMaterial) {
        self.crystal = crystal
        self.foil = foil
        self.edge = edge
        self.glint = glint
    }

    static func make() async throws -> MagicCardSurfaceMaterials {
        MagicCardSurfaceMaterials(crystal: try await CrystalSlabMaterial.load(), foil: try await HoloFoilMaterial.load(),
                                  edge: try await GoldEdgeMaterial.load(), glint: try await SweepGlintMaterial.load())
    }

    /// **v4 B4 §3.5.** The same stack with the crystal's frost chosen (`cmd perf material=plain|blur`).
    static func make(frostBlur blur: Bool) async throws -> MagicCardSurfaceMaterials {
        MagicCardSurfaceMaterials(crystal: try await CrystalSlabMaterial.load(frostBlur: blur), foil: try await HoloFoilMaterial.load(),
                                  edge: try await GoldEdgeMaterial.load(), glint: try await SweepGlintMaterial.load())
    }

    /// `CardSurfaceStyle.apply(to:)`: materials, the gold line's mesh, and components — nothing else.
    func apply(slab: ModelEntity, rim: ModelEntity, goldLine: ModelEntity, foil foilEntity: ModelEntity,
               sweep sweepEntity: ModelEntity, outline: Outline) {
        let half = outline.size / 2
        crystal.setOutline(halfSize: half, cornerRadius: outline.cornerRadius)
        crystal.setThickness(outline.thickness)
        crystal.setSweep(1)
        crystal.commit(to: slab)
        slab.components.set(GroundingShadowComponent(castsShadow: true))

        rim.components.set(OpacityComponent(opacity: 0))

        edge.setOutline(halfSize: half, cornerRadius: outline.cornerRadius)
        edge.setLine(inset: outline.goldInset, width: outline.goldWidth)
        edge.setSweep(1)
        goldLine.model?.mesh = MagicMeshes.goldEdgeRing(width: outline.size.x, height: outline.size.y,
                                                        radius: outline.cornerRadius)
        edge.commit(to: goldLine)
        goldLine.components.set(BloomComponent(scope: .hierarchical))

        // Foil and sweep get fresh counter-clockwise planes (the contract allows replacing these two meshes): the
        // graphs read object-space position, and a style swapped in after the placeholder would otherwise inherit
        // its live-face meshes. Both stay centred on the card, where A4's panel is.
        foilEntity.model?.mesh = MagicMeshes.roundedPlane(width: outline.foilSize.x, height: outline.foilSize.y,
                                                          radius: outline.foilCornerRadius)
        foil.setHalfSize(outline.foilSize / 2)
        foil.setStrength(foilStrength)
        foil.setSweep(1)
        foil.commit(to: foilEntity)
        foilEntity.components.set(OpacityComponent(opacity: 1))

        sweepEntity.model?.mesh = MagicMeshes.roundedPlane(width: outline.sweepSize.x, height: outline.sweepSize.y,
                                                           radius: outline.sweepCornerRadius)
        glint.setHalfSize(outline.sweepSize / 2)
        glint.setSweep(1)
        glint.commit(to: sweepEntity)
        sweepEntity.components.set(OpacityComponent(opacity: 1))
        lastSweep = .nan
    }

    /// **v4 B1: the reveal.** While the slab dissolves in (the caller swaps it to MagicDissolve), the gold line comes
    /// up with the last third of the fill and the foil after it — the same curves `NameCardMaterialStack.setReveal`
    /// uses (`MagicMaterialRules`). nil = the finished card (the line at 1, the foil at `foilStrength`).
    func setRevealLevels(_ progress: Float?, goldLine: ModelEntity, foil foilEntity: ModelEntity) {
        edge.setIntensity(progress.map { V4.MagicMaterialRules.revealEdgeIntensity($0) } ?? 1)
        foil.setStrength(progress.map { V4.MagicMaterialRules.revealFoilStrength($0) * foilStrength } ?? foilStrength)
        edge.commit(to: goldLine)
        foil.commit(to: foilEntity)
    }

    /// `CardSurfaceStyle.update(…)`: `sweep` is A4's linear progress 0…1 (nil between sweeps). Eased here like the
    /// A1 lab's, and pushed only when it changed — at rest this costs one comparison per frame.
    func update(slab: ModelEntity, goldLine: ModelEntity, foil foilEntity: ModelEntity, sweepEntity: ModelEntity,
                progress: Float?) {
        let value = progress.map { V4.MaterialsLabClock.easeInOut($0) } ?? 1
        guard value != lastSweep else { return }
        lastSweep = value
        crystal.setSweep(value)
        foil.setSweep(value)
        edge.setSweep(value)
        glint.setSweep(value)
        crystal.commit(to: slab)
        foil.commit(to: foilEntity)
        edge.commit(to: goldLine)
        glint.commit(to: sweepEntity)
    }
}
