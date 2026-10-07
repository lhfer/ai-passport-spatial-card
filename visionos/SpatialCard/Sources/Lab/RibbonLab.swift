import CoreGraphics
import Foundation
import Metal
import RealityKit
import UIKit

/// `--lab ribbon`: the v4 A2 lab — the recognition key visual ("认出", style frame ①) on the virtual desk,
/// replayed every 4.5 s, built against `stage.deviceFrame` (S) exactly as it would hang off `anchorRoot`.
///
/// - `--ribbon-freeze <t>`: on the second run, stop the clock at t seconds and hold every mote in the air
///   (the still frames of the report: 0.1 / 0.7 / 1.5 / 2.0).
/// - `--ribbon-view <yaw°> <pitch°>`: turn the device (and everything on it) — the same as walking round the
///   desk or holding it tilted, for the "no flip from any angle" check. Use `--lab-no-desk` with a pitch.
/// - `--ribbon-spin <°/s>`: keep turning it (turntable), for the video.
/// - `--ribbon-demo meteor`: the same pieces reused as the follower meteor (follow mode) instead.
/// - `--ribbon-probe`: the SDK probe quads instead (see `RibbonSDKProbe`).
/// - `--ribbon-dust-test` / `--ribbon-latch-test [--latch-move]`: the particle-emitter experiments behind
///   `GoldDust`'s "always emitting, birth rate is the switch, 0.05 s cycles" (see the A2 report).
///
/// Every run logs its beats and a perf line: the rig's own per-frame CPU (`CACurrentMediaTime`) over the run
/// and over its heaviest stretch (1.2–2.2 s).
@MainActor
enum RibbonLab {
    /// The simulator's eye (the brief: ≈ (0, 1.59, 0)); the product passes the head pose instead.
    static let eye: SIMD3<Float> = [0, 1.59, 0]
    static let period: Double = 4.5

