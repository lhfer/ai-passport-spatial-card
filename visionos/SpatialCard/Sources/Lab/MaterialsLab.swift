import RealityKit
import SwiftUI
import UIKit

/// `--lab materials` (v4 A1): the ShaderGraph material library on the virtual desk.
///
/// One row of half-size name cards above the desk, left to right: the v3 slab (control), CrystalSlab, HoloFoil,
/// GoldEdge, MagicDissolve and the full name-card stack (CrystalSlab + HoloFoil + GoldEdge, with a gold serif number
/// on it to judge legibility). Every sample swings ±35° about its vertical axis; the sweep crosses every 3 s and the
/// dissolve runs 0 → 1 → hold → 0 every 4 s (`V4.MaterialsLabClock`).
///
/// Flags (this lab only):
/// - `--materials-probe` / `--materials-probe-usd`: the SDK probe ladders instead of the row (report evidence).
/// - `--materials-focus <0…6>`: one sample alone, at the name card's real size, over the device (close-ups with
///   `--lab-pose 1.45 0.45`). Sample 6 exists only here: A4's hero-card surface geometry (as on branch v4/a4-card)
///   dressed by `MagicCardSurfaceMaterials` — the adapter A4's `CardSurfaceStyle` is meant to wrap.
/// - `--materials-t <s>`: freeze the parameter clock at that time; `--materials-sway <deg>`: freeze the swing angle.
@MainActor
enum MaterialsLab {
    static let sampleScale: Float = 0.5
    static let spacing: Float = 0.165
    /// Card centre above the desk top, and how far behind the device the row stands.
    static let height: Float = 0.2
    static let depth: Float = -0.08

    static let titles = ["v3 对照 · PBR 半透明", "CrystalSlab 水晶厚板", "HoloFoil 全息箔", "GoldEdge 金边",
                         "MagicDissolve 显形", "名片材质栈", "A4 名片面 × A1 材质（模拟）"]

