import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import RealityKit
import UIKit

/// The registration layer (design doc §3.0): a bitmap identical to what the device shows, pasted back onto
/// the `ImageAnchor` at its physical size. From the moment it fades in, every pixel of the "card" is ours to
/// animate: the reveal starts on the screen instead of above it.
///
/// Three textures are derived per theme screen at start (`prepare(themes:)`), so a theme handover is only a
/// material swap (`configure(theme:)`):
/// * `paper` — desaturated / darkened so the fade-in is invisible against the real screen,
/// * `lit`   — pushed brighter with richer ink: the "backlight turns on" look,
/// * `holo`  — 2× edge-detected line art with alpha, tinted by the look (the line-art wireframe).
///
/// LCD note: `paper` / `lit` were designed for matte e-paper. On the self-lit AI Passport a 2 mm pose error
/// shows as ghosting, so `litLayers = false` (`--overlay-lit off`) skips them and the reveals start at the
/// holo / ink stage. Every texture is masked to the LCD's rounded rect (the driver blacks those pixels).
///
/// Layout in anchor space (image lies in X-Z, +Y normal, +Z toward the reader / bottom edge):
///
///     overlay (y +0.0006)
///     ├─ paper  quad (w × h)
///     ├─ lit    quad, ClippingComponent (unscanned part, +Z side of the scan line)
///     ├─ holo   quad, ClippingComponent (scanned part, −Z side)   ← rises and flies as the "wireframe card"
///     ├─ scan   emissive bar + spark emitter, driven by ScanRevealComponent
///     ├─ edge   rounded-rect glow ring around the wireframe (lift-off "light leak")
///     └─ socket rounded-rect glow that stays on the screen afterwards ("插座光")
@MainActor
final class RegistrationOverlay {
    // `nonisolated`: ScanRevealSystem (a RealityKit System, off the main actor) looks entities up by these
    // names; a plain static let on a @MainActor type is an error in the Swift 6 language mode.
    nonisolated static let litName = "overlay.lit"
    nonisolated static let holoName = "overlay.holo"
    nonisolated static let scanName = "overlay.scan"

    struct Textures {
        var paper: TextureResource
        var lit: TextureResource
        var holo: TextureResource
    }

    let root = Entity()
    let paper: ModelEntity
    let lit: ModelEntity
    /// Parent of the holo quad so the flight (position / rotation / scale) does not disturb the clipping quad.
    let holoGroup = Entity()
    let holo: ModelEntity
    let scan: ModelEntity
    let sparks = Entity()
    let edge: ModelEntity
    let socket: ModelEntity

    private(set) var footprint: SIMD2<Float>
    /// The real device's footprint (V3-2a H0): what the socket **ring** is built around.
    private(set) var device: SIMD2<Float> = DeviceFootprint.aiPassport.size
    /// **v4 B1.** Where the case's centre is in this rig's frame (the screen frame S): the paper / lit / holo quads
    /// are the *screen* and stay on S's origin; the socket ring hugs the *case* and is centred here.
    private(set) var caseCenter: SIMD3<Float> = .zero
    private(set) var theme: PassportManifest.Theme
    private var cache: [String: Textures] = [:]
    private var tint: UIColor = .white
    private var socketTint: UIColor = .white
    /// V3-2a H0 socket ring: clear gap outside the footprint prism (which is the device + 3 mm), and the
    /// ring's own thickness.
    static let socketGap: Float = 0.005
    static let socketThickness: Float = 0.0025
    /// `--socket ring|off`: `off` keeps the device completely bare when the card is folded away.
    static var socketEnabled = true
    /// V3-2a H0: how bright the ring is when the card is folded away ("it is alive"), and while a summon
    /// is bringing it back.
    static let socketFolded: Float = 0.35
    static let socketSummon: Float = 0.6

    /// The one place the ring is switched on, so `--socket off` cannot be bypassed by a caller that writes
    /// `socket.isEnabled = true` itself.
    func showSocket(_ on: Bool) {
        socket.isEnabled = on && RegistrationOverlay.socketEnabled
    }
    /// Whether the paper / lit backlight layers take part in the reveals (`--overlay-lit off` → false).
    var litLayers = true

    /// Set to true if the bitmap appears upside-down against the real card on device.
    static let flipZ = false

