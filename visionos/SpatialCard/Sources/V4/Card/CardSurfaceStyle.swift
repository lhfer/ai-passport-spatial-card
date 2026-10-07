import Foundation
import RealityKit
import UIKit

/// **The card's material stack, behind one interface** (brief A4 §1): A1 is building the real ShaderGraph materials
/// (CrystalSlab, HoloFoil, GoldEdge) in parallel, so the card is dressed by whatever `CardSurfaceStyle` it is given.
/// `PlaceholderCardSurfaceStyle` below is v1's stand-in; A1's style replaces it with no change to the card.
///
/// Division of labour: the **rig** owns geometry and motion (it builds `HeroCardSurface`'s entities and meshes, and
/// moves the card); the **style** owns materials and the per-frame material parameters. Contract:
/// - `apply(to:)` runs once per card (and again if the style is swapped). It may set materials, replace the foil /
///   sweep meshes (the placeholder does, for its UV tricks), and add components — nothing else.
/// - `update(…)` runs every frame and may only change **parameters**: `OpacityComponent`s, a `LowLevelMesh` buffer,
///   or `ShaderGraphMaterial.setParameter` — never build a mesh or a material (common rules).
@MainActor
protocol CardSurfaceStyle: AnyObject {
    var name: String { get }
    func apply(to surface: HeroCardSurface)
    /// - Parameters:
    ///   - facing: |n · v| — 1 seen square-on, 0 edge-on (the bible's 正视 / 掠视).
    ///   - viewInCard: unit vector from the card to the eye, in the card's own frame (x right, y up, z out of the
    ///     face) — what makes the foil's hues flow when the head moves.
    ///   - sweep: progress 0…1 of the diagonal light sweep, or nil between sweeps. It crosses foil and gold line.
    func update(_ surface: HeroCardSurface, facing: Float, viewInCard: SIMD3<Float>, sweep: Float?)
}

/// The entities the material stack lives on, in the card's frame (origin at the centre of the slab's front face,
/// +Z towards the reader). Depths are the rig's: slab behind the face, the rest a fraction of a millimetre in front.
///
/// A style that brings its own geometry (A1's `NameCardMaterialStack` builds its slab, foil and edge ring itself)
/// parents it to `root`, joins `sortGroup` at `firstOrder…firstOrder + 6`, and disables the placeholder entities it
/// replaces. Whatever it draws on the face must sit **in front of the rig's opaque frost** (z > +0.15 mm) — or, if
/// its own slab *is* the frost (A1's CrystalSlab), the rig's frost plane is disabled and the type still reads,
/// provided the slab stays as pale as the approved stack.
@MainActor
final class HeroCardSurface {
    let layout: V4.HeroCardLayout
    /// The card root (the rig's), for styles that mount entities of their own.
    let root: Entity
    /// The card's draw-order group; the surface owns orders `firstOrder … firstOrder + 6` (slab … sweep).
    let sortGroup: ModelSortGroup
    let firstOrder: Int32 = 0
    /// The 12 mm crystal block (front face at z = 0) — the sides and back of the card; the face is the rig's frost.
    let slab: ModelEntity
    /// Edge light around the front face — the Fresnel the bible asks for (0.45 square-on → 0.9 grazing).
    let rim: ModelEntity
    /// The gold line 1.5 mm in from the edge.
    let goldLine: ModelEntity
    /// Holo foil over the frost.
    let foil: ModelEntity
    /// The diagonal light sweep (additive), over foil and gold line.
    let sweep: ModelEntity
    /// Glow just outside the slab's edge (the luminous halo of the approved stack in the dark). **Disabled until a
    /// style enables it** — a style that does not know it (A1's wrapper dresses the five above) leaves it off.
    let halo: ModelEntity
    /// An opaque frosted face over the slab's front, for styles whose slab is clear (the placeholder's). **Disabled
    /// until a style enables it**: A1's CrystalSlab is itself the frost, and this plane would hide it.
    let frost: ModelEntity

    /// Depths above the front face, metres. The frost sits at +0.15 mm, so everything the style draws on the face is
    /// in front of it: foil, then the edge light and halo, then the gold line; the sweep crosses over.
    static let frostZ: Float = 0.00015
    static let foilZ: Float = 0.00025
    static let rimZ: Float = 0.0003
    static let goldZ: Float = 0.00035
    static let sweepZ: Float = 0.0012
    /// Width of the halo ring outside the slab: 3 mm. (7 mm read as a soft blur around the edge in review — the rim
    /// should be a crisp line of light with a short glow, not a haze.)
    static let haloWidth: Float = 0.003

