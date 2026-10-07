import Foundation
import RealityKit
import UIKit

/// W2 代码之海 (design doc §5.3): the room is "seen through" as green geometry sweeping out from
/// the card, then lets go into two rings of falling glyph columns. Stays in .mixed: the passthrough
/// is dimmed by the shell sphere (P0-2/P0-3), so picking up the card still exits.
///
/// Entry (4.0 s): 0.00–0.15 card tints green · 0.15–0.65 wavefront: room mesh chunks fade in green by
/// distance from the card, shell dims · 0.65–0.90 room mesh lets go (fades/sinks) while the rain fades
/// in from above · 0.90–1.0 floor disc.  Exit (2.4 s): rain freezes → columns collapse toward the
/// card and dim → room mesh flickers back → shell clears.
@MainActor
final class CodeSeaWorld: World {
    let descriptor: WorldDescriptor
    let root = Entity()
    private let rain = GlyphRain()
    /// Code waterfall around the tower 14 m ahead: a dense, fast, tall column cluster.
    private let towerRain = GlyphRain(rings: [(1.0, 18), (1.6, 14)], height: 7.5, glyphSize: 0.24, speedScale: 2.2)
    private let towerGlow: ModelEntity
    private var streams: [ModelEntity] = []
    private let mirror: ModelEntity
    private let floorDisc: ModelEntity
    private var time: Float = 0
    private var frozen = false
    private var collapse: Float = 0

    init(descriptor: WorldDescriptor) {
        self.descriptor = descriptor
        floorDisc = ModelEntity(mesh: .generatePlane(width: 3, depth: 3, cornerRadius: 1.5),
                                materials: [WorldKit.unlit(UIColor(hex: "#020B04"), opacity: 0.85)])
        floorDisc.components.set(OpacityComponent(opacity: 0))
        // Dark mirror floor: near-black metal reflecting the (dark) environment through the IBL.
        var mirrorMaterial = PhysicallyBasedMaterial()
        mirrorMaterial.baseColor = .init(tint: UIColor(hex: "#03100A"), texture: nil)
        mirrorMaterial.metallic = .init(floatLiteral: 1)
        mirrorMaterial.roughness = .init(floatLiteral: 0.08)
        mirrorMaterial.emissiveColor = .init(color: UIColor(hex: "#00FF41"))
        mirrorMaterial.emissiveIntensity = 0.02
        mirror = ModelEntity(mesh: .generatePlane(width: 30, depth: 30, cornerRadius: 15), materials: [mirrorMaterial])
        towerGlow = ModelEntity(mesh: .generatePlane(width: 5, depth: 5), materials: [FXMaterials.glow(FXTextures.shared.softDisc, tint: descriptor.highlightColor, opacity: 0.9)])
        root.addChild(mirror)
        root.addChild(rain.root)
        root.addChild(towerRain.root)
        root.addChild(towerGlow)
        root.addChild(floorDisc)
    }

    /// Kenney Space Kit pieces come flat-shaded; re-skin them as dark gunmetal with a faint green emissive so they
    /// belong to this world (the IBL adds the reflections).
    private func skinAssets() {
        guard let assets = root.findEntity(named: "assets") else { return }
        var metal = PhysicallyBasedMaterial()
        metal.baseColor = .init(tint: UIColor(hex: "#0E1A14"), texture: nil)
        metal.metallic = .init(floatLiteral: 0.85)
        metal.roughness = .init(floatLiteral: 0.32)
        metal.emissiveColor = .init(color: UIColor(hex: "#0A2A14"))
        metal.emissiveIntensity = 0.004      // PBR emissive is bright: this is just a hint of green in the shadows
        func visit(_ e: Entity) {
            if e.name == "fog" { return }        // the haze bands are not props
            if let m = e as? ModelEntity, let count = m.model?.materials.count { m.model?.materials = Array(repeating: metal, count: max(1, count)) }
            for c in e.children { visit(c) }
        }
        visit(assets)
    }

