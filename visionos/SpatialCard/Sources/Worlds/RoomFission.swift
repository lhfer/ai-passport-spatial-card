import ARKit
import Foundation
import RealityKit
import UIKit

/// Turns the real room into a world. The SceneReconstruction mesh is cut into ~0.45 m cells (world-space
/// triangles grouped by centroid, with planar UVs so the world material can tile over them). A wavefront
/// from the card converts each cell into the world's look (`Recipe.material`), then the cell breaks away
/// (`Recipe.breakAway`) — how it breaks is the world's signature. Behind the departing cells the engine
/// brings up an opaque shell and switches the space to `.full`; the exit plays the same wave backwards so
/// the world reverses into the real room before the passthrough comes back.
@MainActor
final class RoomFission {
    struct Cell {
        let entity: ModelEntity
        let center: SIMD3<Float>
        let normal: SIMD3<Float>
        let seed: Float
        var distance: Float = 0          // from the wave origin, set per run
        var dressed = false              // world material assigned (done lazily as the wave arrives)
    }

    struct Pose {
        var offset: SIMD3<Float> = .zero
        var rotation: simd_quatf = simd_quatf(angle: 0, axis: [0, 1, 0])
        var scale: SIMD3<Float> = [1, 1, 1]
        var opacity: Float = 1
    }

    struct Recipe {
        /// Converted look of a cell (called once per cell at the start of a run).
        var material: (Cell) -> RealityKit.Material
        /// Break-away pose for `k` 0…1 (0 = still in place, 1 = gone). `t` is wall-clock seconds for wobble.
        var breakAway: (Cell, Float, Float) -> Pose
        var waveSpeed: Float = 2.2          // m/s from the card
        var convertDuration: Float = 0.30   // s: passthrough → world material
        var holdDuration: Float = 0.25      // s: fully converted before breaking away
        var breakDuration: Float = 1.0      // s
    }

    let root = Entity()
    private(set) var cells: [Cell] = []
    private(set) var isPreparing = false
    private var preparedAnchorIDs: Set<UUID> = []
    private var lastPrepare = Date.distantPast
    private var lastPrepareCheck = Date.distantPast
    private var running = false
    private var time: Float = 0
    /// Fraction of cells that have fully broken away (entry) / are fully back and faded (exit).
    private(set) var coverage: Float = 0
    private var waveSpan: Float = 1

    // MARK: - Geometry preparation (cheap to keep warm; runs while the wearer is at the desk)

    /// Rebuild the cells from the current mesh anchors if they changed (throttled). Geometry only — materials
    /// are applied per run.
    func prepare(anchors: [UUID: MeshAnchor], force: Bool = false) {
        // The anchor set only changes every few seconds: compare keys at most once a second (the desk tick calls this
        // at 4 Hz), never while a run or a build is in flight.
        guard force || (!isPreparing && !running && Date().timeIntervalSince(lastPrepare) > 4 && Date().timeIntervalSince(lastPrepareCheck) > 1) else { return }
        lastPrepareCheck = Date()
        let ids = Set(anchors.keys)
        guard force || ids != preparedAnchorIDs, !isPreparing, !running else { return }
        lastPrepare = Date()
        preparedAnchorIDs = ids
        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for anchor in anchors.values {
            triangles.append(contentsOf: RoomFission.triangles(of: anchor))
        }
        if triangles.isEmpty { return }
        Task { await build(triangles: triangles) }
    }