    static func run(_ stage: LabStage) async {
        let args = CommandLine.arguments
        if args.contains("--ribbon-probe") {
            await RibbonSDKProbe.build(on: stage)
            return
        }
        if let index = args.firstIndex(of: "--ribbon-demo"), index + 1 < args.count, args[index + 1] == "meteor" {
            await runMeteor(stage)
            return
        }
        if let view = floats(after: "--ribbon-view", count: 2) {
            stage.deviceFrame.orientation = simd_quatf(angle: view[0] * .pi / 180, axis: [0, 1, 0])
                * simd_quatf(angle: view[1] * .pi / 180, axis: [1, 0, 0])
            stage.log(String(format: "view: yaw %.0f°, pitch %.0f°", view[0], view[1]))
        }
        let magic: RecognitionMagic
        do {
            magic = try await RecognitionMagic.make(screenSize: LabStage.screenSize)
        } catch {
            stage.log("ribbon: could not build the rig: \(error)")
            return
        }
        magic.cameraPosition = { eye }
        magic.onBeat = { beat, t in stage.log(String(format: "beat %@ (rig %.2f s)", beat.rawValue, t)) }
        stage.deviceFrame.addChild(magic.root)
        stage.log("ParticleEmitterComponent() default timing: \(ParticleEmitterComponent().timing)")
        stage.log("ribbon: \(magic.entityCount) entities; dust peak ≤ \(magic.spec.peakAlive) motes "
                  + "(trail \(magic.spec.trail.peakAlive) + dissolve \(magic.spec.dissolve.peakAlive) + sparkle \(magic.spec.sparkle.peakAlive)); "
                  + String(format: "path %.3f m (outline from %.3f m)", magic.timeline.path.length, magic.timeline.outlineStart))

        if args.contains("--ribbon-latch-test") {
            // D / E / F: made with birth rate 0 (emitting), switched to 95/s two seconds later.
            // D keeps the default timing (repeating, emit 1 s); E cycles every 0.05 s; F has one 3600 s cycle and
            // is restart()ed when switched. Which ones answer at once?
            let cases: [(String, Double?, Bool)] = [("D default 1 s", nil, false), ("E 0.05 s", 0.05, false),
                                                    ("F 3600 s + restart()", 3600, true), ("G 3600 s", 3600, false)]
            var entities: [Entity] = []
            for (index, c) in cases.enumerated() {
                let e = Entity()
                var p = GoldDust.component(.trail)
                if let seconds = c.1 { p.timing = .repeating(warmUp: nil, emit: .init(duration: seconds), idle: nil) }
                else { p.timing = ParticleEmitterComponent().timing }
                e.components.set(p)
                e.position = [-0.45 + Float(index) * 0.13, 0.12, 0]
                stage.deviceFrame.addChild(e)
                entities.append(e)
            }
            stage.at(2.0) {
                for (index, e) in entities.enumerated() {
                    guard var p = e.components[ParticleEmitterComponent.self] else { continue }
                    p.mainEmitter.birthRate = 95
                    if cases[index].2 { p.restart() }
                    e.components.set(p)
                }
                stage.log("latch test: birth rate → 95 on D (x −0.45), E (x −0.32), F (x −0.19), G (x −0.06)")
                if args.contains("--latch-move") {
                    // …and from now on they climb at 0.15 m/s, like a ribbon head leaving the screen.
                    var climbed: Float = 0
                    stage.onTick { dt in
                        climbed += 0.15 * dt
                        for (index, e) in entities.enumerated() {
                            e.position = [-0.45 + Float(index) * 0.13, 0.12 + climbed, 0]
                        }
                    }
                }
            }
        }

        if args.contains("--ribbon-dust-test") {
            // A: the trail preset, parked; B: the same preset circling like the head; C: a plain sphere emitter
            // (no image sequence) circling. All started now, all 12 cm above the desk, left of the device.
            let a = GoldDustEmitter(.trail, name: "test.a")
            let b = GoldDustEmitter(.trail, name: "test.b")
            let c = Entity()
            var plain = ParticleEmitterComponent()
            plain.emitterShape = .sphere
            plain.emitterShapeSize = [0.004, 0.004, 0.004]
            plain.particlesInheritTransform = false
            plain.isEmitting = true
            plain.mainEmitter.image = MagicTextures.shared.headGlow
            plain.mainEmitter.blendMode = .additive
            plain.mainEmitter.birthRate = 95
            plain.mainEmitter.lifeSpan = 1.2
            plain.mainEmitter.size = 0.003
            plain.mainEmitter.color = .constant(.single(.white))
            plain.mainEmitter.isLightingEnabled = false
            c.components.set(plain)
            for e in [a.entity, b.entity, c] { stage.deviceFrame.addChild(e) }
            a.position = [-0.20, 0.12, 0]
            a.start()
            b.start()
            var phase: Float = 0
            stage.onTick { dt in
                phase += dt * 5
                b.place(at: [-0.35 + 0.06 * cos(phase), 0.12, 0.06 * sin(phase)], along: [-sin(phase), 0, cos(phase)])
                c.position = [-0.50 + 0.06 * cos(phase), 0.12, 0.06 * sin(phase)]
            }
            stage.log("dust test: A parked at x −0.20, B trail preset circling at x −0.35, C plain circling at x −0.50")
            Task { @MainActor in
                for _ in 0..<40 {
                    try? await Task.sleep(for: .seconds(0.25))
                    stage.log(magic.dustDebug)
                }
            }
        }

        if let spin = floats(after: "--ribbon-spin", count: 1)?.first {
            let base = stage.deviceFrame.orientation
            var angle: Float = 0
            stage.onTick { dt in
                angle += spin * .pi / 180 * dt
                stage.deviceFrame.orientation = simd_quatf(angle: angle, axis: [0, 1, 0]) * base
            }
        }

        let freeze = floats(after: "--ribbon-freeze", count: 1)?.first
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.6))
            var loop = 0
            while !Task.isCancelled {
                if let freeze, loop == 1 {
                    magic.freeze(at: freeze)
                    stage.log(String(format: "freezing the second run at %.2f s", freeze))
                }
                magic.run()
                stage.log("run \(loop + 1)")
                try? await Task.sleep(for: .seconds(3.2))
                let perf = magic.perf, peak = magic.perfPeak
                stage.log(String(format: "perf run %d: rig tick avg %.3f ms, p95 %.3f ms, max %.3f ms over %d frames; "
                                 + "1.2–2.2 s avg %.3f ms, p95 %.3f ms, max %.3f ms over %d frames",
                                 loop + 1, perf.average, perf.p95, perf.maximum, perf.samples.count,
                                 peak.average, peak.p95, peak.maximum, peak.samples.count))
                magic.resetPerf()
                if freeze != nil, loop == 1 {
                    stage.log(String(format: "frozen at %.2f s", magic.time))
                    return
                }
                try? await Task.sleep(for: .seconds(period - 3.2))
                loop += 1
            }
        }
    }

    /// `--ribbon-demo meteor`: the same pieces reused for the follower meteor (style frame ⑥) — a ribbon in
    /// **follow** mode chasing a target that falls out of the upper right into the screen, shedding dust; on
    /// landing a glint and the screen's burst; the ribbon then ages out behind its last position. Every 3 s.
    static func runMeteor(_ stage: LabStage) async {
        let ribbon: RibbonTrail
        do { ribbon = try await RibbonTrail.make(style: .fairy) } catch {
            stage.log("meteor: could not build the ribbon: \(error)")
            return
        }
        let glints = await StarGlint.make()
        let burst = await ScreenBurst.make(size: LabStage.screenSize, lift: 0.0006)
        let dust = GoldDustEmitter(.trail, name: "meteor.dust")
        let root = Entity()
        root.name = "meteor"
        for child in [ribbon.root, glints.root, burst.entity, dust.entity] { root.addChild(child) }
        stage.deviceFrame.addChild(root)
        ribbon.cameraPosition = { eye }
        // From far up and to the right, curving in, and straight down into the screen centre at the end.
        let from = SIMD3<Float>(0.42, 0.55, -0.35), to = SIMD3<Float>(0, 0.002, 0)
        let fall = V4.RibbonSpline(segments: [V4.RibbonSpline.hermite(from, [-0.55, -0.05, 0.25], to, [0, -0.5, 0])])
        let flight: Float = 0.9
        let timing = V4.RibbonTiming.eased(length: fall.length, duration: flight, easing: .easeInCubic)
        var clock: Float = 10
        var landed = true
        var target: SIMD3<Float>? = nil
        stage.onTick { dt in
            clock += dt
            if clock > 3 {                                     // a new meteor
                clock = 0
                landed = false
                ribbon.follow { target }
                dust.start()
            }
            if !landed {
                let s = timing.distance(at: clock)
                let p = fall.point(atDistance: s)
                target = p
                dust.place(at: p, along: fall.tangent(atDistance: s))
                if clock >= flight {
                    landed = true
                    target = nil
                    ribbon.release()
                    dust.stop()
                    glints.flash(at: [0, 0.004, 0], size: 0.010, duration: 0.32)
                    burst.play()
                    stage.log("meteor landed")
                }
            }
            ribbon.update(dt: dt)
            glints.update(dt: dt)
            if burst.isRunning { burst.set(time: clock - flight) }
        }
        stage.log(String(format: "meteor demo: %.2f m fall in %.1f s, every 3 s", fall.length, flight))
    }

    private static func floats(after flag: String, count: Int) -> [Float]? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + count < args.count else { return nil }
        let values = args[(index + 1)...(index + count)].compactMap(Float.init)
        return values.count == count ? values : nil
    }
}

