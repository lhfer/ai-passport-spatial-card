import CoreGraphics
import Foundation
import ImageIO
import QuartzCore
import RealityKit
import UIKit

/// A note cover with depth (A3 目标 2.3): hand it an image and it picks the best of three presentations, builds an
/// entity that fits a card frame, and logs which one it used and what each step cost.
///
/// | mode | what the eye gets | where it works |
/// | --- | --- | --- |
/// | `scene` | Apple's spatial scene — `ImagePresentationComponent.Spatial3DImage`, generated from the flat cover | headset only: the simulator's `generate()` throws `unableToGenerateSpatial3DImage` |
/// | `lift` | the subject (Vision's foreground instance mask) lifted 8–15 mm off a defocused, hole-filled background | anywhere a mask exists: live Vision on the headset, a bundled mask elsewhere |
/// | `flat` | the cover as a texture | always |
///
/// The frame is never empty: `flat` is up the moment the image is decoded and every better mode cross-fades in over
/// it when it is ready — which is also the product's "tap a card, it opens in place" rhythm, where the spatial scene
/// takes seconds to generate and must not hold the gesture hostage.
///
/// Geometry: `root`'s content spans `size` in its local x–y plane, centred, facing +Z (a `lift`'s subject stands in
/// front of that plane by `parallax.lift`). Put it on a frame's face.
@MainActor
final class LivingCover {
    /// One cover image. `imageSource` feeds `Spatial3DImage`, `image` everything else.
    struct Source {
        let name: String
        let image: CGImage
        let imageSource: CGImageSource

        /// `fake-cover-3` (a file at the bundle root, any of jpg / png / heic), `Avatar` (an asset-catalog image),
        /// an absolute path or `~/Documents/…`.
        static func named(_ name: String, bundle: Bundle = .main) -> Source? {
            let fileManager = FileManager.default
            let expanded = (name as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                return file(URL(fileURLWithPath: expanded))
            }
            for ext in ["jpg", "jpeg", "png", "heic"] {
                if let url = bundle.url(forResource: name, withExtension: ext) { return file(url) }
            }
            if let asset = UIImage(named: name, in: bundle, with: nil), let data = asset.pngData(),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return Source(name: name.lowercased(), image: image, imageSource: source)
            }
            return nil
        }