    func build(ctx: WorldContext, engine: WorldEngine) {
        let origin = ctx.origin, f = ctx.forward, r = ctx.right
        floorDisc.position = SIMD3(ctx.headPosition.x, ctx.floorY + 0.005, ctx.headPosition.z)
        mirror.position = origin + [0, -0.03, 0]
        rain.build(center: SIMD3(ctx.headPosition.x, ctx.floorY, ctx.headPosition.z), floorY: ctx.floorY,
                   tint: descriptor.primaryColor, head: descriptor.highlightColor)
        rain.setOpacity(0)
        // Tower 14 m ahead (matches the placements): waterfall of code, a glow at its crown.
        let tower = origin + f * 14
        towerRain.build(center: tower, floorY: ctx.floorY, tint: descriptor.primaryColor, head: descriptor.highlightColor)
        towerRain.setOpacity(0)
        towerGlow.position = tower + [0, 7.4, 0]
        towerGlow.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.08, baseOpacity: 1, opacityAmplitude: 0.3, period: 2.4))
        towerGlow.components.set(OpacityComponent(opacity: 0))
        // Three data streams from the card to the tower base: thin glowing ribbons with travelling pulses.
        for s in streams { s.removeFromParent() }
        streams.removeAll()
        for i in 0..<3 {
            let lateral = r * (Float(i) - 1) * 0.9
            let from = ctx.cardPosition + [0, 0.02, 0]
            let to = tower + lateral + [0, 0.35, 0]
            let len = simd_length(to - from)
            let ribbon = ModelEntity(mesh: .generateBox(width: 0.02, height: 0.006, depth: len), materials: [FXMaterials.glow(FXTextures.shared.beam, tint: descriptor.primaryColor, opacity: 0.55)])
            ribbon.position = (from + to) / 2
            ribbon.look(at: to, from: (from + to) / 2, relativeTo: nil)
            ribbon.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.0, baseOpacity: 1, opacityAmplitude: 0.45, period: 1.1 + 0.3 * Float(i), phase: Float(i)))
            ribbon.components.set(BloomComponent(scope: .hierarchical))
            ribbon.components.set(OpacityComponent(opacity: 0))
            root.addChild(ribbon)
            streams.append(ribbon)
        }
        skinAssets()
    }

    func applyQuality(_ tier: WorldQuality) {
        rain.setDensity(tier.density)
        towerRain.setDensity(tier == .low ? 0.3 : 1)
        for s in streams { s.isEnabled = tier > .low }
    }

    /// The room becomes glyph-covered green geometry that falls like code (RoomFission drives it).
    func fissionRecipe(ctx: WorldContext) -> RoomFission.Recipe? { RoomFission.codeSea(descriptor) }

    func entry(progress p: Float, dt: Float, ctx: WorldContext, engine: WorldEngine) {
        time += dt
        // The room itself is handled by RoomFission (glyph surfaces falling as code); the shell follows its coverage.
        let shell = p < 0.15 ? 0 : min(1, (p - 0.15) / 0.75)
        engine.shell.set(opacity: shell * 0.35)
        // Rain fades in from above while the room lets go; the tower, its glow and the streams come with it.
        let arrive = max(0, min(1, (p - 0.6) / 0.3))
        rain.setOpacity(arrive)
        rain.update(dt: dt, frozen: false, collapse: 0)
        towerRain.setOpacity(arrive)
        towerRain.update(dt: dt, frozen: false, collapse: 0)
        towerGlow.components.set(OpacityComponent(opacity: arrive))
        for (i, s) in streams.enumerated() { s.components.set(OpacityComponent(opacity: max(0, min(1, (p - 0.75 - 0.05 * Float(i)) / 0.2)))) }
        floorDisc.components.set(OpacityComponent(opacity: max(0, (p - 0.9) / 0.1)))
    }

    func inside(dt: Float, ctx: WorldContext, engine: WorldEngine) {
        time += dt
        rain.update(dt: dt, frozen: false, collapse: 0)
        towerRain.update(dt: dt, frozen: false, collapse: 0)
        engine.shell.set(opacity: descriptor.immersion.shellOpacity)
    }

    func exit(progress p: Float, dt: Float, ctx: WorldContext, engine: WorldEngine) {
        // 0–0.08 freeze · 0.08–0.5 columns collapse toward the card · 0.5–0.8 room flickers back · shell clears by 1.
        frozen = p < 0.08
        collapse = max(0, min(1, (p - 0.08) / 0.42))
        rain.setOpacity(1 - collapse)
        rain.update(dt: dt, frozen: frozen, collapse: collapse, collapseTarget: ctx.cardPosition)
        towerRain.setOpacity(1 - collapse)
        towerRain.update(dt: dt, frozen: frozen, collapse: collapse, collapseTarget: ctx.cardPosition)
        towerGlow.components.set(OpacityComponent(opacity: 1 - collapse))
        for s in streams { s.components.set(OpacityComponent(opacity: 1 - min(1, p * 3))) }
        engine.shell.set(opacity: descriptor.immersion.shellOpacity)
        floorDisc.components.set(OpacityComponent(opacity: max(0, 1 - p * 2)))
    }

    func teardown() {}
}

/// Instanced glyph rain: two rings of columns around the wearer, each column a stack of glyph quads
/// falling at its own speed; the lowest glyph of every column is drawn brighter (the "head").
@MainActor
final class GlyphRain {
    let root = Entity()
    private struct Column { var angle: Float; var radius: Float; var speed: Float; var phase: Float; var count: Int; var glyphSet: Int }
    private let rings: [(radius: Float, count: Int)]
    private let glyphSize: Float
    private let speedScale: Float
    private var densityLimit = 1.0 as Float

    /// `rings` = (radius, columns) around the centre; `height` metres of fall; `glyphSize` quad edge.
    init(rings: [(radius: Float, count: Int)] = [(2.3, 44), (5.5, 30)], height: Float = 4.2, glyphSize: Float = 0.18, speedScale: Float = 1) {
        self.rings = rings
        self.height = height
        self.glyphSize = glyphSize
        self.speedScale = speedScale
    }