    static func build(_ stage: LabStage) async {
        let args = CommandLine.arguments
        if args.contains("--materials-probe") || args.contains("--materials-probe-usd") {
            await runProbes(stage, full: args.contains("--materials-probe"))
            return
        }

        let frozenTime = value(after: "--materials-t").flatMap(Double.init)
        let frozenSway = value(after: "--materials-sway").flatMap(Float.init).map { $0 * .pi / 180 }
        let focus = value(after: "--materials-focus").flatMap(Int.init)

        let loadStart = CACurrentMediaTime()
        let row = Entity()
        row.name = "materials.row"
        // The row, or (focus) one sample at the name card's real size, centred over the device.
        let firstX = -spacing * 2.5
        row.position = [0, focus == nil ? height : height + 0.04, depth]
        stage.desk.addChild(row)

        let geometry = NameCardMaterialStack.Geometry.nameCard
        let slabMesh = MagicMeshes.slab(width: geometry.slabSize.x, height: geometry.slabSize.y,
                                        depth: geometry.thickness, radius: geometry.slabCornerRadius)
        var holders: [Entity] = []
        for index in 0..<titles.count {
            let holder = Entity()
            holder.name = "materials.sample\(index)"
            let x = focus == nil ? firstX + Float(index) * spacing : 0
            holder.position = [x, 0, 0]
            holder.scale = SIMD3(repeating: focus == nil ? sampleScale : 1)
            // The row shows 0…5; sample 6 (A4's surface) only in focus.
            holder.isEnabled = focus == index || (focus == nil && index < 6)
            row.addChild(holder)
            holders.append(holder)
            let label = makeLabel(titles[index])
            label.position = [x, focus == nil ? -0.095 : -0.175, 0.02]
            label.isEnabled = holder.isEnabled
            row.addChild(label)
        }

        // 0 — the v3 control: PBR frosted slab (opacity 0.30, clearcoat) and its emissive rim ring.
        do {
            let group = ModelSortGroup(depthPass: nil)
            let slab = ModelEntity(mesh: slabMesh, materials: [HologramController.slabMaterial(look: HologramLook.desk)])
            slab.position = [0, 0, NameCardMaterialStack.slabZ]
            slab.components.set(ModelSortGroupComponent(group: group, order: 0))
            let rim = ModelEntity(mesh: FXMeshes.roundedRectRing(width: geometry.slabSize.x, height: geometry.slabSize.y,
                                                                 radius: geometry.slabCornerRadius, thickness: 0.0022),
                                  materials: [HologramController.emissive(.white, intensity: 5, opacity: 0.6)])
            rim.position = [0, 0, -0.001]
            rim.components.set(ModelSortGroupComponent(group: group, order: 1))
            holders[0].addChild(slab)
            holders[0].addChild(rim)
        }

        var crystal: (CrystalSlabMaterial, ModelEntity)?
        var foil: (HoloFoilMaterial, ModelEntity)?
        var edge: (GoldEdgeMaterial, ModelEntity)?
        var dissolve: (MagicDissolveMaterial, ModelEntity)?
        var stack: NameCardMaterialStack?
        var heroSurface: HeroSurfaceSample?
        do {
            // 1 — CrystalSlab. (`--materials-blur-only`: frost 1, no milk — the plate shows nothing but
            // RealityKit's background blur, to see whether the blur samples what is behind.)
            var crystalMaterial = try await CrystalSlabMaterial.load()
            if CommandLine.arguments.contains("--materials-blur-only") {
                crystalMaterial.setOpacity(0)
                crystalMaterial.setFrost(1)
                crystalMaterial.setReflection(0)
            }
            let crystalEntity = ModelEntity(mesh: slabMesh, materials: [crystalMaterial.material])
            crystalEntity.position = [0, 0, NameCardMaterialStack.slabZ]
            holders[1].addChild(crystalEntity)
            crystal = (crystalMaterial, crystalEntity)

            // 2 — HoloFoil on the card face.
            var foilMaterial = try await HoloFoilMaterial.load()
            foilMaterial.setHalfSize(geometry.cardSize / 2)
            let foilEntity = ModelEntity(mesh: MagicMeshes.roundedPlane(width: geometry.cardSize.x, height: geometry.cardSize.y,
                                                                        radius: geometry.cardCornerRadius),
                                         materials: [foilMaterial.material])
            holders[2].addChild(foilEntity)
            foil = (foilMaterial, foilEntity)

            // 3 — GoldEdge on its ring (7 mm in, 6 mm out of the slab outline).
            let edgeMaterial = try await GoldEdgeMaterial.load()
            let edgeEntity = ModelEntity(mesh: MagicMeshes.goldEdgeRing(width: geometry.slabSize.x, height: geometry.slabSize.y,
                                                                        radius: geometry.slabCornerRadius),
                                         materials: [edgeMaterial.material])
            edgeEntity.components.set(BloomComponent(scope: .hierarchical))
            holders[3].addChild(edgeEntity)
            edge = (edgeMaterial, edgeEntity)

            // 4 — MagicDissolve on the slab.
            let dissolveMaterial = try await MagicDissolveMaterial.load()
            let dissolveEntity = ModelEntity(mesh: slabMesh, materials: [dissolveMaterial.material])
            dissolveEntity.position = [0, 0, NameCardMaterialStack.slabZ]
            dissolveEntity.components.set(BloomComponent(scope: .hierarchical))
            holders[4].addChild(dissolveEntity)
            dissolve = (dissolveMaterial, dissolveEntity)

            // 5 — the full stack, with a number on it (over an ink veil: gold type on pale crystal needs one).
            let group = ModelSortGroup(depthPass: nil)
            let cardStack = try await NameCardMaterialStack.make(geometry, sortGroup: group)
            holders[5].addChild(cardStack.root)
            try await addSampleContent(to: holders[5], group: group, order: 3)
            stack = cardStack

            // 6 — A4's hero-card surface (focus only).
            if focus == 6 {
                heroSurface = try await makeHeroSurface(on: holders[6])
            }
        } catch {
            stage.log("materials FAILED to load: \(error) | \(error.localizedDescription)")
        }
        let loads = MagicMaterialLoader.loadTimes.sorted { $0.key < $1.key }
            .map { String(format: "%@ %.0f ms", $0.key, $0.value) }.joined(separator: ", ")
        stage.log(String(format: "materials ready in %.0f ms (%@)", (CACurrentMediaTime() - loadStart) * 1000, loads))
        stage.log("entities: \(countEntities(row)) under the row (6 samples + labels)")

        // Per-frame: swing, sweep, dissolve — parameter writes only, timed.
        var frames = 0
        var totalMs = 0.0
        var worstMs = 0.0
        var stackTotalMs = 0.0
        var stackWorstMs = 0.0
        var lastReport = stage.time
        stage.onTick { _ in
            let t = frozenTime ?? stage.time
            let start = CACurrentMediaTime()
            let angle = frozenSway ?? V4.MaterialsLabClock.sway(at: t)
            let turn = simd_quatf(angle: angle, axis: [0, 1, 0])
            for holder in holders { holder.orientation = turn }

            let sweep = V4.MaterialsLabClock.sweep(at: t)
            if var c = crystal {
                c.0.setSweep(sweep)
                c.0.commit(to: c.1)
                crystal = c
            }
            if var f = foil {
                f.0.setSweep(sweep)
                f.0.commit(to: f.1)
                foil = f
            }
            if var e = edge {
                e.0.setSweep(sweep)
                e.0.commit(to: e.1)
                edge = e
            }
            if var d = dissolve {
                d.0.setProgress(V4.MaterialsLabClock.dissolve(at: t))
                d.0.commit(to: d.1)
                dissolve = d
            }
            // The product's share on its own: one card stack, one sweep value, one commit (3 parameters, ≤ 3 pushes).
            let stackStart = CACurrentMediaTime()
            if let stack {
                stack.setSweep(sweep)
                stack.commit()
            }
            // A4's style receives the linear progress (nil between sweeps), as HeroCardRig hands it over.
            heroSurface?.update(sweep: V4.MaterialsLabClock.sweepProgress(at: t))
            let end = CACurrentMediaTime()
            let ms = (end - start) * 1000
            let stackMs = (end - stackStart) * 1000
            frames += 1
            totalMs += ms
            worstMs = max(worstMs, ms)
            stackTotalMs += stackMs
            stackWorstMs = max(stackWorstMs, stackMs)
            if stage.time - lastReport >= 5 {
                stage.log(String(format: "[perf] materials tick: %d frames, avg %.3f ms, worst %.3f ms (sway + 5 sweeps + 1 dissolve + commits); card stack alone avg %.3f ms, worst %.3f ms",
                                 frames, totalMs / Double(max(1, frames)), worstMs,
                                 stackTotalMs / Double(max(1, frames)), stackWorstMs))
                frames = 0
                totalMs = 0
                worstMs = 0
                stackTotalMs = 0
                stackWorstMs = 0
                lastReport = stage.time
            }
        }
        stage.log("materials lab running (sweep every \(V4.MaterialsLabClock.sweepPeriod) s, dissolve every \(V4.MaterialsLabClock.dissolvePeriod) s)")
    }