        static func file(_ url: URL) -> Source? {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
            return Source(name: url.deletingPathExtension().lastPathComponent, image: image, imageSource: source)
        }
    }

    /// What one `load` did, for the log line and the report's numbers.
    struct Report {
        var name: String
        var request: V4.CoverRequest
        var mode: V4.CoverMode = .flat
        var flatMs: Double = 0
        var sceneMs: Double?
        var sceneNote: String?
        var maskMs: Double?
        var maskNote: String?
        var maskSource: String?
        var coverage: Float?
        var verdict: String?
        var layersMs: Double?
        var texturesMs: Double?
        var totalMs: Double = 0

        var line: String {
            var parts = ["\(name) request=\(request.rawValue) → \(mode.rawValue)", String(format: "flat %.1f ms", flatMs)]
            if let sceneMs { parts.append(String(format: "scene %@ %.1f ms", sceneNote ?? "", sceneMs)) }
            if let maskMs {
                var mask = String(format: "mask %.1f ms", maskMs)
                if let maskSource { mask += " [\(maskSource)]" }
                if let maskNote { mask += " (\(maskNote))" }
                if let coverage { mask += String(format: " coverage %.3f", coverage) }
                if let verdict { mask += " → \(verdict)" }
                parts.append(mask)
            }
            if let layersMs { parts.append(String(format: "layers %.1f ms", layersMs)) }
            if let texturesMs { parts.append(String(format: "textures %.1f ms", texturesMs)) }
            parts.append(String(format: "total %.1f ms", totalMs))
            return parts.joined(separator: " · ")
        }
    }

    /// Learned once per run and shared by every cover (see `V4.CoverCapabilities`).
    static var capabilities = V4.CoverCapabilities()
    /// Consecutive failures per capability. On the simulator the first failure is systemic (no generator, no Vision
    /// inference context); on a headset one odd image must not switch a mode off for every later cover, so it takes
    /// two in a row.
    private static var sceneFailures = 0
    private static var maskFailures = 0
    #if targetEnvironment(simulator)
    private static let failuresToGiveUp = 1
    #else
    private static let failuresToGiveUp = 2
    #endif

    private static func noteScene(_ error: String?) {
        guard let error else {
            sceneFailures = 0
            capabilities.scene = .available
            return
        }
        sceneFailures += 1
        if sceneFailures >= failuresToGiveUp { capabilities.scene = .unavailable(error) }
    }

    private static func noteMask(_ state: V4.CoverCapabilities.State) {
        guard case .unavailable = state else {
            maskFailures = 0
            capabilities.liveMask = state
            return
        }
        maskFailures += 1
        if maskFailures >= failuresToGiveUp { capabilities.liveMask = state }
    }

    let root = Entity()
    let size: SIMD2<Float>
    var parallax: V4.CoverParallax
    /// Cross-fade between presentations (the art bible's "medium" motion: 0.35–0.60 s).
    var fadeDuration: Float = 0.45
    private(set) var mode: V4.CoverMode?
    private(set) var report: Report?
    /// The current presentation's holder (a flat quad, the three lift layers, or the image presentation).
    private var current: Entity?
    /// The spatial scene holder, kept so its component can be inspected (`presentationScreenSize`, viewing mode).
    private(set) var presentation: Entity?

    init(size: SIMD2<Float>, lift: Float = 0.012) {
        self.size = size
        parallax = V4.CoverParallax(size: size, lift: lift)
        root.name = "livingCover"
    }

    /// Shows `source` using the best mode `request` allows, and returns what happened. Safe to call again: the new
    /// cover cross-fades over the old one.
    @discardableResult
    func load(_ source: Source, request: V4.CoverRequest) async -> Report {
        let start = CACurrentMediaTime()
        var report = Report(name: source.name, request: request)
        let attempts = V4.CoverPlanner.attempts(for: request, capabilities: Self.capabilities)

        // 1. Flat, immediately — unless the request is the spatial scene itself, which shows its own mono image.
        if attempts.contains(.flat) || request == .auto {
            if let flat = try? makeFlat(source.image) {
                // Cross-fade only when replacing an earlier cover; a fresh frame takes the flat cover at once.
                show(flat, as: .flat, fade: current != nil)
            }
            report.flatMs = ms(since: start)
        }

        // 2. The spatial scene. Explicitly requested: the post-generate flow (component first, then generate — the
        // system draws its own generation animation). Automatic: pre-generate, and cross-fade only on success.
        var sceneTask: Task<(holder: Entity?, note: String, ms: Double), Never>?
        if attempts.contains(.scene) {
            if request == .scene {
                let t0 = CACurrentMediaTime()
                let (holder, note) = await presentScene(source, pregenerate: false)
                report.sceneMs = ms(since: t0)
                report.sceneNote = note
                if let holder {
                    show(holder, as: .scene, fade: false)
                    report.mode = .scene
                }
            } else {
                sceneTask = Task { @MainActor [weak self] in
                    guard let self else { return (nil, "cancelled", 0) }
                    let t0 = CACurrentMediaTime()
                    let (holder, note) = await self.presentScene(source, pregenerate: true)
                    return (holder, note, self.ms(since: t0))
                }
            }
        }

        // 3. The lift, while the scene generates.
        if attempts.contains(.lift) {
            await lift(source, into: &report)
        }

        // 4. On the headset this is where seconds pass; the lift (or flat) is already on show meanwhile.
        if let sceneTask {
            let scene = await sceneTask.value
            report.sceneMs = scene.ms
            report.sceneNote = scene.note
            if let holder = scene.holder {
                show(holder, as: .scene, fade: true)
                report.mode = .scene
            }
        }
        report.totalMs = ms(since: start)
        self.report = report
        return report
    }

    // MARK: - Modes

    private func makeFlat(_ image: CGImage) throws -> Entity {
        let texture = try TextureResource(image: image, options: .init(semantic: .color))
        // No tone map: a cover is an image, and should look like the one the system's own presentation draws.
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: .white, texture: .init(texture))
        let quad = ModelEntity(mesh: .generatePlane(width: size.x, height: size.y, cornerRadius: min(size.x, size.y) * 0.025),
                               materials: [material])
        quad.name = "livingCover.flat"
        return quad
    }

    /// Spatial3DImage → generate → ImagePresentationComponent, sized to fit `size`. Returns the holder (nil when
    /// generation failed in pre-generate mode) and a note for the log.
    private func presentScene(_ source: Source, pregenerate: Bool) async -> (Entity?, String) {
        let image: ImagePresentationComponent.Spatial3DImage
        do {
            image = try await ImagePresentationComponent.Spatial3DImage(imageSource: source.imageSource)
        } catch {
            Self.noteScene("init: \(error)")
            return (nil, "✗ Spatial3DImage(imageSource:) threw \(error)")
        }
        let holder = Entity()
        holder.name = "livingCover.scene"
        if !pregenerate {
            attachPresentation(image, to: holder)
        }
        do {
            try await image.generate()
            Self.noteScene(nil)
        } catch {
            Self.noteScene(String(describing: error))
            return (pregenerate ? nil : holder, "✗ generate() threw \(error)")
        }
        if pregenerate {
            attachPresentation(image, to: holder)
        } else if var component = holder.components[ImagePresentationComponent.self] {
            component.desiredViewingMode = .spatial3D
            holder.components.set(component)
        }
        let viewing = holder.components[ImagePresentationComponent.self]?.viewingMode
        return (holder, "✓ \(viewing.map { "\($0)" } ?? "?")")
    }

    private func attachPresentation(_ image: ImagePresentationComponent.Spatial3DImage, to holder: Entity) {
        var component = ImagePresentationComponent(spatial3DImage: image)
        component.desiredViewingMode = .spatial3D
        // `screenHeight` is the one size knob: the width follows the image's aspect. Fit the cover's box.
        component.screenHeight = size.y
        holder.components.set(component)
        if let placed = holder.components[ImagePresentationComponent.self] {
            let screen = placed.presentationScreenSize
            if screen.x > size.x * 1.001, screen.x > 0 {
                var fitted = placed
                fitted.screenHeight = size.y * size.x / screen.x
                holder.components.set(fitted)
            }
        }
        presentation = holder
    }

    private func lift(_ source: Source, into report: inout Report) async {
        let name = source.name
        let image = source.image
        let parallax = parallax
        let liveState = Self.capabilities.liveMask
        let t0 = CACurrentMediaTime()
        // Off the main actor: Vision and vImage.
        let result = await Task.detached(priority: .userInitiated) { () -> LiftResult in
            var result = LiftResult()
            let pixels: LivingCoverLayers.Pixels
            do {
                pixels = try LivingCoverLayers.decode(image)
            } catch {
                result.note = "decode failed"
                return result
            }
            let maskStart = CACurrentMediaTime()
            var mask: LivingCoverLayers.Mask?
            if !liveState.isUnavailable {
                do {
                    mask = try LivingCoverLayers.liveMask(for: image)
                    result.live = .available
                } catch LivingCoverLayers.Failure.noForeground {
                    result.live = .available
                    result.note = "live: no foreground"
                } catch {
                    result.live = .unavailable(String(describing: error))
                    result.note = "live ✗ \(error)"
                }
            } else {
                result.note = "live skipped (unavailable)"
            }
            if mask == nil, let bundled = LivingCoverLayers.bundledMask(named: name, width: pixels.width, height: pixels.height) {
                mask = bundled
            }
            result.maskMs = (CACurrentMediaTime() - maskStart) * 1000
            guard let mask else { return result }
            result.maskSource = mask.source
            let stats = V4.CoverMaskStats.measure(mask.pixels, width: mask.width, height: mask.height)
            result.stats = stats
            result.verdict = stats.verdict()
            guard result.verdict == .lift else { return result }
            let layersStart = CACurrentMediaTime()
            result.layers = try? LivingCoverLayers.makeLayers(pixels, mask: mask, parallax: parallax)
            result.layersMs = (CACurrentMediaTime() - layersStart) * 1000
            return result
        }.value

        if let live = result.live { Self.noteMask(live) }
        report.maskMs = result.maskMs ?? ms(since: t0)
        report.maskNote = result.note
        report.maskSource = result.maskSource
        report.coverage = result.stats?.coverage
        report.verdict = result.verdict.map { "\($0)" } ?? (result.maskSource == nil ? "no mask" : nil)
        report.layersMs = result.layersMs
        guard let layers = result.layers else { return }
        let texturesStart = CACurrentMediaTime()
        guard let holder = try? makeLift(layers) else { return }
        report.texturesMs = ms(since: texturesStart)
        show(holder, as: .lift, fade: true)
        report.mode = .lift
    }

    private struct LiftResult: @unchecked Sendable {
        var live: V4.CoverCapabilities.State?
        var note: String?
        var maskMs: Double?
        var maskSource: String?
        var stats: V4.CoverMaskStats?
        var verdict: V4.CoverMaskStats.Verdict?
        var layers: LivingCoverLayers.Layers?
        var layersMs: Double?
    }

    private func makeLift(_ layers: LivingCoverLayers.Layers) throws -> Entity {
        let holder = Entity()
        holder.name = "livingCover.lift"
        let corner = min(size.x, size.y) * 0.025

        var backgroundMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        // 8 % darker than the cover: separates the lifted subject from its backdrop without looking dimmed.
        backgroundMaterial.color = .init(tint: UIColor(white: 0.92, alpha: 1),
                                         texture: .init(try TextureResource(image: layers.background,
                                                                            options: .init(semantic: .color))))
        // The brief's "slightly enlarged": a texture zoom about the centre, so nothing overhangs the frame.
        let zoom = parallax.backgroundZoom
        backgroundMaterial.textureCoordinateTransform = .init(offset: SIMD2<Float>(repeating: (1 - 1 / zoom) / 2),
                                                              scale: SIMD2<Float>(repeating: 1 / zoom))
        let background = ModelEntity(mesh: .generatePlane(width: size.x, height: size.y, cornerRadius: corner),
                                     materials: [backgroundMaterial])
        background.name = "livingCover.lift.background"
        holder.addChild(background)

        var shadowMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        shadowMaterial.color = .init(tint: .black, texture: .init(try TextureResource(image: layers.shadow,
                                                                                     options: .init(semantic: .color))))
        shadowMaterial.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        shadowMaterial.writesDepth = false
        let shadow = ModelEntity(mesh: .generatePlane(width: size.x, height: size.y), materials: [shadowMaterial])
        shadow.name = "livingCover.lift.shadow"
        let offset = parallax.shadowOffset
        shadow.position = [offset.x, offset.y, 0.0006]
        holder.addChild(shadow)

        var foregroundMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        foregroundMaterial.color = .init(tint: .white, texture: .init(try TextureResource(image: layers.foreground,
                                                                                         options: .init(semantic: .color))))
        foregroundMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
        foregroundMaterial.opacityThreshold = nil
        let foreground = ModelEntity(mesh: .generatePlane(width: size.x, height: size.y), materials: [foregroundMaterial])
        foreground.name = "livingCover.lift.subject"
        foreground.position = [0, 0, parallax.clampedLift]
        holder.addChild(foreground)
        return holder
    }

    // MARK: - Presentation swap

    /// Puts every mesh of a presentation behind any SwiftUI layer that overlaps it.
    ///
    /// Found in the lab: a ♥ pill hung 2 mm in front of a lifted cover was drawn **behind** the cover's image once the
    /// card swayed its corner away from the viewer (+20°), and in front of it at −10° — the renderer sorts a SwiftUI
    /// layer against nearly coplanar transparent meshes by a heuristic that flips with the angle. RealityKit's answer is
    /// `ModelSortGroup.planarUIAlwaysBehind` ("draw a model's mesh behind a SwiftUI layer that's coincident with the
    /// mesh"); the order inside the group keeps background → shadow → subject.
    static func sortBehindUI(_ entity: Entity) {
        var order: Int32 = 0
        func visit(_ e: Entity) {
            if e.components.has(ModelComponent.self) || e.components.has(ImagePresentationComponent.self) {
                e.components.set(ModelSortGroupComponent(group: .planarUIAlwaysBehind, order: order))
                order += 1
            }
            for child in e.children { visit(child) }
        }
        visit(entity)
    }

    private func show(_ holder: Entity, as newMode: V4.CoverMode, fade: Bool) {
        let old = current
        current = holder
        mode = newMode
        Self.sortBehindUI(holder)
        root.addChild(holder)
        guard fade, let old else {
            old?.removeFromParent()
            return
        }
        holder.components.set(OpacityComponent(opacity: 0))
        holder.components.set(TweenComponent(opacity: (0, 1), duration: fadeDuration, easing: .easeInOutCubic))
        old.components.set(TweenComponent(opacity: (1, 0), delay: fadeDuration * 0.35, duration: fadeDuration,
                                          easing: .easeInOutCubic, removeWhenDone: true))
    }

    private func ms(since t0: CFTimeInterval) -> Double { (CACurrentMediaTime() - t0) * 1000 }
}