/// `--lab ribbon --ribbon-probe`: five quads in front of the wearer that answer the SDK questions the ribbon's
/// design depends on. Each quad is labelled in the log; the answers are read off a screenshot.
@MainActor
enum RibbonSDKProbe {
    struct ColorVertex {
        var position: SIMD3<Float> = .zero
        var uv0: SIMD2<Float> = .zero
        var uv1: SIMD2<Float> = .zero
        var color: UInt32 = 0
    }

    static func build(on stage: LabStage) async {
        let origin = SIMD3<Float>(0, 1.50, -0.55)
        let size: Float = 0.08
        let gap: Float = 0.10

        // A grey opaque bar behind the lower half of every quad: additive blending brightens it, alpha hides it.
        let bar = ModelEntity(mesh: .generatePlane(width: 0.75, height: 0.035),
                              materials: [UnlitMaterial(color: UIColor(white: 0.45, alpha: 1))])
        bar.position = origin + [0, -0.02, -0.01]
        stage.root.addChild(bar)

        var addDescriptor = UnlitMaterial.Program.Descriptor()
        addDescriptor.blendMode = .add
        addDescriptor.applyPostProcessToneMap = false
        let addProgram = await UnlitMaterial.Program(descriptor: addDescriptor)

        let fade = makeTexture(width: 128, height: 8) { x, _ in (1, 1, 1, 1 - x) }
        let rainbow = makeTexture(width: 128, height: 8) { x, _ in
            let h = x * 5
            let r = max(0, min(1, abs(h - 3) - 1)), g = max(0, min(1, 2 - abs(h - 2))), b = max(0, min(1, 2 - abs(h - 4)))
            return (r, g, b, 1)
        }

        // 1 · vertex colours through a plain UnlitMaterial.
        do {
            var material = UnlitMaterial(color: .white)
            material.faceCulling = .none
            let quad = try quadEntity(material: material)
            quad.position = origin + [-2 * gap, 0, 0]
            stage.root.addChild(quad)
            stage.log("probe 1 (x −0.20): LowLevelMesh vertex colours (red/green/blue/white corners) under UnlitMaterial(white)")
        } catch {
            stage.log("probe 1 failed: \(error)")
        }

        // 2 · program blend mode `.add` with a white → clear texture.
        do {
            var material = UnlitMaterial(program: addProgram)
            material.color = .init(tint: .white, texture: .init(fade))
            material.faceCulling = .none
            material.writesDepth = false
            let quad = try quadEntity(material: material)
            quad.position = origin + [-gap, 0, 0]
            stage.root.addChild(quad)
            stage.log("probe 2 (x −0.10): UnlitMaterial.Program blendMode .add, texture white→clear left→right")
        } catch {
            stage.log("probe 2 failed: \(error)")
        }

        // 3 · the same, under an OpacityComponent of 0.3.
        do {
            var material = UnlitMaterial(program: addProgram)
            material.color = .init(tint: .white, texture: .init(fade))
            material.faceCulling = .none
            material.writesDepth = false
            let quad = try quadEntity(material: material)
            quad.position = origin
            quad.components.set(OpacityComponent(opacity: 0.3))
            stage.root.addChild(quad)
            stage.log("probe 3 (x 0.00): .add + OpacityComponent(0.3)")
        } catch {
            stage.log("probe 3 failed: \(error)")
        }

        // 4 · colour texture on uv0, opacity texture on uv1 (uv1 = uv0 with x and y swapped).
        do {
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(tint: .white, texture: .init(rainbow))
            var opacity = MaterialParameters.Texture(fade)
            opacity.uvIndex = 1
            material.blending = .transparent(opacity: .init(scale: 1, texture: opacity))
            material.faceCulling = .none
            material.writesDepth = false
            let quad = try quadEntity(material: material)
            quad.position = origin + [gap, 0, 0]
            stage.root.addChild(quad)
            stage.log("probe 4 (x +0.10): rainbow colour on uv0 (along x), fade opacity on uv1 (uv1 = swapped → fade along y if uvIndex works)")
        } catch {
            stage.log("probe 4 failed: \(error)")
        }

        // 5 · an extended-range tint (4, 3, 1.5) next to the same tint clamped, both under bloom.
        do {
            let hot = UIColor(red: 4, green: 3, blue: 1.5, alpha: 1)
            let plain = UIColor(red: 1, green: 0.75, blue: 0.375, alpha: 1)
            for (index, tint) in [hot, plain].enumerated() {
                var material = UnlitMaterial(applyPostProcessToneMap: false)
                material.color = .init(tint: tint)
                material.faceCulling = .none
                let quad = ModelEntity(mesh: .generatePlane(width: size / 2.2, height: size), materials: [material])
                quad.position = origin + [2 * gap + (index == 0 ? -0.022 : 0.022), 0, 0]
                quad.components.set(BloomComponent(scope: .hierarchical))
                var bloom = BloomOptionsComponent()
                bloom.threshold = 1.0
                bloom.strength = 1.0
                quad.components.set(bloom)
                stage.root.addChild(quad)
            }
            stage.log("probe 5 (x +0.20): left tint (4, 3, 1.5) extended sRGB, right (1, 0.75, 0.375); both BloomComponent threshold 1")
        }

        // Row 2 (12 cm higher): bloom and HDR under additive blending.
        let row2 = origin + [0, 0.12, 0]
        // 6 · the v3 recipe: PBR emissive × 6 under BloomComponent — does the simulator draw bloom at all?
        do {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: .black)
            material.emissiveColor = .init(color: UIColor(red: 1, green: 0.84, blue: 0.54, alpha: 1))
            material.emissiveIntensity = 6
            material.faceCulling = .none
            let quad = ModelEntity(mesh: .generatePlane(width: 0.03, height: 0.03), materials: [material])
            quad.position = row2 + [-2 * gap, 0, 0]
            quad.components.set(BloomComponent(scope: .hierarchical))
            var bloom = BloomOptionsComponent()
            bloom.threshold = 1.0
            bloom.strength = 1.0
            quad.components.set(bloom)
            stage.root.addChild(quad)
            stage.log("probe 6 (row 2, x −0.20): PBR emissive gold × 6 + BloomComponent (3 cm square)")
        }
        // 7 · PBR program with blendMode .add, emissive texture × 4 (white → clear), black base colour.
        do {
            var descriptor = PhysicallyBasedMaterial.Program.Descriptor()
            descriptor.blendMode = .add
            let program = await PhysicallyBasedMaterial.Program(descriptor: descriptor)
            var material = PhysicallyBasedMaterial(program: program)
            material.baseColor = .init(tint: .black)
            material.emissiveColor = .init(color: .white, texture: .init(fade))
            material.emissiveIntensity = 4
            material.faceCulling = .none
            material.writesDepth = false
            let quad = try quadEntity(material: material)
            quad.position = row2 + [-gap, 0, 0]
            quad.components.set(BloomComponent(scope: .hierarchical))
            var bloom = BloomOptionsComponent()
            bloom.threshold = 1.0
            bloom.strength = 1.0
            quad.components.set(bloom)
            stage.root.addChild(quad)
            stage.log("probe 7 (row 2, x −0.10): PBR Program .add, emissive white→clear × 4 + bloom")
        } catch {
            stage.log("probe 7 failed: \(error)")
        }
        // 8 · Unlit .add with the texture on uv0 but a textureCoordinateTransform (offset 0.5, scale 2).
        do {
            var material = UnlitMaterial(program: addProgram)
            material.color = .init(tint: .white, texture: .init(fade))
            material.textureCoordinateTransform = .init(offset: [0.5, 0], scale: [2, 1], rotation: 0)
            material.faceCulling = .none
            material.writesDepth = false
            let quad = try quadEntity(material: material)
            quad.position = row2
            stage.root.addChild(quad)
            stage.log("probe 8 (row 2, x 0.00): Unlit .add + textureCoordinateTransform(offset 0.5, scale 2) on a LowLevelMesh")
        } catch {
            stage.log("probe 8 failed: \(error)")
        }
        // 9 · Unlit (alpha) with the opacity texture on uv0: does an opacity texture work at all?
        do {
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(tint: .white, texture: .init(rainbow))
            material.blending = .transparent(opacity: .init(scale: 1, texture: .init(fade)))
            material.faceCulling = .none
            material.writesDepth = false
            let quad = try quadEntity(material: material)
            quad.position = row2 + [gap, 0, 0]
            stage.root.addChild(quad)
            stage.log("probe 9 (row 2, x +0.10): rainbow colour + opacity texture on uv0 (fade left → right if it works)")
        } catch {
            stage.log("probe 9 failed: \(error)")
        }
        // 10 · Unlit .add, tint (1, 0.84, 0.54) with an OpacityComponent of 1, drawn twice on top of itself:
        // does additive stacking clip at 1 or keep going (visible only as a whiter square)?
        do {
            for index in 0..<3 {
                var material = UnlitMaterial(program: addProgram)
                material.color = .init(tint: UIColor(red: 0.5, green: 0.42, blue: 0.27, alpha: 1))
                material.faceCulling = .none
                material.writesDepth = false
                let quad = ModelEntity(mesh: .generatePlane(width: 0.03, height: 0.03), materials: [material])
                quad.position = row2 + [2 * gap + Float(index) * 0.012, 0, Float(index) * 0.001]
                stage.root.addChild(quad)
            }
            stage.log("probe 10 (row 2, x +0.20): three overlapping .add squares, tint (0.5, 0.42, 0.27)")
        }

