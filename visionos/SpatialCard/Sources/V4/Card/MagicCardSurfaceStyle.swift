import RealityKit

/// A1's material stack on the hero card: CrystalSlab (frosted, per-pixel Fresnel rim), GoldEdge, a pastel HoloFoil
/// over the panel and SweepGlint — `MagicCardSurfaceMaterials` does the work (A1 report §7).
///
/// **v4 B1** adds the one thing the product needs that A1's wrapper does not do: the **reveal**. For the first
/// recognition the card is dissolved into the outline the ribbon drew — `setReveal(_:on:)` swaps the slab to
/// MagicDissolve (preloaded, same outline, same crystal parameters: at progress 1 it is pixel-for-pixel the crystal),
/// drives its progress, and brings the gold line and the foil up behind the front (A1's `MagicMaterialRules` curves).
/// It also switches off the two placeholder-only entities a swap from `PlaceholderCardSurfaceStyle` would leave on:
/// A1's slab *is* the frost, and its rim light lives in the crystal (A4 §7).
@MainActor
final class MagicCardSurfaceStyle: CardSurfaceStyle {
    let name = "a1-magic"
    private let materials: MagicCardSurfaceMaterials
    private var dissolve: MagicDissolveMaterial
    /// nil = the whole card (the slab renders CrystalSlab); a value = mid-reveal.
    private(set) var reveal: Float?

    private init(materials: MagicCardSurfaceMaterials, dissolve: MagicDissolveMaterial) {
        self.materials = materials
        self.dissolve = dissolve
    }

    /// First call ≈ 1.5 s in the simulator (four ShaderGraph materials); `MagicMaterialLoader.preload()` at launch
    /// makes it instant (`V4MaterialPreload`).
    static func make() async throws -> MagicCardSurfaceStyle {
        MagicCardSurfaceStyle(materials: try await MagicCardSurfaceMaterials.make(),
                              dissolve: try await MagicDissolveMaterial.load())
    }

    /// **v4 B4 §3.5.** A1's stack with the frost chosen — `cmd perf material=blur` on a `plain` launch (or the other way)
    /// loads the two frost graphs it needs on first use (≈ 1.5 s in the simulator) and keeps them.
    static func make(frostBlur blur: Bool) async throws -> MagicCardSurfaceStyle {
        MagicCardSurfaceStyle(materials: try await MagicCardSurfaceMaterials.make(frostBlur: blur),
                              dissolve: try await MagicDissolveMaterial.load(frostBlur: blur))
    }

    func apply(to surface: HeroCardSurface) {
        let layout = surface.layout
        let inset = V4.HeroCardLayout.goldInset
        materials.apply(slab: surface.slab, rim: surface.rim, goldLine: surface.goldLine,
                        foil: surface.foil, sweep: surface.sweep,
                        outline: .init(size: layout.size, cornerRadius: layout.cornerRadius,
                                       thickness: V4.HeroCardLayout.thickness,
                                       foilSize: [layout.panel.width, layout.panel.height],
                                       foilCornerRadius: layout.panelCornerRadius,
                                       sweepSize: layout.size - 2 * inset,
                                       sweepCornerRadius: layout.cornerRadius - inset,
                                       goldInset: inset, goldWidth: V4.HeroCardLayout.goldWidth))
        // v4 B1: A1's crystal is the frost and carries the edge light; the placeholder's opaque frost plane and its
        // additive halo would sit on top of it (and they are left on by a style swap).
        surface.frost.isEnabled = false
        surface.halo.isEnabled = false
        dissolve.setOutline(halfSize: layout.size / 2, cornerRadius: layout.cornerRadius)
        dissolve.setThickness(V4.HeroCardLayout.thickness)
        reveal = nil
    }

    func update(_ surface: HeroCardSurface, facing: Float, viewInCard: SIMD3<Float>, sweep: Float?) {
        // facing / viewInCard are evaluated per pixel on the GPU; only the sweep is a parameter.
        materials.update(slab: surface.slab, goldLine: surface.goldLine, foil: surface.foil,
                         sweepEntity: surface.sweep, progress: sweep)
        // The wrapper pushes the crystal to the slab when the sweep changes; mid-reveal the slab is the dissolve.
        if reveal != nil { dissolve.commit(to: surface.slab) }
    }

    /// **v4 B1: the reveal.** `progress` 0…1 fills the slab from its outline inward (0 = only the glowing gold edge,
    /// 1 = the crystal); nil puts the finished card back. The swap between the two preloaded materials happens only
    /// when crossing into / out of a reveal.
    func setReveal(_ progress: Float?, on surface: HeroCardSurface) {
        let clamped = progress.map { min(1, max(0, $0)) }
        if let p = clamped, p < 1 {
            reveal = p
            dissolve.setProgress(p)
            dissolve.commit(to: surface.slab)
            materials.setRevealLevels(p, goldLine: surface.goldLine, foil: surface.foil)
        } else if reveal != nil || clamped == 1 {
            reveal = nil
            materials.crystal.commit(to: surface.slab)
            materials.setRevealLevels(nil, goldLine: surface.goldLine, foil: surface.foil)
        }
    }
}