    init(layout: V4.HeroCardLayout, root: Entity, sortGroup: ModelSortGroup) {
        self.layout = layout
        self.root = root
        self.sortGroup = sortGroup
        let w = layout.size.x, h = layout.size.y, r = layout.cornerRadius
        slab = ModelEntity(mesh: FXMeshes.roundedSlab(width: w, height: h, depth: V4.HeroCardLayout.thickness, radius: r))
        slab.name = "card.slab"
        slab.position = [0, 0, -V4.HeroCardLayout.thickness / 2]
        // 6 mm wide (v = 0 at the slab's edge, 1 inside): room for an edge light that falls off inward.
        rim = ModelEntity(mesh: FXMeshes.roundedRectRing(width: w, height: h, radius: r, thickness: 0.006))
        rim.name = "card.rim"
        rim.position = [0, 0, Self.rimZ]
        let inset = V4.HeroCardLayout.goldInset
        goldLine = ModelEntity(mesh: FXMeshes.roundedRectRing(width: w - 2 * inset, height: h - 2 * inset,
                                                              radius: r - inset, thickness: V4.HeroCardLayout.goldWidth))
        goldLine.name = "card.goldLine"
        goldLine.position = [0, 0, Self.goldZ]
        foil = ModelEntity(mesh: .generatePlane(width: layout.face.width, height: layout.face.height,
                                                cornerRadius: layout.faceCornerRadius))
        foil.name = "card.foil"
        foil.position = [layout.face.midX, layout.face.midY, Self.foilZ]
        sweep = ModelEntity(mesh: .generatePlane(width: w - 2 * inset, height: h - 2 * inset, cornerRadius: r - inset))
        sweep.name = "card.sweep"
        sweep.position = [0, 0, Self.sweepZ]
        sweep.components.set(OpacityComponent(opacity: 0))
        let g = Self.haloWidth
        halo = ModelEntity(mesh: FXMeshes.roundedRectRing(width: w + 2 * g, height: h + 2 * g, radius: r + g, thickness: g))
        halo.name = "card.halo"
        halo.position = [0, 0, Self.rimZ]
        halo.isEnabled = false
        frost = ModelEntity(mesh: .generatePlane(width: layout.face.width, height: layout.face.height,
                                                 cornerRadius: layout.faceCornerRadius))
        frost.name = "card.frost"
        frost.position = [layout.face.midX, layout.face.midY, Self.frostZ]
        frost.isEnabled = false
    }

    var entities: [ModelEntity] { [slab, frost, rim, goldLine, foil, sweep, halo] }
}

/// **v1's stand-in material stack**, dressed in the approved pale-frost direction (A1, 2026-09-26): a clear-coated,
/// near-white `PhysicallyBasedMaterial` slab at 10 % opacity for the sides, a warm edge light and an outer halo that
/// follow the viewing angle, a gold line, a pastel foil tint over the frost, and a gold light band for the sweep —
/// foil and sweep on `HeroCardLiveFace` meshes, so their textures slide (hue flow, sweep) without a new mesh or
/// material per frame. (The frost face itself is the rig's: it is the card's surface, not a material effect.)
///
/// True additive blending (edge light, halo, sweep) comes from `UnlitMaterial.Program` with `blendMode = .add`
/// (visionOS 2+); that program has to be built asynchronously, hence `make()`. The foil is plain alpha: added onto a
/// pale frost it would only push it towards white — laid over it, its pastels tint it.
@MainActor
final class PlaceholderCardSurfaceStyle: CardSurfaceStyle {
    let name = "placeholder"
    /// Scale on the bible's foil curve (0.12 square-on → 0.45 grazing is its *ceiling*). On the frost the full curve
    /// reads as the iridescent tint it should be. (On the round 1–8 midnight panel the additive foil needed 0.45: sRGB
    /// 62.8 → 89.0 → 104.7 → 126.0 at gain 0 / 0.5 / 1 / 2 — the `.add` blend does scale with `OpacityComponent`.)
    /// `--card-foil-gain` overrides it.
    var foilGain: Float = 1
    /// The halo follows the rim's Fresnel, doubled: at the rim's 0.45 square-on it read as a muddy brown band.
    static let haloGain: Float = 2
    private let additive: UnlitMaterial.Program
    private let foilTexture: TextureResource
    private let sweepTexture: TextureResource
    private let edgeTexture: TextureResource
    private let haloTexture: TextureResource
    private var frostTextures: [V4.HeroCardShape: TextureResource] = [:]
    private var foilFace: HeroCardLiveFace?
    private var sweepFace: HeroCardLiveFace?
    /// Last view direction the foil UVs were written for; they are only rewritten when the eye has moved.
    private var lastView: SIMD3<Float> = [0, 0, 0]
    private var lastSweep: Float?
    private var lastRim: Float = -1
    private var lastFoil: Float = -1
    /// Diagonal of the sweep: from the top-left corner towards the bottom-right, 30° off vertical.
    private let sweepDirection = simd_normalize(SIMD2<Float>(0.5, -0.866))