    init(footprint: SIMD2<Float>, theme: PassportManifest.Theme) {
        self.footprint = footprint
        self.theme = theme
        let fx = FXTextures.shared
        paper = ModelEntity(mesh: .generatePlane(width: footprint.x, depth: footprint.y), materials: [UnlitMaterial(color: .white)])
        lit = ModelEntity(mesh: .generatePlane(width: footprint.x, depth: footprint.y), materials: [UnlitMaterial(color: .white)])
        holo = ModelEntity(mesh: .generatePlane(width: footprint.x, depth: footprint.y), materials: [UnlitMaterial(color: .white)])
        scan = ModelEntity(mesh: .generatePlane(width: footprint.x + 0.006, depth: 0.003), materials: [RegistrationOverlay.scanMaterial(.cyan)])
        edge = ModelEntity(mesh: .generatePlane(width: footprint.x + 0.008, depth: footprint.y + 0.008),
                           materials: [FXMaterials.glow(fx.roundedRing(aspect: footprint.x / footprint.y), tint: .white, opacity: 0.8)])
        // V3-2a H0: the socket used to be a 1.15 × **screen** plane glowing straight through the LCD. It is
        // now a thin outline ring *outside* the device, so "the card is folded away but the passport is still
        // alive" is a hairline around bare hardware.
        socket = ModelEntity(mesh: FXMeshes.roundedRectRing(width: 0.1, height: 0.1, radius: 0.01, thickness: 0.0025),
                             materials: [FXMaterials.flat(tint: .white, opacity: 1)])

        root.position = [0, 0.0006, 0]
        paper.name = "overlay.paper"
        edge.name = "overlay.edge"
        paper.position = [0, 0.0000, 0]
        lit.position = [0, 0.0002, 0]
        lit.name = RegistrationOverlay.litName
        holo.name = RegistrationOverlay.holoName
        holo.position = [0, 0.0004, 0]
        scan.name = RegistrationOverlay.scanName
        scan.position = [0, 0.0009, footprint.y / 2]
        edge.position = [0, -0.0001, 0]
        socket.position = [0, -0.0003, 0]
        socket.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])    // the ring mesh lies in X-Y
        socket.name = RegistrationOverlay.socketName
        socket.components.set(InputTargetComponent(allowedInputTypes: .all))
        socket.components[InputTargetComponent.self]?.isEnabled = false
        socket.components.set(CollisionComponent(shapes: [
            .generateBox(width: footprint.x * 1.3, height: 0.012, depth: footprint.y * 1.3),
        ]))
        buildSocket()

        if RegistrationOverlay.flipZ {
            for quad in [paper, lit, holo] { quad.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0]) }
        }

        // Soft 4 mm edge along the scan direction (Z); the bounds themselves are written by ScanRevealSystem.
        for quad in [lit, holo] {
            var clipping = ClippingComponent(bounds: BoundingBox(min: [-1, -1, -1], max: [1, 1, 1]))
            clipping.featheredEdge = .init(symmetricEdgeInset: [0, 0, 0.004], falloff: .cubic)
            clipping.shouldClipSelf = true
            clipping.shouldClipChildren = false
            quad.components.set(clipping)
        }

        // Scan line: emissive bar with hierarchical bloom, sparks trailing it.
        scan.components.set(BloomComponent(scope: .hierarchical))
        var bloom = BloomOptionsComponent()
        bloom.strength = 0.9
        bloom.threshold = 0.8
        bloom.blurRadius = 2
        scan.components.set(bloom)
        sparks.position = [0, 0.001, 0]
        sparks.name = "overlay.sparks"
        sparks.components.set(RegistrationOverlay.sparkEmitter(width: footprint.x, sprite: fx.particle, tint: .white))
        scan.addChild(sparks)

        holoGroup.addChild(holo)
        holoGroup.addChild(edge)
        root.addChild(paper)
        root.addChild(lit)
        root.addChild(holoGroup)
        root.addChild(scan)
        root.addChild(socket)

        for e in [paper, lit, holoGroup, scan, edge, socket] { e.isEnabled = false }
        root.isEnabled = false
    }

    // MARK: - Configuration

    func configure(device: SIMD2<Float>, caseCenter: SIMD3<Float> = .zero) {
        guard device != self.device || caseCenter != self.caseCenter else { return }
        self.device = device
        self.caseCenter = caseCenter
        socket.position = [caseCenter.x, -0.0003, caseCenter.z]
        buildSocket()
    }

    /// The socket outline: inner edge `socketGap` outside the device's footprint (which already carries the
    /// audit's 3 mm margin), 2.5 mm thick, rounded corners. `--socket off` never enables it at all.
    private func buildSocket() {
        let inner = SIMD2<Float>(device.x / 2 + RegistrationOverlay.socketGap,
                                 device.y / 2 + RegistrationOverlay.socketGap)
        let thickness = RegistrationOverlay.socketThickness
        socket.model?.mesh = FXMeshes.roundedRectRing(width: (inner.x + thickness) * 2,
                                                      height: (inner.y + thickness) * 2,
                                                      radius: 0.008 + thickness, thickness: thickness)
        socket.model?.materials = [FXMaterials.flat(tint: socketTint, opacity: 1)]
        socket.components.set(FootprintProbeComponent(.hole(inner)))
        socket.components.set(CollisionComponent(shapes: [
            .generateBox(width: (inner.x + thickness) * 2 + 0.02, height: 0.014,
                         depth: (inner.y + thickness) * 2 + 0.02),
        ]))
    }

    /// Derive the textures of every theme screen up front (≈ 40–80 ms each) so handovers never stall.
    func prepare(themes: [PassportManifest.Theme]) {
        let start = Date()
        for t in themes where cache[t.bitmap] == nil {
            if let textures = RegistrationOverlay.makeTextures(named: t.bitmap) {
                cache[t.bitmap] = textures
            }
        }
        print(String(format: "[theme] overlay textures for %d themes in %.0f ms", cache.count, Date().timeIntervalSince(start) * 1000))
        applyTextures()
    }

    /// Switch to another theme screen: a material swap, no re-meshing (every theme has the same footprint).
    func configure(theme: PassportManifest.Theme) {
        guard theme.id != self.theme.id else { return }
        self.theme = theme
        applyTextures()
    }

    func apply(look: HologramLook) {
        tint = look.tint
        let fx = FXTextures.shared
        scan.model?.materials = [RegistrationOverlay.scanMaterial(look.highlight)]
        edge.model?.materials = [FXMaterials.glow(fx.roundedRing(aspect: footprint.x / footprint.y), tint: look.tint, opacity: 0.8)]
        socketTint = look.secondaryTint
        buildSocket()
        sparks.components.set(RegistrationOverlay.sparkEmitter(width: footprint.x, sprite: fx.particle, tint: look.highlight))
        applyTextures()
    }

    /// Textures of the current theme (derived on demand if `prepare` has not run for it).
    func applyTextures() {
        if cache[theme.bitmap] == nil {
            cache[theme.bitmap] = RegistrationOverlay.makeTextures(named: theme.bitmap)
        }
        guard let textures = cache[theme.bitmap] else { return }
        var paperMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        paperMaterial.color = .init(tint: .white, texture: .init(textures.paper))
        paperMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
        paperMaterial.opacityThreshold = nil
        paperMaterial.writesDepth = false
        paper.model?.materials = [paperMaterial]

        var litMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        litMaterial.color = .init(tint: .white, texture: .init(textures.lit))
        litMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
        litMaterial.opacityThreshold = nil
        litMaterial.writesDepth = false
        lit.model?.materials = [litMaterial]

        var holoMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        holoMaterial.color = .init(tint: tint, texture: .init(textures.holo))
        holoMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
        holoMaterial.opacityThreshold = nil
        holoMaterial.faceCulling = .none
        holoMaterial.writesDepth = false
        holo.model?.materials = [holoMaterial]
    }

    // MARK: - Reset for a new reveal

    /// Put every layer back to "nothing visible, scan at the bottom edge". With `litLayers == false` the paper /
    /// lit quads stay disabled and the reveal starts at the holo / ink stage.
    func resetForReveal() {
        root.isEnabled = true
        paper.isEnabled = litLayers
        lit.isEnabled = litLayers
        holoGroup.isEnabled = true
        scan.isEnabled = false
        edge.isEnabled = false
        socket.isEnabled = false
        paper.components.set(OpacityComponent(opacity: 0))
        lit.components.set(OpacityComponent(opacity: 0))
        holoGroup.transform = Transform(scale: [1, 1, 1], rotation: simd_quatf(angle: 0, axis: [1, 0, 0]), translation: .zero)
        holoGroup.components.set(OpacityComponent(opacity: 1))
        holo.components.set(OpacityComponent(opacity: 1))
        edge.components.set(OpacityComponent(opacity: 0))
        ScanRevealSystem.write(progress: 0, to: self)
    }

    /// Everything off. `keepSocket` leaves the root and the socket glow alive: after an explicit dismiss the
    /// socket is the only thing on the desk, and it is what the wearer taps to bring the card back.
    func hideAll(keepSocket: Bool = false) {
        guard keepSocket else {
            root.isEnabled = false
            return
        }
        root.isEnabled = true
        for e in [paper, lit, holoGroup, scan, edge] { e.isEnabled = false }
        socket.isEnabled = RegistrationOverlay.socketEnabled
    }

    /// Name of the socket glow, so the RealityView gesture can recognise a tap on it.
    static let socketName = "overlay.socket"

    /// Whether the socket accepts gaze + pinch (only while the card is dismissed — otherwise a tap on the device
    /// would fight the projector's base ring, which sits right on top of it).
    func setSocketTappable(_ enabled: Bool) {
        // **V3-4 §4** `--device-taps off` (the default): nothing drawn on the hardware takes a pinch at all,
        // because a hand closing round the passport is a pinch as far as visionOS is concerned.
        let on = enabled && RegistrationOverlay.deviceTapsEnabled
        socket.components[InputTargetComponent.self]?.isEnabled = on
        socket.components[HoverEffectComponent.self] = on ? HoverEffectComponent() : nil
    }

    /// `--device-taps on|off`, written once by `AppModel` before the space opens.
    static var deviceTapsEnabled = false

    // MARK: - Materials / textures

    private static func scanMaterial(_ color: UIColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .white, texture: nil)
        material.emissiveColor = .init(color: color, texture: nil)
        material.emissiveIntensity = 6
        material.blending = .transparent(opacity: .init(floatLiteral: 0.95))
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }

    private static func sparkEmitter(width: Float, sprite: TextureResource, tint: UIColor) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .box
        p.emitterShapeSize = [width, 0.001, 0.003]
        p.birthLocation = .volume
        p.birthDirection = .local
        p.emissionDirection = [0, 1, 0]
        p.speed = 0.1
        p.speedVariation = 0.05
        p.isEmitting = false
        p.mainEmitter.image = sprite
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = 400
        p.mainEmitter.lifeSpan = 0.4
        p.mainEmitter.lifeSpanVariation = 0.15
        p.mainEmitter.size = 0.001
        p.mainEmitter.sizeVariation = 0.0006
        p.mainEmitter.color = .evolving(start: .single(.white), end: .single(tint.withAlphaComponent(0)))
        p.mainEmitter.opacityCurve = .quickFadeInOut
        p.mainEmitter.spreadingAngle = 0.4
        p.mainEmitter.isLightingEnabled = false
        return p
    }

    /// Alpha mask of the LCD's rounded rect at `size` (pixels), inset by `inset` pixels.
    private static func roundedMask(size: CGSize, inset: CGFloat) -> CIImage {
        let manifest = PassportManifest.shared
        let scale = size.width / CGFloat(max(1, manifest.pixelSize.first ?? 240))
        let radius = max(0, CGFloat(manifest.cornerRadiusPx) * scale - inset)
        let renderer = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f }())
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset), cornerRadius: radius).fill()
        }
        return CIImage(cgImage: image.cgImage!)
    }

    private static func masked(_ image: CIImage?, mask: CIImage) -> CIImage? {
        guard let image else { return nil }
        let blend = CIFilter.blendWithAlphaMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: image.extent)
        blend.maskImage = mask
        return blend.outputImage?.cropped(to: image.extent)
    }

    /// One GPU CIContext for every derivation (a context is expensive; three per controller init was the worst
    /// moment to pay for it).
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func makeTextures(named name: String) -> Textures? {
        guard let uiImage = UIImage(named: name), let cg = uiImage.cgImage else {
            print("[overlay] bitmap \(name) not found in the asset catalog")
            return nil
        }
        let context = RegistrationOverlay.ciContext
        let source = CIImage(cgImage: cg)
        let size = CGSize(width: cg.width, height: cg.height)

        let paperFilter = CIFilter.colorControls()
        paperFilter.inputImage = source
        paperFilter.saturation = 0.75
        paperFilter.brightness = -0.15
        paperFilter.contrast = 1.0

        let litSat = CIFilter.colorControls()
        litSat.inputImage = source
        litSat.saturation = 1.2
        litSat.brightness = 0
        litSat.contrast = 1.05
        let litExposure = CIFilter.exposureAdjust()
        litExposure.inputImage = litSat.outputImage
        litExposure.ev = 0.35

        let scaled = CIFilter.lanczosScaleTransform()
        scaled.inputImage = source
        scaled.scale = 2
        scaled.aspectRatio = 1
        let edges = CIFilter.edges()
        edges.inputImage = scaled.outputImage
        edges.intensity = 12
        let edgeContrast = CIFilter.colorControls()
        edgeContrast.inputImage = edges.outputImage
        edgeContrast.saturation = 0
        edgeContrast.contrast = 3
        edgeContrast.brightness = 0.05
        let mask = CIFilter.maskToAlpha()
        mask.inputImage = edgeContrast.outputImage
        let holoExtent = source.extent.applying(CGAffineTransform(scaleX: 2, y: 2))
        // The LCD driver blacks every pixel outside the rounded rect: the paper / lit quads are cut to it (the
        // corners show the real device) and the line art is inset a little further so the mask's own edge does
        // not turn into a bright arc.
        let cardMask = roundedMask(size: size, inset: 0)
        let holoMask = roundedMask(size: CGSize(width: size.width * 2, height: size.height * 2), inset: 6)
        let holoImage = masked(mask.outputImage?.cropped(to: holoExtent), mask: holoMask)

        func render(_ image: CIImage?, name: String, extent: CGRect? = nil) -> TextureResource? {
            guard let image, let out = context.createCGImage(image, from: extent ?? image.extent) else { return nil }
            return try? TextureResource(image: out, withName: name, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        }
        guard let paper = render(masked(paperFilter.outputImage, mask: cardMask), name: "\(name).paper"),
              let lit = render(masked(litExposure.outputImage, mask: cardMask), name: "\(name).lit"),
              let holo = render(holoImage, name: "\(name).holo", extent: holoExtent) else {
            print("[overlay] texture derivation failed for \(name)")
            return nil
        }
        return Textures(paper: paper, lit: lit, holo: holo)
    }
}