    // MARK: - Pieces

    /// A gold serif fan count and its caption on the stack card, in front of the foil (as the SwiftUI sheet would be),
    /// over a soft ink veil: on pale frosted crystal, gold type needs a dark ground to stay above 4.5 : 1 in a lit room
    /// (bible §1: ink is the colour for text on a light ground).
    private static func addSampleContent(to holder: Entity, group: ModelSortGroup, order: Int32) async throws {
        var veilMaterial = try await InkVeilMaterial.load()
        let veilHalf: SIMD2<Float> = [0.092, 0.056]
        veilMaterial.setShape(halfSize: veilHalf, cornerRadius: 0.024, softness: 0.012)
        let veil = ModelEntity(mesh: .generatePlane(width: 2 * veilHalf.x + 0.03, height: 2 * veilHalf.y + 0.03),
                               materials: [veilMaterial.material])
        veil.position = [0, -0.013, 0.0012]
        veil.components.set(ModelSortGroupComponent(group: group, order: order))
        holder.addChild(veil)

        addCount(to: holder, group: group, order: order + 1, numberAt: [0, -0.035, 0.002], captionAt: [0, 0.023, 0.002])

        // Stand-in for the avatar: a dark disc, where the hero image sits.
        let disc = ModelEntity(mesh: MagicMeshes.roundedPlane(width: 0.07, height: 0.07, radius: 0.035),
                               materials: [HologramController.unlit(UIColor(hex: "#1B2A6B"), opacity: 0.95)])
        disc.position = [0, 0.09, 0.001]
        disc.components.set(ModelSortGroupComponent(group: group, order: order))
        holder.addChild(disc)
    }