    private init(additive: UnlitMaterial.Program) {
        self.additive = additive
        foilTexture = HeroCardTextures.foil()
        sweepTexture = HeroCardTextures.sweepBand()
        edgeTexture = HeroCardTextures.edgeLight()
        haloTexture = HeroCardTextures.outerHalo()
    }

    static func make() async -> PlaceholderCardSurfaceStyle {
        var descriptor = UnlitMaterial.Program.Descriptor()
        descriptor.blendMode = .add
        descriptor.applyPostProcessToneMap = false
        let program = await UnlitMaterial.Program(descriptor: descriptor)
        return PlaceholderCardSurfaceStyle(additive: program)
    }

    func apply(to surface: HeroCardSurface) {
        let layout = surface.layout
        // Crystal: near-white, micro-frosted, clear-coated; a trace of warm emission so it never goes black in a dark
        // room (0.06 is far under any bloom threshold — the card body must not glow, bible §2).
        var crystal = PhysicallyBasedMaterial()
        crystal.baseColor = .init(tint: HeroCardPalette.crystal)
        crystal.roughness = .init(floatLiteral: 0.2)
        crystal.metallic = .init(floatLiteral: 0)
        crystal.clearcoat = .init(floatLiteral: 1)
        crystal.clearcoatRoughness = .init(floatLiteral: 0.05)
        crystal.emissiveColor = .init(color: HeroCardPalette.goldHot)
        crystal.emissiveIntensity = 0.06
        crystal.blending = .transparent(opacity: .init(floatLiteral: 0.10))
        crystal.faceCulling = .back
        crystal.writesDepth = false
        surface.slab.model?.materials = [crystal]
        surface.slab.components.set(GroundingShadowComponent(castsShadow: true))

        // Frost: the face — pale, luminous, opaque (the approved direction; see `HeroCardTextures.frost`). Unlit, so it
        // reads the same in the dark dome and in a lit room; opaque, so the type and the pop-up in front of it never
        // depend on transparent draw order.
        let frostTexture = frostTextures[layout.shape] ?? HeroCardTextures.frost(layout: layout)
        frostTextures[layout.shape] = frostTexture
        var frost = UnlitMaterial(applyPostProcessToneMap: false)
        frost.color = .init(tint: .white, texture: .init(frostTexture, sampler: HeroCardTextures.clampSampler))
        surface.frost.model?.materials = [frost]
        surface.frost.isEnabled = true

        // Rim: the crystal's edge light — a warm hairline at the slab's edge fading inward over 6 mm, added onto
        // whatever is behind; strength = opacity, set per frame from the angle (Fresnel).
        var edge = UnlitMaterial(program: additive)
        edge.color = .init(tint: .white, texture: .init(edgeTexture, sampler: HeroCardTextures.clampSampler))
        edge.faceCulling = .none
        edge.writesDepth = false
        surface.rim.model?.materials = [edge]
        surface.rim.components.set(OpacityComponent(opacity: V4.HeroCardLook.rimFacing))

        // Halo: the same warm light spilling past the edge into the room (additive — in a lit room it all but
        // vanishes, in the dark it is the card's glow).
        var halo = UnlitMaterial(program: additive)
        halo.color = .init(tint: .white, texture: .init(haloTexture, sampler: HeroCardTextures.clampSampler))
        halo.faceCulling = .none
        halo.writesDepth = false
        surface.halo.model?.materials = [halo]
        surface.halo.components.set(OpacityComponent(opacity: min(1, V4.HeroCardLook.rimFacing * Self.haloGain)))
        surface.halo.isEnabled = true

        // Gold line: old gold deepened a little, so it holds on the pale frost's warm edge; the sweep, added on top,
        // lifts it towards `gold` as it passes.
        var gold = UnlitMaterial(applyPostProcessToneMap: false)
        gold.color = .init(tint: HeroCardPalette.oldGold.mixed(with: UIColor(hex: "#A67C2E"), by: 0.5))
        gold.faceCulling = .none
        surface.goldLine.model?.materials = [gold]

        // Foil: a pastel tint laid over the frost (alpha), on a live face.
        var foil = UnlitMaterial(applyPostProcessToneMap: false)
        foil.color = .init(tint: .white, texture: .init(foilTexture, sampler: HeroCardTextures.repeatSampler))
        foil.blending = .transparent(opacity: .init(floatLiteral: 1))
        foil.faceCulling = .none
        foil.writesDepth = false
        if let face = HeroCardLiveFace(rect: layout.face, radius: layout.faceCornerRadius) {
            foilFace = face
            surface.foil.model?.mesh = face.resource
            surface.foil.position = [0, 0, HeroCardSurface.foilZ]
        }
        surface.foil.model?.materials = [foil]
        surface.foil.components.set(OpacityComponent(opacity: V4.HeroCardLook.foilFacing))

        var band = UnlitMaterial(program: additive)
        band.color = .init(tint: .white, texture: .init(sweepTexture, sampler: HeroCardTextures.clampSampler))
        band.faceCulling = .none
        band.writesDepth = false
        let inset = V4.HeroCardLayout.goldInset - 0.0006
        let outer = V4.HeroCardRect(minX: -layout.size.x / 2, minY: -layout.size.y / 2,
                                    width: layout.size.x, height: layout.size.y).inset(by: inset)
        if let face = HeroCardLiveFace(rect: outer, radius: layout.cornerRadius - inset) {
            sweepFace = face
            surface.sweep.model?.mesh = face.resource
            surface.sweep.position = [0, 0, HeroCardSurface.sweepZ]
            face.setUVs { _ in [0, 0.5] }                      // parked on the clear border texel
        }
        surface.sweep.model?.materials = [band]
        surface.sweep.components.set(OpacityComponent(opacity: 0))
        lastView = [0, 0, 0]
        lastSweep = nil
        lastRim = -1
        lastFoil = -1
    }