    /// Simulator / no scene reconstruction: a 4 × 2.6 × 4 m room around `center` (floor y = floorY).
    func prepareSynthetic(center: SIMD3<Float>, floorY: Float) {
        guard cells.isEmpty, !isPreparing else { return }
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        let hw: Float = 2.2, hd: Float = 2.4, h: Float = 2.6
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
            // Subdivide into 0.4 m pieces so the chunker has enough triangles to work with.
            let n = 8
            for i in 0..<n {
                for j in 0..<n {
                    let u0 = Float(i) / Float(n), u1 = Float(i + 1) / Float(n), v0 = Float(j) / Float(n), v1 = Float(j + 1) / Float(n)
                    func p(_ u: Float, _ v: Float) -> SIMD3<Float> { simd_mix(simd_mix(a, b, SIMD3(repeating: u)), simd_mix(d, c, SIMD3(repeating: u)), SIMD3(repeating: v)) }
                    tris.append((p(u0, v0), p(u1, v0), p(u1, v1)))
                    tris.append((p(u0, v0), p(u1, v1), p(u0, v1)))
                }
            }
        }
        let c = SIMD3<Float>(center.x, floorY, center.z)
        quad(c + [-hw, 0, -hd], c + [hw, 0, -hd], c + [hw, 0, hd], c + [-hw, 0, hd])                  // floor
        quad(c + [-hw, h, hd], c + [hw, h, hd], c + [hw, h, -hd], c + [-hw, h, -hd])                  // ceiling
        quad(c + [-hw, 0, -hd], c + [hw, 0, -hd], c + [hw, h, -hd], c + [-hw, h, -hd])                // back wall
        quad(c + [hw, 0, hd], c + [-hw, 0, hd], c + [-hw, h, hd], c + [hw, h, hd])                    // front wall
        quad(c + [-hw, 0, hd], c + [-hw, 0, -hd], c + [-hw, h, -hd], c + [-hw, h, hd])                // left
        quad(c + [hw, 0, -hd], c + [hw, 0, hd], c + [hw, h, hd], c + [hw, h, -hd])                    // right
        Task { await build(triangles: tris) }
    }

    private nonisolated static func triangles(of anchor: MeshAnchor) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        let g = anchor.geometry
        let v = g.vertices, f = g.faces
        let vbase = v.buffer.contents().advanced(by: v.offset)
        func vertex(_ i: Int) -> SIMD3<Float> {
            let p = vbase.advanced(by: i * v.stride)
            let x = p.load(as: Float.self), y = p.load(fromByteOffset: 4, as: Float.self), z = p.load(fromByteOffset: 8, as: Float.self)
            let w = anchor.originFromAnchorTransform * SIMD4<Float>(x, y, z, 1)
            return SIMD3(w.x, w.y, w.z)
        }
        let fbase = f.buffer.contents()
        var out: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        out.reserveCapacity(f.count)
        for t in 0..<f.count {
            func index(_ k: Int) -> Int {
                let p = fbase.advanced(by: (t * 3 + k) * f.bytesPerIndex)
                return f.bytesPerIndex == 2 ? Int(p.load(as: UInt16.self)) : Int(p.load(as: UInt32.self))
            }
            out.append((vertex(index(0)), vertex(index(1)), vertex(index(2))))
        }
        return out
    }

    /// Set when `begin` ran while the geometry was still building; applied as soon as the cells exist.
    private var pendingBegin: (recipe: Recipe, origin: SIMD3<Float>)?

    private func build(triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)], cellSize: Float = 0.45) async {
        isPreparing = true
        defer {
            isPreparing = false
            if let pending = pendingBegin {
                pendingBegin = nil
                begin(recipe: pending.recipe, origin: pending.origin)
            }
        }
        // Group by centroid cell.
        var groups: [SIMD3<Int32>: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]] = [:]
        for tri in triangles {
            let c = (tri.0 + tri.1 + tri.2) / 3
            let key = SIMD3<Int32>(Int32(floor(c.x / cellSize)), Int32(floor(c.y / cellSize)), Int32(floor(c.z / cellSize)))
            groups[key, default: []].append(tri)
        }
        var newCells: [Cell] = []
        var seed = WorldKit.RNG(0xF155)
        var built = 0
        for (_, tris) in groups {
            guard tris.count >= 1 else { continue }
            // ~40 small meshes per frame keeps the desk animation smooth while a room builds.
            built += 1
            if built % 40 == 0 { await Task.yield() }
            var center = SIMD3<Float>.zero
            var normalSum = SIMD3<Float>.zero
            for t in tris { center += (t.0 + t.1 + t.2) / 3 }
            center /= Float(tris.count)
            var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = []
            var indices: [UInt32] = []
            positions.reserveCapacity(tris.count * 3); normals.reserveCapacity(tris.count * 3); uvs.reserveCapacity(tris.count * 3)
            for t in tris {
                var n = simd_cross(t.1 - t.0, t.2 - t.0)
                let len = simd_length(n)
                n = len > 1e-8 ? n / len : SIMD3<Float>(0, 1, 0)
                normalSum += n
                let a = abs(n)
                for p in [t.0, t.1, t.2] {
                    positions.append(p - center)
                    normals.append(n)
                    // Planar UV on the plane perpendicular to the dominant axis, 2 tiles per metre.
                    let uv: SIMD2<Float> = a.y >= a.x && a.y >= a.z ? [p.x, p.z] : (a.x >= a.z ? [p.z, p.y] : [p.x, p.y])
                    uvs.append(uv * 2)
                }
                let base = UInt32(positions.count - 3)
                indices += [base, base + 1, base + 2]      // one winding: every recipe material is double-sided (faceCulling .none)
            }
            var d = MeshDescriptor(name: "room-cell")
            d.positions = MeshBuffers.Positions(positions)
            d.normals = MeshBuffers.Normals(normals)
            d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
            d.primitives = .triangles(indices)
            guard let mesh = try? MeshResource.generate(from: [d]) else { continue }
            let entity = ModelEntity(mesh: mesh, materials: [WorldKit.unlit(.clear, opacity: 0.01)])
            entity.position = center
            entity.isEnabled = false
            entity.components.set(ModelSortGroupComponent(group: WorldEngine.sortGroup, order: WorldEngine.worldOrder))
            newCells.append(Cell(entity: entity, center: center, normal: simd_normalize(normalSum + [0, 1e-4, 0]), seed: seed.next()))
        }
        for c in cells { c.entity.removeFromParent() }
        cells = newCells
        for c in cells { root.addChild(c.entity) }
        print("[fission] \(cells.count) cells from \(triangles.count) triangles")
    }

    // MARK: - Runs

    private var recipe: Recipe?

    /// Start a run: distances from `origin`, materials applied, everything in place at opacity 0.
    func begin(recipe: Recipe, origin: SIMD3<Float>) {
        self.recipe = recipe
        if isPreparing { pendingBegin = (recipe, origin) }
        running = true
        time = 0
        coverage = 0
        var maxD: Float = 0.5
        for i in cells.indices {
            cells[i].distance = simd_length(cells[i].center - origin)
            cells[i].dressed = false
            maxD = max(maxD, cells[i].distance)
            let e = cells[i].entity
            e.components.set(OpacityComponent(opacity: 0))
            e.transform = Transform(translation: cells[i].center)
            e.isEnabled = false
        }
        waveSpan = maxD
        root.isEnabled = true
    }

    /// Start the reverse run of the last recipe: the cells keep their materials and `dressed` flags (no material
    /// uploads on the first frame), come back enabled at opacity 0 and fly in as `update(reverse: true)` advances.
    /// Falls back to `begin` when no forward run happened.
    func beginReverse(origin: SIMD3<Float>) {
        guard let recipe else { return }
        guard cells.contains(where: \.dressed) else { begin(recipe: recipe, origin: origin); return }
        running = true
        time = 0
        coverage = 0
        for i in cells.indices {
            let e = cells[i].entity
            e.components.set(OpacityComponent(opacity: 0))
            e.transform = Transform(translation: cells[i].center)
            e.isEnabled = cells[i].dressed
        }
        root.isEnabled = true
    }

    /// Total seconds a forward run needs for the wave to finish everywhere.
    var runDuration: Float {
        guard let r = recipe else { return 1 }
        return waveSpan / r.waveSpeed + r.convertDuration + r.holdDuration + r.breakDuration
    }

    /// Advance the wave. `elapsed` seconds since `begin`; `reverse` plays the whole thing backwards (cells fly
    /// back, re-form the world-material room, then fade into the passthrough).
    func update(elapsed: Float, dt: Float, reverse: Bool) {
        guard running, let r = recipe else { return }
        time += dt
        var gone = 0
        let total = runDuration
        for i in cells.indices {
            let c = cells[i]
            // Forward local time for this cell.
            let local = (reverse ? total - elapsed : elapsed) - c.distance / r.waveSpeed
            var pose = Pose()
            if local <= 0 {
                pose.opacity = 0
                if reverse == false { continue }        // not reached yet: nothing to draw, nothing to dress
            }
            if !c.dressed {
                // Dress the cell the frame the wave reaches it, so 400 material uploads spread over the run.
                c.entity.model?.materials = [r.material(c)]
                c.entity.isEnabled = true
                cells[i].dressed = true
            }
            if local <= 0 {
                pose.opacity = 0
            } else if local < r.convertDuration {
                pose.opacity = local / r.convertDuration
            } else if local < r.convertDuration + r.holdDuration {
                pose.opacity = 1
            } else {
                let k = min(1, (local - r.convertDuration - r.holdDuration) / r.breakDuration)
                pose = r.breakAway(c, k, time)
                if k >= 1 { gone += 1 }
            }
            let e = c.entity
            e.transform = Transform(scale: pose.scale, rotation: pose.rotation, translation: c.center + pose.offset)
            e.components.set(OpacityComponent(opacity: max(0, min(1, pose.opacity))))
        }
        coverage = cells.isEmpty ? min(1, elapsed / max(0.5, total)) : Float(gone) / Float(cells.count)
    }

    func end() {
        running = false
        for c in cells {
            c.entity.isEnabled = false
            c.entity.transform = Transform(translation: c.center)
        }
        root.isEnabled = false
    }

    // MARK: - Recipes (one per world; each breaks the room in its own way)

    static func codeSea(_ d: WorldDescriptor) -> Recipe {
        let glyphs = WorldKit.glyphGridTexture(color: d.primaryColor)
        return Recipe(
            material: { _ in FXMaterials.glow(glyphs, tint: .white, opacity: 0.9) },
            breakAway: { c, k, t in
                // Code falls: the cell drops with gravity, tumbling slightly, and dims as it goes.
                var p = Pose()
                let fall = k * k * (1.6 + 1.2 * c.seed)
                p.offset = [0, -fall, 0]
                p.rotation = simd_quatf(angle: k * (0.4 + 0.6 * c.seed), axis: simd_normalize(SIMD3<Float>(c.seed - 0.5, 0.2, 0.5 - c.seed)))
                p.opacity = 1 - k * k
                return p
            }, waveSpeed: 2.2, convertDuration: 0.3, holdDuration: 0.35, breakDuration: 1.1)
    }

    static func neonCity(_ d: WorldDescriptor) -> Recipe {
        let panels = WorldKit.panelTexture(edge: d.primaryColor, edge2: d.secondaryColor)
        return Recipe(
            material: { _ in FXMaterials.glow(panels, tint: .white, opacity: 0.95) },
            breakAway: { c, k, _ in
                // Billboards fly off: slide out along the surface normal, lift, yaw, and dim.
                var p = Pose()
                let e = 1 - pow(1 - k, 3)
                p.offset = c.normal * (0.8 * e) + SIMD3<Float>(0, 0.4 * e, 0)
                p.rotation = simd_quatf(angle: (c.seed - 0.5) * 0.8 * e, axis: [0, 1, 0])
                p.opacity = 1 - e
                return p
            }, waveSpeed: 3.0, convertDuration: 0.2, holdDuration: 0.4, breakDuration: 0.9)
    }

    static func deepSea(_ d: WorldDescriptor) -> Recipe {
        let caustics = WorldKit.causticsTexture()
        return Recipe(
            material: { _ in FXMaterials.glow(caustics, tint: d.secondaryColor, opacity: 0.6) },
            breakAway: { c, k, t in
                // Dissolves in water: sinks slowly, wobbling, thinning out.
                var p = Pose()
                p.offset = [sin(t * 1.3 + c.seed * 6) * 0.05 * k, -0.6 * k * k, cos(t * 1.1 + c.seed * 4) * 0.05 * k]
                p.rotation = simd_quatf(angle: 0.3 * k * sin(t + c.seed * 5), axis: [1, 0, 0])
                p.opacity = 1 - k
                return p
            }, waveSpeed: 1.6, convertDuration: 0.45, holdDuration: 0.3, breakDuration: 1.6)
    }

    static func paperValley(_ d: WorldDescriptor) -> Recipe {
        let paper = WorldKit.paperTexture()
        return Recipe(
            material: { _ in WorldKit.unlit(.white, texture: paper) },
            breakAway: { c, k, _ in
                // Folds away: the sheet hinges 90° about a tangent through its centre and flattens.
                var p = Pose()
                let e = k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2
                let tangent = simd_normalize(simd_cross(c.normal, abs(c.normal.y) > 0.9 ? [1, 0, 0] : [0, 1, 0]))
                p.rotation = simd_quatf(angle: e * (.pi / 2), axis: tangent)
                p.scale = [1, 1, 1] - (SIMD3<Float>(1, 1, 1) - abs(tangent)) * (0.98 * e)
                p.opacity = 1 - max(0, (k - 0.7) / 0.3)
                return p
            }, waveSpeed: 1.8, convertDuration: 0.35, holdDuration: 0.3, breakDuration: 0.8)
    }
}