        // Row 3 (above row 2): transfer calibration. Four 16-step grey ramps (bytes 0, 17, …, 255) under the
        // ribbon's own material (Unlit, program .add, no tone map), built four ways.
        let row3 = origin + [0, 0.20, 0]
        let variants: [(String, CGColorSpace, TextureResource.Semantic)] = [
            ("sRGB space, .color", CGColorSpace(name: CGColorSpace.sRGB)!, .color),
            ("linear sRGB space, .color", CGColorSpace(name: CGColorSpace.linearSRGB)!, .color),
            ("sRGB space, .raw", CGColorSpace(name: CGColorSpace.sRGB)!, .raw),
            ("sRGB space, .hdrColor", CGColorSpace(name: CGColorSpace.sRGB)!, .hdrColor),
        ]
        for (index, variant) in variants.enumerated() {
            let ramp = makeRamp(space: variant.1, semantic: variant.2)
            var material = UnlitMaterial(program: addProgram)
            material.color = .init(tint: .white, texture: .init(ramp))
            material.faceCulling = .none
            material.writesDepth = false
            let quad = ModelEntity(mesh: .generatePlane(width: 0.48, height: 0.018), materials: [material])
            quad.position = row3 + [0, Float(index) * 0.022, 0]
            stage.root.addChild(quad)
            stage.log("probe 11.\(index) (row 3, y +\(index * 22) mm): grey ramp 0…255 in 16 steps, \(variant.0)")
        }