    func update(_ surface: HeroCardSurface, facing: Float, viewInCard: SIMD3<Float>, sweep: Float?) {
        let rim = V4.HeroCardLook.rim(facing: facing)
        if abs(rim - lastRim) > 0.002 {
            surface.rim.components.set(OpacityComponent(opacity: rim))
            surface.halo.components.set(OpacityComponent(opacity: min(1, rim * Self.haloGain)))
            lastRim = rim
        }
        let foil = V4.HeroCardLook.foil(facing: facing) * foilGain
        if abs(foil - lastFoil) > 0.002 {
            surface.foil.components.set(OpacityComponent(opacity: foil))
            lastFoil = foil
        }
        // Hue flow: the foil's UVs slide with the eye's direction across the card (≈ one hue cycle per 25° of head
        // movement), so turning the head — or the card — runs the rainbow across it. Only when the eye has moved.
        if let face = foilFace, simd_length(viewInCard - lastView) > 0.0015 {
            lastView = viewInCard
            let scale: Float = 3.2                            // UV per metre of card
            let flow = SIMD2<Float>(viewInCard.x, viewInCard.y) * 1.15
            face.setUVs { p in [p.x * scale + flow.x, p.y * scale * 0.8 + flow.y] }
        }
        // Sweep: the band's centre travels along the diagonal from beyond one corner to beyond the other.
        if let face = sweepFace, sweep != lastSweep {
            lastSweep = sweep
            if let progress = sweep {
                let half = surface.layout.size / 2
                let reach = abs(half.x * sweepDirection.x) + abs(half.y * sweepDirection.y) + 0.03
                let eased = progress * progress * (3 - 2 * progress)
                let centre = -reach + 2 * reach * eased
                let width: Float = 0.16                         // metres of card per unit of u
                let dir = sweepDirection
                face.setUVs { p in [0.5 + (simd_dot(p, dir) - centre) / width, 0.5] }
                // 0.65 peak: at 0.85 (round 5) the band washed the handle line out as it crossed it.
                surface.sweep.components.set(OpacityComponent(opacity: 0.65 * sin(.pi * progress)))
            } else {
                surface.sweep.components.set(OpacityComponent(opacity: 0))
            }
        }
    }
}