    /// The gold serif count and its caption.
    private static func addCount(to holder: Entity, group: ModelSortGroup, order: Int32,
                                 numberAt: SIMD3<Float>, captionAt: SIMD3<Float>) {
        let serif = UIFont.systemFont(ofSize: 0.056, weight: .regular).fontDescriptor.withDesign(.serif)
            .map { UIFont(descriptor: $0, size: 0.056) } ?? UIFont.systemFont(ofSize: 0.056)
        // Not tone-mapped: the gold lands at its true #FFD58A (tone mapping pulled it to L ≈ 0.50 and the day contrast under 4.5 : 1).
        var numberMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        numberMaterial.color = .init(tint: UIColor(hex: V4.MagicPalette.gold))
        numberMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
        let number = ModelEntity(mesh: .generateText("4,401", extrusionDepth: 0.0005, font: serif), materials: [numberMaterial])
        centre(number, at: numberAt)
        number.components.set(ModelSortGroupComponent(group: group, order: order))
        holder.addChild(number)

        let caption = ModelEntity(mesh: .generateText("粉丝", extrusionDepth: 0.0003,
                                                      font: UIFont(name: "PingFangSC-Regular", size: 0.018) ?? .systemFont(ofSize: 0.018)),
                                  materials: [HologramController.unlit(UIColor(hex: V4.MagicPalette.goldHot), opacity: 0.9)])
        centre(caption, at: captionAt)
        caption.components.set(ModelSortGroupComponent(group: group, order: order))
        holder.addChild(caption)
    }

    /// Sample 6: the hero card's surface as A4 builds it (branch v4/a4-card, `HeroCardSurface` + `HeroCardRig`,
    /// square shape) — slab 12 mm with its front face at z 0, rim ring, gold ring 1.5 mm in, the opaque midnight panel
    /// 7 mm in, foil over the panel, sweep plane — dressed by `MagicCardSurfaceMaterials` exactly as A4's
    /// `CardSurfaceStyle` adapter would (A1 report §7).
    private static func makeHeroSurface(on holder: Entity) async throws -> HeroSurfaceSample {
        let size: SIMD2<Float> = [0.27, 0.27], radius: Float = 0.030, thickness: Float = 0.012
        let goldInset: Float = 0.0015, goldWidth: Float = 0.0010, panelInset: Float = 0.0070
        let panelSize = size - 2 * panelInset, panelRadius = max(0.004, radius - panelInset)
        let group = ModelSortGroup(depthPass: nil)

        let slab = ModelEntity(mesh: FXMeshes.roundedSlab(width: size.x, height: size.y, depth: thickness, radius: radius))
        slab.position = [0, 0, -thickness / 2]
        let rim = ModelEntity(mesh: FXMeshes.roundedRectRing(width: size.x, height: size.y, radius: radius, thickness: 0.006))
        rim.position = [0, 0, 0.0001]
        let goldLine = ModelEntity(mesh: FXMeshes.roundedRectRing(width: size.x - 2 * goldInset, height: size.y - 2 * goldInset,
                                                                  radius: radius - goldInset, thickness: goldWidth))
        goldLine.position = [0, 0, 0.0002]
        var panelMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        panelMaterial.color = .init(tint: UIColor(hex: "#0E1636"))
        let panel = ModelEntity(mesh: .generatePlane(width: panelSize.x, height: panelSize.y, cornerRadius: panelRadius),
                                materials: [panelMaterial])
        panel.position = [0, 0, 0.0003]
        let foil = ModelEntity(mesh: .generatePlane(width: panelSize.x, height: panelSize.y, cornerRadius: panelRadius))
        foil.position = [0, 0, 0.0005]
        let sweep = ModelEntity(mesh: .generatePlane(width: size.x - 2 * goldInset, height: size.y - 2 * goldInset,
                                                     cornerRadius: radius - goldInset))
        sweep.position = [0, 0, 0.0012]
        sweep.components.set(OpacityComponent(opacity: 0))
        for (order, entity) in [slab, rim, goldLine, panel, foil, sweep].enumerated() {
            entity.components.set(ModelSortGroupComponent(group: group, order: Int32(order)))
            holder.addChild(entity)
        }

        let materials = try await MagicCardSurfaceMaterials.make()
        materials.apply(slab: slab, rim: rim, goldLine: goldLine, foil: foil, sweep: sweep,
                        outline: .init(size: size, cornerRadius: radius, thickness: thickness,
                                       foilSize: panelSize, foilCornerRadius: panelRadius,
                                       sweepSize: size - 2 * goldInset, sweepCornerRadius: radius - goldInset,
                                       goldInset: goldInset, goldWidth: goldWidth))
        addCount(to: holder, group: group, order: 6, numberAt: [0, -0.03, 0.0009], captionAt: [0, 0.028, 0.0009])
        return HeroSurfaceSample(materials: materials, slab: slab, goldLine: goldLine, foil: foil, sweep: sweep)
    }