// MARK: - Scan reveal

/// Sweeps the scan line from the bottom edge (+Z) to the top (−Z) over `duration`, writing the
/// clipping bounds of the lit (unscanned) and holo (scanned) quads and moving the scan bar.
struct ScanRevealComponent: Component {
    var width: Float
    var depth: Float
    var delay: Float = 0
    var duration: Float
    var elapsed: Float = 0
}

final class ScanRevealSystem: System {
    private static let query = EntityQuery(where: .has(ScanRevealComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("scanReveal", since: cpuStart) }
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: ScanRevealSystem.query, updatingSystemWhen: .rendering) {
            guard var scan = entity.components[ScanRevealComponent.self] else { continue }
            scan.elapsed += dt
            let raw = (scan.elapsed - scan.delay) / max(0.001, scan.duration)
            let progress = max(0, min(1, raw))
            ScanRevealSystem.write(progress: progress, width: scan.width, depth: scan.depth, root: entity)
            if raw >= 1 {
                entity.components.remove(ScanRevealComponent.self)
            } else {
                entity.components.set(scan)
            }
        }
    }

    @MainActor
    static func write(progress: Float, to overlay: RegistrationOverlay) {
        write(progress: progress, width: overlay.footprint.x, depth: overlay.footprint.y, root: overlay.root)
    }

    /// `progress` 0 = nothing scanned (scan bar at +Z / bottom edge), 1 = fully scanned.
    static func write(progress: Float, width: Float, depth: Float, root: Entity) {
        let half = depth / 2
        let lineZ = half - progress * depth
        let bigX = width, bigY: Float = 0.05
        if let lit = root.findEntity(named: RegistrationOverlay.litName) {
            var c = lit.components[ClippingComponent.self] ?? ClippingComponent(bounds: .empty)
            c.bounds = BoundingBox(min: [-bigX, -bigY, -half - 0.01], max: [bigX, bigY, lineZ])
            lit.components.set(c)
        }
        if let holo = root.findEntity(named: RegistrationOverlay.holoName) {
            var c = holo.components[ClippingComponent.self] ?? ClippingComponent(bounds: .empty)
            c.bounds = BoundingBox(min: [-bigX, -bigY, lineZ], max: [bigX, bigY, half + 0.01])
            holo.components.set(c)
        }
        if let scan = root.findEntity(named: RegistrationOverlay.scanName) {
            scan.position = [0, scan.position.y, lineZ]
            scan.isEnabled = progress > 0 && progress < 1
            if var emitter = scan.children.first?.components[ParticleEmitterComponent.self] {
                emitter.isEmitting = scan.isEnabled
                scan.children.first?.components.set(emitter)
            }
        }
    }
}