    /// Quality tier: columns beyond `fraction` of each ring are collapsed (instances scaled to zero).
    func setDensity(_ fraction: Float) { densityLimit = max(0.1, min(1, fraction)) }
    private var columns: [Column] = []
    private var bodies: [ModelEntity] = []
    private var heads: [ModelEntity] = []
    private var bodyData: [LowLevelInstanceData] = []
    private var headData: [LowLevelInstanceData] = []
    private var bodyCounts: [Int] = []
    private var center: SIMD3<Float> = .zero
    private var floorY: Float = 0
    private var time: Float = 0
    private let height: Float
    private let spacing: Float = 0.16
    private let glyphSets = 8

    func build(center: SIMD3<Float>, floorY: Float, tint: UIColor, head: UIColor) {
        self.center = center
        self.floorY = floorY
        var rng = WorldKit.RNG(0xC0DE)
        columns.removeAll()
        for (radius, n) in rings {
            for i in 0..<n {
                let angle = Float(i) / Float(n) * 2 * .pi + rng.range(-0.03, 0.03)
                columns.append(Column(angle: angle, radius: radius, speed: rng.range(0.6, 1.9) * speedScale, phase: rng.range(0, height),
                                      count: Int(height / spacing), glyphSet: Int(rng.next() * Float(glyphSets))))
            }
        }
        bodyCounts = Array(repeating: 0, count: glyphSets)
        for c in columns { bodyCounts[c.glyphSet] += c.count }
        let quad = MeshResource.generatePlane(width: glyphSize, height: glyphSize)
        for set in 0..<glyphSets {
            let glyph = WorldKit.glyphs[set % WorldKit.glyphs.count]
            let bodyTex = WorldKit.glyphTexture(glyph, color: .white)
            guard let bData = try? LowLevelInstanceData(instanceCount: max(1, bodyCounts[set])),
                  let hData = try? LowLevelInstanceData(instanceCount: max(1, columns.filter { $0.glyphSet == set }.count)) else { continue }
            let body = ModelEntity(mesh: quad, materials: [FXMaterials.glow(bodyTex, tint: tint, opacity: 0.85)])
            let headE = ModelEntity(mesh: quad, materials: [FXMaterials.glow(bodyTex, tint: head, opacity: 1)])
            let bounds = BoundingBox(min: [-8, -1, -8], max: [8, 6, 8])
            if let comp = try? MeshInstancesComponent(mesh: quad, instances: bData, bounds: bounds) { body.components.set(comp) }
            if let comp = try? MeshInstancesComponent(mesh: quad, instances: hData, bounds: bounds) { headE.components.set(comp) }
            body.components.set(BloomComponent(scope: .hierarchical))
            root.addChild(body); root.addChild(headE)
            bodies.append(body); heads.append(headE); bodyData.append(bData); headData.append(hData)
        }
    }

    func setOpacity(_ o: Float) {
        root.components.set(OpacityComponent(opacity: o))
        root.isEnabled = o > 0.001
    }

    /// `collapse` 0…1 pulls every glyph toward `collapseTarget` and dims it (reflow exit).
    func update(dt: Float, frozen: Bool, collapse: Float, collapseTarget: SIMD3<Float>? = nil) {
        if !frozen { time += dt }
        guard bodyData.count == glyphSets else { return }
        var bodyIndex = Array(repeating: 0, count: glyphSets)
        var headIndex = Array(repeating: 0, count: glyphSets)
        let target = collapseTarget ?? center
        for (ci, c) in columns.enumerated() {
            // Density gate: a stable subset of columns per ring (index parity spread) survives lower tiers.
            let hidden = Float((ci * 7919) % 100) / 100 > densityLimit
            let x = center.x + cos(c.angle) * c.radius, z = center.z + sin(c.angle) * c.radius
            // Glyphs face the centre (the wearer).
            let facing = simd_quatf(angle: atan2(-cos(c.angle), -sin(c.angle)), axis: [0, 1, 0])
            let fall = (time * c.speed + c.phase).truncatingRemainder(dividingBy: height)
            let set = c.glyphSet
            for k in 0..<c.count {
                var y = floorY + height - ((Float(k) * spacing + fall).truncatingRemainder(dividingBy: height))
                var pos = SIMD3<Float>(x, y, z)
                var scale: Float = hidden ? 0 : 1
                if collapse > 0 {
                    pos = simd_mix(pos, target, SIMD3<Float>(repeating: collapse * collapse))
                    scale *= 1 - collapse * 0.9
                }
                y = pos.y
                var m = simd_float4x4(facing)
                m.columns.0 *= scale; m.columns.1 *= scale; m.columns.2 *= scale
                m.columns.3 = SIMD4<Float>(pos, 1)
                let isHead = k == 0
                if isHead {
                    let i = headIndex[set]
                    if i < headData[set].instanceCount { headData[set].withMutableTransforms { $0[i] = m } }
                    headIndex[set] += 1
                } else {
                    let i = bodyIndex[set]
                    if i < bodyData[set].instanceCount { bodyData[set].withMutableTransforms { $0[i] = m } }
                    bodyIndex[set] += 1
                }
            }
        }
    }
}