    /// Sample 6's per-frame hook: what A4's `update(_:facing:viewInCard:sweep:)` forwards.
    @MainActor
    final class HeroSurfaceSample {
        let materials: MagicCardSurfaceMaterials
        let slab, goldLine, foil, sweep: ModelEntity

        init(materials: MagicCardSurfaceMaterials, slab: ModelEntity, goldLine: ModelEntity, foil: ModelEntity, sweep: ModelEntity) {
            self.materials = materials
            self.slab = slab
            self.goldLine = goldLine
            self.foil = foil
            self.sweep = sweep
        }

        func update(sweep progress: Float?) {
            materials.update(slab: slab, goldLine: goldLine, foil: foil, sweepEntity: sweep, progress: progress)
        }
    }

    private static func centre(_ entity: ModelEntity, at point: SIMD3<Float>) {
        let bounds = entity.visualBounds(relativeTo: nil)
        entity.position = point - SIMD3(bounds.center.x, bounds.center.y, 0)
    }

    private static func makeLabel(_ text: String) -> Entity {
        let font = UIFont(name: "PingFangSC-Semibold", size: 0.0085) ?? .systemFont(ofSize: 0.0085, weight: .semibold)
        let label = ModelEntity(mesh: .generateText(text, extrusionDepth: 0.0002, font: font),
                                materials: [HologramController.unlit(UIColor(white: 1, alpha: 1), opacity: 0.55)])
        let bounds = label.visualBounds(relativeTo: nil)
        label.position = [-bounds.center.x, -bounds.center.y, 0]
        let holder = Entity()
        holder.addChild(label)
        return holder
    }

    private static func countEntities(_ entity: Entity) -> Int {
        1 + entity.children.reduce(0) { $0 + countEntities($1) }
    }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    // MARK: - Probes

    private static func runProbes(_ stage: LabStage, full: Bool) async {
        let usdRow = Entity()
        usdRow.name = "materials.probe.usd"
        usdRow.position = [-0.21, 0.30, 0]
        stage.desk.addChild(usdRow)
        await MaterialProbeUSD.run(on: usdRow, log: stage.log)
        if full {
            let probeRow = Entity()
            probeRow.name = "materials.probe"
            probeRow.position = [-0.21, 0.48, -0.1]
            stage.desk.addChild(probeRow)
            await MaterialXProbe.run(on: probeRow, log: stage.log)
        }
        stage.log("probe done")
    }
}
