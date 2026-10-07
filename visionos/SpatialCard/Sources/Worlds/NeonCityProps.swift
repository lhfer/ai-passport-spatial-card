import Foundation
import Metal
import RealityKit
import UIKit

/// Procedural set pieces for 霓虹雨城: the wet rooftop slab, the elevated rail with its train, the airship, the antenna
/// mast, the water tank and the roof-access hut. Everything the IBL should light is PBR (asphalt, tank, hut,
/// parapet); everything else is unlit or emissive so it never renders black inside the opaque shell.
@MainActor
enum NeonCityProps {
    // MARK: - Rooftop (Poly Haven asphalt_02, wet)

    /// Descriptor `textures` stems of the asphalt set (`WorldAssetLibrary` loads them with the right semantics:
    /// `_nor` → normal map, `_rough` → linear data).
    static let asphaltDiffuse = "neon_asphalt_diff"
    static let asphaltNormal = "neon_asphalt_nor"
    static let asphaltRoughness = "neon_asphalt_rough"

    /// Rain-soaked asphalt: dark diffuse, full normal map, roughness pulled down and a glossy clearcoat so the IBL
    /// (the Bund at night) smears across the floor like neon on wet ground.
    static func wetAsphalt(diffuse: TextureResource?, normal: TextureResource?, roughness: TextureResource?) -> PhysicallyBasedMaterial {
        let desc = MTLSamplerDescriptor()
        desc.sAddressMode = .repeat
        desc.tAddressMode = .repeat
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.mipFilter = .linear
        desc.maxAnisotropy = 4      // the slab is all grazing angles; 8 doubled the fetches for no visible gain
        let sampler = MaterialParameters.Texture.Sampler(desc)
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(white: 0.62, alpha: 1), texture: diffuse.map { .init($0, sampler: sampler) })
        if let normal { m.normal = .init(texture: .init(normal, sampler: sampler)) }
        m.roughness = .init(scale: 0.32, texture: roughness.map { .init($0, sampler: sampler) })
        m.metallic = .init(floatLiteral: 0)
        m.clearcoat = .init(floatLiteral: 0.9)
        m.clearcoatRoughness = .init(floatLiteral: 0.1)
        m.faceCulling = .none
        return m
    }

    /// Placeholder until the textures arrive: dark, glossy, still catches the IBL.
    static func wetAsphaltPlaceholder() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(hex: "#14161F"))
        m.roughness = .init(floatLiteral: 0.3)
        m.clearcoat = .init(floatLiteral: 0.8)
        m.clearcoatRoughness = .init(floatLiteral: 0.1)
        m.faceCulling = .none
        return m
    }

    /// Square slab in the XZ plane with tiled UVs (and tangents, so the normal map works), normal +Y.
    static func slabMesh(size: Float, tiles: Float) -> MeshResource {
        let h = size / 2
        var d = MeshDescriptor(name: "neon-roof")
        d.positions = MeshBuffers.Positions([[-h, 0, -h], [h, 0, -h], [h, 0, h], [-h, 0, h]])
        d.normals = MeshBuffers.Normals(Array(repeating: SIMD3<Float>(0, 1, 0), count: 4))
        d.tangents = MeshBuffers.Tangents(Array(repeating: SIMD3<Float>(1, 0, 0), count: 4))
        d.textureCoordinates = MeshBuffers.TextureCoordinates([[0, 0], [tiles, 0], [tiles, tiles], [0, tiles]])
        d.primitives = .triangles([0, 2, 1, 0, 3, 2])
        return (try? MeshResource.generate(from: [d])) ?? .generatePlane(width: size, depth: size)
    }

    /// Shared 1 m cube for anything box-shaped that only differs by scale (skyline towers).
    static let unitBox = MeshResource.generateBox(size: 1)

    static func concrete(_ hex: String = "#3E4254") -> PhysicallyBasedMaterial {
        WorldKit.pbr(UIColor(hex: hex), roughness: 0.92, metallic: 0)
    }

    static func darkMetal(_ hex: String = "#3B4054") -> PhysicallyBasedMaterial {
        WorldKit.pbr(UIColor(hex: hex), roughness: 0.48, metallic: 0.75)
    }

    /// Unit puddle (1 m × 0.7 m, fully rounded) — the world scales one instanced draw per puddle.
    static let puddleMesh = MeshResource.generatePlane(width: 1, depth: 0.7, cornerRadius: 0.35)

    /// Standing water: a glossier, slightly darker patch of the same asphalt tone (not a black hole) that mirrors the
    /// IBL. Opaque and clearcoat-free: it sits 6 mm over the slab, so nothing shows through the 15 % it used to let
    /// pass, and a second specular lobe on top of the slab's own clearcoat bought nothing the low roughness and a
    /// little metallic do not. Both changes take it out of the sorted transparent pass.
    static func puddleMaterial() -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: UIColor(hex: "#1B1F2C"))
        m.roughness = .init(floatLiteral: 0.05)
        m.metallic = .init(floatLiteral: 0.15)
        return m
    }

    // MARK: - Elevated rail + train

    /// Deck, running lights and pillars along local Z (the world yaws the entity so local −Z = forward).
    static func elevatedRail(length: Float, deckY: Float, pillarBottomY: Float, lightColor: UIColor) -> Entity {
        let rail = Entity()
        let deck = ModelEntity(mesh: .generateBox(width: 1.8, height: 0.7, depth: length), materials: [WorldKit.unlit(UIColor(hex: "#151B30"))])
        deck.position = [0, deckY - 0.35, 0]
        rail.addChild(deck)
        for side: Float in [-1, 1] {
            let strip = ModelEntity(mesh: .generateBox(width: 0.05, height: 0.04, depth: length), materials: [WorldKit.emissive(lightColor, intensity: 2.2)])
            strip.position = [side * 0.88, deckY + 0.02, 0]
            rail.addChild(strip)
        }
        let pillarH = deckY - 0.7 - pillarBottomY
        var z: Float = -length / 2 + 7
        let pillarMesh = MeshResource.generateBox(width: 1.0, height: pillarH, depth: 1.0)
        let pillarMaterial = WorldKit.unlit(UIColor(hex: "#0F1428"))
        while z < length / 2 {
            let pillar = ModelEntity(mesh: pillarMesh, materials: [pillarMaterial])
            pillar.position = [0, pillarBottomY + pillarH / 2, z]
            rail.addChild(pillar)
            z += 16
        }
        return rail
    }

    /// Box-car metro with lit windows, two headlights, a headlight pool on the deck and red tail lights.
    /// Local frame: cars along Z, front toward −Z; `root.position.y` = deck top.
    @MainActor
    final class Train {
        let root = Entity()
        let length: Float
        private let carLength: Float = 11
        private let gap: Float = 0.5
        private let beam: ModelEntity

        init(cars: Int, accent: UIColor, windows: TextureResource) {
            length = Float(cars) * carLength + Float(cars - 1) * gap
            let body = WorldKit.unlit(UIColor(hex: "#0D1224"))
            let glass = WorldKit.unlit(.white, texture: windows, toneMap: false, opaque: true)   // the strip is a solid image
            // Plain boxes: a `cornerRadius` box is ~13 k triangles in RealityKit, so the four cars alone were
            // 52 k while the metro crossed — and the 12 cm fillet is invisible at 11 m and beyond.
            let bodyMesh = MeshResource.generateBox(width: 2.7, height: 3.0, depth: carLength)
            let sideMesh = MeshResource.generatePlane(width: carLength, height: 3.0)
            for i in 0..<cars {
                let z = -length / 2 + carLength / 2 + Float(i) * (carLength + gap)
                let car = ModelEntity(mesh: bodyMesh, materials: [body])
                car.position = [0, 1.5, z]
                root.addChild(car)
                for side: Float in [-1, 1] {
                    let plane = ModelEntity(mesh: sideMesh, materials: [glass])
                    plane.position = [side * 1.365, 1.55, z]
                    plane.orientation = simd_quatf(angle: side * .pi / 2, axis: [0, 1, 0])
                    root.addChild(plane)
                }
            }
            let fx = FXTextures.shared
            for side: Float in [-1, 1] {
                let head = ModelEntity(mesh: .generatePlane(width: 0.7, height: 0.7), materials: [FXMaterials.glow(fx.coreDisc, tint: UIColor(hex: "#FFF6E0"), opacity: 0.95)])
                head.position = [side * 0.85, 1.0, -length / 2 - 0.06]
                root.addChild(head)
                let tail = ModelEntity(mesh: .generatePlane(width: 0.45, height: 0.45), materials: [FXMaterials.glow(fx.coreDisc, tint: UIColor(hex: "#FF3B3B"), opacity: 0.9)])
                tail.position = [side * 0.85, 1.0, length / 2 + 0.06]
                root.addChild(tail)
            }
            // Headlight pool: the beam texture laid flat on the deck ahead of the nose, bright at the train.
            beam = ModelEntity(mesh: .generatePlane(width: 3.4, height: 9), materials: [FXMaterials.glow(fx.beam, tint: UIColor(hex: "#FFE9C0"), opacity: 0.35)])
            beam.position = [0, 0.05, -length / 2 - 4.5]
            beam.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            root.addChild(beam)
            // Accent stripe (livery) along the roof line.
            for side: Float in [-1, 1] {
                let stripe = ModelEntity(mesh: .generateBox(width: 0.02, height: 0.08, depth: length), materials: [WorldKit.emissive(accent, intensity: 1.6)])
                stripe.position = [side * 1.37, 2.75, 0]
                root.addChild(stripe)
            }
            root.isEnabled = false
        }
    }

    nonisolated static func trainWindowsKey(accent: UIColor) -> String { "train-windows-\(accent.hashValue)" }

    /// One metro car side: dark body, roof band, a row of lit windows (warm / cool, a few dark), two door seams.
    static func trainWindowsTexture(accent: UIColor) -> TextureResource {
        WorldKit.customTexture(key: trainWindowsKey(accent: accent), mipmaps: true) { renderTrainWindows(accent: accent) }
    }

    nonisolated static func trainWindowsJob(accent: UIColor) -> WorldKit.TextJob {
        WorldKit.TextJob(key: trainWindowsKey(accent: accent), mipmaps: true) { renderTrainWindows(accent: accent) }
    }

    nonisolated static func renderTrainWindows(accent: UIColor) -> CGImage? {
        let size = CGSize(width: 1024, height: 256)
        let renderer = UIGraphicsImageRenderer(size: size)
        var rng = WorldKit.RNG(0x7EA1)
        return renderer.image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(hex: "#0F1428").cgColor)
            c.fill(CGRect(origin: .zero, size: size))
            c.setFillColor(UIColor(hex: "#1B2140").cgColor)
            c.fill(CGRect(x: 0, y: 0, width: 1024, height: 44))
            c.setFillColor(UIColor(hex: "#07090F").cgColor)
            c.fill(CGRect(x: 0, y: 214, width: 1024, height: 42))
            c.setFillColor(accent.withAlphaComponent(0.9).cgColor)
            c.fill(CGRect(x: 0, y: 196, width: 1024, height: 8))
            for i in 0..<10 {
                let x = 40 + CGFloat(i) * 96
                let door = i == 2 || i == 7
                if door {
                    c.setFillColor(UIColor(hex: "#0A0D1C").cgColor)
                    c.fill(CGRect(x: x - 6, y: 48, width: 76, height: 166))
                    c.setFillColor(UIColor(hex: "#3A4570").cgColor)
                    c.fill(CGRect(x: x + 30, y: 48, width: 4, height: 166))
                }
                let lit = rng.next() > 0.18
                let warm = rng.next() > 0.45
                let color = lit ? (warm ? UIColor(hex: "#FFD9A6") : UIColor(hex: "#CFE9FF")) : UIColor(hex: "#151A30")
                c.setFillColor(color.cgColor)
                c.fill(CGRect(x: x, y: door ? 60 : 64, width: 64, height: door ? 78 : 92))
            }
        }.cgImage
    }

    // MARK: - Airship

    /// Ellipsoid hull along local +X (nose at +X), gondola, lit belly, side banners with the card owner's name,
    /// blinking nose / tail lights.
    @MainActor
    final class Airship {
        let root = Entity()
        let nav: ModelEntity
        let tail: ModelEntity

        /// The hull's UV sphere (`WorldKit.skySphere`), made ahead by `NeonCityWorld.prewarm` (B5 §5).
        static let hullRings = 12
        static let hullSegments = 24

        init(primary: UIColor, accent: UIColor, banner: TextureResource) {
            // 18 m blimp: hull along +X, nose at +X. `generateSphere` is ~8 k triangles; a 12 × 24 UV sphere is
            // 576 and still reads as a smooth hull at 40–55 m (the material is unlit and two-sided, so the
            // sky-dome helper's inward normals make no difference).
            let hull = ModelEntity(mesh: WorldKit.skySphere(radius: 1, rings: Airship.hullRings, segments: Airship.hullSegments),
                                   materials: [WorldKit.unlit(UIColor(hex: "#2A3152"))])
            hull.scale = [9, 2.2, 2.2]
            root.addChild(hull)
            let finMaterial = WorldKit.unlit(UIColor(hex: "#222848"))
            let finV = ModelEntity(mesh: .generateBox(width: 3.0, height: 4.6, depth: 0.1), materials: [finMaterial])
            finV.position = [-7.2, 0, 0]
            root.addChild(finV)
            let finH = ModelEntity(mesh: .generateBox(width: 3.0, height: 0.1, depth: 4.6), materials: [finMaterial])
            finH.position = [-7.2, 0, 0]
            root.addChild(finH)
            let gondola = ModelEntity(mesh: .generateBox(width: 3.8, height: 1.1, depth: 1.6), materials: [WorldKit.unlit(UIColor(hex: "#1A2040"))])
            gondola.position = [1.0, -2.55, 0]
            root.addChild(gondola)
            let windows = ModelEntity(mesh: .generateBox(width: 3.4, height: 0.35, depth: 1.66), materials: [WorldKit.emissive(UIColor(hex: "#FFD9A6"), intensity: 2.5)])
            windows.position = [1.0, -2.45, 0]
            root.addChild(windows)
            let fx = FXTextures.shared
            let belly = ModelEntity(mesh: .generatePlane(width: 16, height: 5), materials: [FXMaterials.glow(fx.softDisc, tint: primary, opacity: 0.45)])
            belly.position = [0, -1.9, 0]
            belly.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            root.addChild(belly)
            for side: Float in [-1, 1] {
                let plate = ModelEntity(mesh: .generatePlane(width: 8.8, height: 2.6), materials: [WorldKit.unlit(UIColor(hex: "#0B0E1A"))])
                plate.position = [1.0, 0.15, side * 2.26]
                plate.orientation = simd_quatf(angle: side > 0 ? 0 : .pi, axis: [0, 1, 0])
                root.addChild(plate)
                let text = ModelEntity(mesh: .generatePlane(width: 8.4, height: 2.1), materials: [FXMaterials.glow(banner, tint: .white, opacity: 1)])
                text.position = [1.0, 0.15, side * 2.3]
                text.orientation = plate.orientation
                root.addChild(text)
                let rim = ModelEntity(mesh: .generateBox(width: 8.9, height: 0.07, depth: 0.05), materials: [WorldKit.emissive(accent, intensity: 3)])
                rim.position = [1.0, 1.5, side * 2.28]
                root.addChild(rim)
            }
            nav = ModelEntity(mesh: .generatePlane(width: 0.9, height: 0.9), materials: [FXMaterials.glow(fx.coreDisc, tint: .white, opacity: 1)])
            nav.position = [9.1, 0, 0]
            root.addChild(nav)
            tail = ModelEntity(mesh: .generatePlane(width: 0.8, height: 0.8), materials: [FXMaterials.glow(fx.coreDisc, tint: UIColor(hex: "#FF3B3B"), opacity: 1)])
            tail.position = [-8.7, 2.4, 0]
            root.addChild(tail)
        }

        /// Two-state blink, written only when the state flips (it used to set two opacities every frame).
        func blink(time: Float) {
            let t = time.truncatingRemainder(dividingBy: 2.4)
            set(nav, t < 0.12 ? 1 : 0.15)
            set(tail, t > 1.2 && t < 1.32 ? 1 : 0.2)
        }

        private func set(_ lamp: ModelEntity, _ opacity: Float) {
            guard lamp.components[OpacityComponent.self]?.opacity != opacity else { return }
            lamp.components.set(OpacityComponent(opacity: opacity))
        }
    }

    // MARK: - Rooftop furniture

    /// Antenna mast: pole, three cross-bars with dipoles, a red beacon on top (returned so the world can blink it).
    static func antennaMast(height: Float) -> (root: Entity, beacon: ModelEntity) {
        let root = Entity()
        let metal = WorldKit.unlit(UIColor(hex: "#2C3252"))
        let dipoleMesh = MeshResource.generateBox(width: 0.035, height: 0.9, depth: 0.035)
        let pole = ModelEntity(mesh: .generateCylinder(height: height, radius: 0.06), materials: [metal])
        pole.position = [0, height / 2, 0]
        root.addChild(pole)
        for (i, y) in [height - 0.4, height - 1.3, height - 2.3].enumerated() {
            let bar = ModelEntity(mesh: .generateBox(width: 1.7 - Float(i) * 0.25, height: 0.05, depth: 0.05), materials: [metal])
            bar.position = [0, y, 0]
            bar.orientation = simd_quatf(angle: Float(i) * 0.5, axis: [0, 1, 0])
            root.addChild(bar)
            for side: Float in [-1, 1] {
                let dipole = ModelEntity(mesh: dipoleMesh, materials: [metal])
                dipole.position = bar.orientation.act([side * (0.85 - Float(i) * 0.125), 0, 0]) + [0, y + 0.3, 0]
                root.addChild(dipole)
            }
        }
        let base = ModelEntity(mesh: .generateBox(width: 0.7, height: 0.25, depth: 0.7), materials: [concrete("#2E3142")])
        base.position = [0, 0.125, 0]
        root.addChild(base)
        let beacon = ModelEntity(mesh: .generatePlane(width: 0.5, height: 0.5), materials: [FXMaterials.glow(FXTextures.shared.coreDisc, tint: UIColor(hex: "#FF2E2E"), opacity: 1)])
        beacon.position = [0, height + 0.15, 0]
        beacon.components.set(BillboardComponent())
        root.addChild(beacon)
        return (root, beacon)
    }

    /// Rooftop water tank on four legs, conical lid, PBR dark metal (reads the IBL).
    static func waterTank() -> Entity {
        let root = Entity()
        let metal = darkMetal()
        let legH: Float = 2.6
        let legMesh = MeshResource.generateBox(width: 0.16, height: legH, depth: 0.16)
        for (dx, dz) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
            let leg = ModelEntity(mesh: legMesh, materials: [metal])
            leg.position = [dx * 0.95, legH / 2, dz * 0.95]
            root.addChild(leg)
        }
        let brace = ModelEntity(mesh: .generateBox(width: 2.1, height: 0.12, depth: 2.1), materials: [metal])
        brace.position = [0, 1.3, 0]
        root.addChild(brace)
        let tank = ModelEntity(mesh: .generateCylinder(height: 2.4, radius: 1.3), materials: [darkMetal("#464B60")])
        tank.position = [0, legH + 1.2, 0]
        root.addChild(tank)
        let band = ModelEntity(mesh: .generateCylinder(height: 0.1, radius: 1.34), materials: [darkMetal("#5A6078")])
        band.position = [0, legH + 1.9, 0]
        root.addChild(band)
        let lid = ModelEntity(mesh: .generateCone(height: 0.75, radius: 1.36), materials: [darkMetal("#3A3F52")])
        lid.position = [0, legH + 2.4 + 0.375, 0]
        root.addChild(lid)
        return root
    }

    /// Roof-access hut with a steel door and a warm lamp above it (door on local −Z).
    static func accessHut(lampColor: UIColor) -> Entity {
        let root = Entity()
        let hut = ModelEntity(mesh: .generateBox(width: 2.8, height: 2.5, depth: 2.4), materials: [concrete("#474B5E")])
        hut.position = [0, 1.25, 0]
        root.addChild(hut)
        let cap = ModelEntity(mesh: .generateBox(width: 3.0, height: 0.14, depth: 2.6), materials: [concrete("#2F3243")])
        cap.position = [0, 2.57, 0]
        root.addChild(cap)
        let door = ModelEntity(mesh: .generatePlane(width: 0.95, height: 2.05), materials: [darkMetal("#1E2235")])
        door.position = [0.4, 1.025, -1.205]
        root.addChild(door)
        let fixture = ModelEntity(mesh: .generateBox(width: 0.3, height: 0.1, depth: 0.16), materials: [WorldKit.emissive(lampColor, intensity: 3)])
        fixture.position = [0.4, 2.28, -1.24]
        root.addChild(fixture)
        let glow = ModelEntity(mesh: .generatePlane(width: 2.2, height: 2.2), materials: [FXMaterials.glow(FXTextures.shared.softDisc, tint: lampColor, opacity: 0.3)])
        glow.position = [0.4, 1.6, -1.26]
        root.addChild(glow)
        return root
    }

    /// Framed neon sign on a dark backing plate; `sign` is the text plane the world fades in.
    static func mountedSign(sign: ModelEntity, width: Float, height: Float, color: UIColor) -> Entity {
        let mount = Entity()
        let plate = ModelEntity(mesh: .generateBox(width: width + 0.8, height: height + 0.6, depth: 0.25), materials: [WorldKit.unlit(UIColor(hex: "#0A0D1A"))])
        plate.position = [0, 0, -0.2]
        mount.addChild(plate)
        let tube = WorldKit.emissive(color, intensity: 3.5)
        let horizontal = MeshResource.generateBox(width: width + 0.8, height: 0.06, depth: 0.06)
        let vertical = MeshResource.generateBox(width: 0.06, height: height + 0.6, depth: 0.06)
        for (w, h, x, y) in [(width + 0.8, 0.06, 0, (height + 0.6) / 2), (width + 0.8, 0.06, 0, -(height + 0.6) / 2), (0.06, height + 0.6, (width + 0.8) / 2, 0), (0.06, height + 0.6, -(width + 0.8) / 2, 0)] as [(Float, Float, Float, Float)] {
            let bar = ModelEntity(mesh: w > h ? horizontal : vertical, materials: [tube])
            bar.position = [x, y, -0.04]
            mount.addChild(bar)
        }
        sign.position = [0, 0, 0.02]
        mount.addChild(sign)
        // One hierarchical bloom scope for the whole sign (frame + text) instead of five: the scope only decides
        // which pixels are gathered, and the four neon bars and the text are already inside this one.
        mount.components.set(BloomComponent(scope: .hierarchical))
        return mount
    }

    // MARK: - Billboard

    /// The device's theme bitmap (480 × 640, the same image the LCD shows and ARKit tracks) with the LCD's rounded
    /// corners cut to transparent, so the 3:4 board on the tower shows the screen and not a black frame.
    /// **v4 B5 §5.** The billboard's texture through `WorldKit`'s cache (key `billboard-<bitmap>`, mipmaps as before): the
    /// preheat renders and uploads it ahead; nil when the bitmap is missing.
    static func billboardTexture(themeBitmap name: String) -> TextureResource? {
        guard UIImage(named: name) != nil else { return nil }
        return WorldKit.customTexture(key: "billboard-\(name)", mipmaps: true) { billboardImage(themeBitmap: name) }
    }

    nonisolated static func billboardJob(themeBitmap name: String) -> WorldKit.TextJob {
        WorldKit.TextJob(key: "billboard-\(name)", mipmaps: true) { billboardImage(themeBitmap: name) }
    }

    nonisolated static func billboardImage(themeBitmap name: String) -> CGImage? {
        guard let cg = UIImage(named: name)?.cgImage else { return nil }
        let manifest = PassportManifest.shared
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let radius = CGFloat(manifest.cornerRadiusPx) * w / CGFloat(max(1, manifest.pixelSize.first ?? 240))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: format)
        return renderer.image { ctx in
            let c = ctx.cgContext
            c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: radius, cornerHeight: radius, transform: nil))
            c.clip()
            // CGContext draws with a flipped Y; UIKit's renderer already compensates for UIImage drawing, so use UIImage.
            UIImage(cgImage: cg).draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }.cgImage
    }
}