        // Row 4 (to the left and right of row 3): which space a particle's `acceleration` is in. Two emitters
        // with a strong (0, −0.25, 0) and `particlesInheritTransform = false`; the right one's entity is turned
        // 90° about X, so if acceleration were emitter-local its motes would stream toward the viewer, not down.
        for (index, turned) in [false, true].enumerated() {
            let entity = Entity()
            var p = ParticleEmitterComponent()
            p.emitterShape = .point
            p.speed = 0.001
            p.particlesInheritTransform = false
            p.isEmitting = true
            p.mainEmitter.image = MagicTextures.shared.dustTwinkle
            p.mainEmitter.blendMode = .additive
            p.mainEmitter.birthRate = 30
            p.mainEmitter.lifeSpan = 1.5
            p.mainEmitter.size = 0.006
            p.mainEmitter.acceleration = [0, -0.25, 0]
            p.mainEmitter.color = .constant(.single(.white))
            p.mainEmitter.isLightingEnabled = false
            entity.components.set(p)
            entity.position = row3 + [index == 0 ? -0.30 : 0.30, 0.06, 0]
            if turned { entity.orientation = simd_quatf(angle: .pi / 2, axis: [1, 0, 0]) }
            stage.root.addChild(entity)
            stage.log("probe 12.\(index): emitter at x \(index == 0 ? "−0.30" : "+0.30"), accel (0, −0.25, 0), entity \(turned ? "turned 90° about X" : "unturned")")
        }
    }

    /// 16 flat steps, bytes 0, 17, …, 255, opaque grey (premultiplied = straight at alpha 1).
    static func makeRamp(space: CGColorSpace, semantic: TextureResource.Semantic) -> TextureResource {
        let width = 256, height = 4
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(min(255, (x / 16) * 17))
                let i = (y * width + x) * 4
                bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return try! TextureResource(image: image, options: .init(semantic: semantic))
    }

    /// A 0.08 m quad as a `LowLevelMesh`: uv0 = (x, y), uv1 = (y, x), corner colours red / green / blue / white.
    static func quadEntity(material: any Material) throws -> ModelEntity {
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = 4
        descriptor.indexCapacity = 6
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<ColorVertex>.offset(of: \.position)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<ColorVertex>.offset(of: \.uv0)!),
            .init(semantic: .uv1, format: .float2, offset: MemoryLayout<ColorVertex>.offset(of: \.uv1)!),
            .init(semantic: .color, format: .uchar4Normalized_bgra, offset: MemoryLayout<ColorVertex>.offset(of: \.color)!),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<ColorVertex>.stride)]
        descriptor.indexType = .uint32
        let mesh = try LowLevelMesh(descriptor: descriptor)
        let h: Float = 0.04
        let corners: [(SIMD3<Float>, SIMD2<Float>, UInt32)] = [
            ([-h, -h, 0], [0, 0], 0xFFFF_0000),   // BGRA packed as 0xAARRGGBB: red
            ([h, -h, 0], [1, 0], 0xFF00_FF00),    // green
            ([-h, h, 0], [0, 1], 0xFF00_00FF),    // blue
            ([h, h, 0], [1, 1], 0xFFFF_FFFF),     // white
        ]
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let vertices = raw.bindMemory(to: ColorVertex.self)
            for (i, corner) in corners.enumerated() {
                vertices[i] = ColorVertex(position: corner.0, uv0: corner.1, uv1: [corner.1.y, corner.1.x], color: corner.2)
            }
        }
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            for (i, value) in [UInt32(0), 1, 2, 2, 1, 3].enumerated() { indices[i] = value }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexOffset: 0, indexCount: 6, topology: .triangle, materialIndex: 0,
                                                 bounds: BoundingBox(min: [-h, -h, -0.001], max: [h, h, 0.001]))])
        let resource = try MeshResource(from: mesh)
        return ModelEntity(mesh: resource, materials: [material])
    }

    /// Straight RGBA (not premultiplied) → a premultiplied sRGB texture.
    static func makeTexture(width: Int, height: Int, _ pixel: (Float, Float) -> (Float, Float, Float, Float)) -> TextureResource {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height))
                let i = (y * width + x) * 4
                bytes[i] = UInt8(max(0, min(1, r * a)) * 255)
                bytes[i + 1] = UInt8(max(0, min(1, g * a)) * 255)
                bytes[i + 2] = UInt8(max(0, min(1, b * a)) * 255)
                bytes[i + 3] = UInt8(max(0, min(1, a)) * 255)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        return try! TextureResource(image: image, options: .init(semantic: .color))
    }
}
