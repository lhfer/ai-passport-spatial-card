import CoreGraphics
import Foundation
import RealityKit
import UIKit

// Procedural life for 深海微光: the kelp forest, the fish school and the whale. All three are silhouettes in
// moonlit water, so they use unlit materials (inside the shell there is no passthrough light and the IBL is
// too dark to read on thin strips); the scanned rocks and the sand disc are the PBR/IBL part of the world.

/// Instanced, swaying kelp: every strand is a chain of quads bent by a travelling wave, two layers deep
/// (near = wide strands you can walk up to, far = thin tall strands in the haze; the far layer is
/// medium-quality and up).
@MainActor
final class KelpForest {
    let root = Entity()

    private struct Strand {
        var base: SIMD3<Float>
        var yaw: simd_quatf
        var segments: Int
        var segmentLength: Float
        var width: Float
        var phase: Float
        var speed: Float
        var amplitude: Float
        var far: Bool
    }

    private var strands: [Strand] = []
    private var near: (entity: ModelEntity, data: LowLevelInstanceData)?
    private var far: (entity: ModelEntity, data: LowLevelInstanceData)?

    func build(origin: SIMD3<Float>, forward f: SIMD3<Float>, right r: SIMD3<Float>, rng: inout WorldKit.RNG) {
        strands.removeAll()
        for layer in 0..<2 {
            let isFar = layer == 1
            for _ in 0..<(isFar ? 44 : 36) {
                let dist = isFar ? rng.range(6.6, 9.6) : rng.range(4.2, 6.5)
                let along = rng.range(-4.5, 5.0)
                let base = origin - r * dist + f * along - [0, 0.05, 0]
                let height = isFar ? rng.range(4.2, 6.8) : rng.range(2.6, 4.8)
                let toOrigin = simd_normalize(SIMD3<Float>(origin.x - base.x, 0, origin.z - base.z))
                let yaw = simd_quatf(angle: atan2(toOrigin.x, toOrigin.z), axis: [0, 1, 0])
                strands.append(Strand(base: base, yaw: yaw, segments: 8, segmentLength: height / 8,
                                      width: isFar ? rng.range(0.07, 0.12) : rng.range(0.09, 0.17),
                                      phase: rng.range(0, 6.28), speed: rng.range(0.25, 0.45),
                                      amplitude: rng.range(0.07, 0.14), far: isFar))
            }
        }
        let quad = MeshResource.generatePlane(width: 1, height: 1)
        let bounds = BoundingBox(min: [-16, -1, -16], max: [16, 9, 16])
        func layer(_ isFar: Bool, color: UIColor) -> (ModelEntity, LowLevelInstanceData)? {
            let n = strands.filter { $0.far == isFar }.reduce(0) { $0 + $1.segments }
            guard let data = try? LowLevelInstanceData(instanceCount: max(1, n)) else { return nil }
            let entity = ModelEntity(mesh: quad, materials: [KelpForest.material(color)])
            if let comp = try? MeshInstancesComponent(mesh: quad, instances: data, bounds: bounds) { entity.components.set(comp) }
            root.addChild(entity)
            return (entity, data)
        }
        near = layer(false, color: UIColor(hex: "#155A3E"))
        far = layer(true, color: UIColor(hex: "#0C3D36"))
        update(time: 0)
    }

    /// Kelp strip: dark rooted base fading to a lighter, slightly translucent tip; unlit so it reads in the murk.
    private static var cachedTexture: TextureResource?
    private static func material(_ tint: UIColor) -> UnlitMaterial {
        if cachedTexture == nil {
            let size = CGSize(width: 16, height: 128)
            let image = UIGraphicsImageRenderer(size: size).image { ctx in
                let colors = [UIColor(white: 0.3, alpha: 1).cgColor, UIColor(white: 0.82, alpha: 1).cgColor, UIColor(white: 0.62, alpha: 1).cgColor]
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.55, 1])!
                ctx.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
                // Central rib.
                ctx.cgContext.setFillColor(UIColor(white: 0.55, alpha: 1).cgColor)
                ctx.cgContext.fill(CGRect(x: 7, y: 0, width: 2, height: size.height))
            }
            if let cg = image.cgImage {
                cachedTexture = try? TextureResource(image: cg, withName: "sea.kelp", options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
            }
        }
        var m = UnlitMaterial(applyPostProcessToneMap: true)
        m.color = .init(tint: tint, texture: cachedTexture.map { .init($0) })
        m.blending = .opaque
        m.faceCulling = .none
        return m
    }

    func setFarVisible(_ visible: Bool) { far?.entity.isEnabled = visible }

    private var nearMatrices: [simd_float4x4] = []
    private var farMatrices: [simd_float4x4] = []

    func update(time: Float) {
        guard let near, let far else { return }
        nearMatrices.removeAll(keepingCapacity: true)
        farMatrices.removeAll(keepingCapacity: true)
        let lean = 0.06 * sin(time * 0.21) + 0.03 * sin(time * 0.37 + 1)    // slow current shared by the forest
        for s in strands {
            var pos = s.base
            var rot = s.yaw
            for k in 0..<s.segments {
                let along = Float(k) / Float(s.segments - 1)
                let wave = sin(6.2832 * s.speed * time + s.phase + Float(k) * 0.7)
                let bend = s.amplitude * wave * (0.3 + 0.7 * along) + (k == 0 ? lean : 0)
                let nod = s.amplitude * 0.45 * sin(6.2832 * s.speed * 0.7 * time + s.phase * 1.3 + Float(k) * 0.5)
                rot = rot * simd_quatf(angle: bend, axis: [0, 0, 1]) * simd_quatf(angle: nod, axis: [1, 0, 0])
                let centre = pos + rot.act([0, s.segmentLength / 2, 0])
                let width = s.width * (1.05 - 0.4 * along)
                var m = simd_float4x4(rot)
                m.columns.0 *= width
                m.columns.1 *= s.segmentLength * 1.03      // tiny overlap hides the seams
                m.columns.3 = SIMD4<Float>(centre, 1)
                if s.far { farMatrices.append(m) } else { nearMatrices.append(m) }
                pos += rot.act([0, s.segmentLength, 0])
            }
        }
        // One buffer write per layer (a closure per instance is measurably slower in the simulator).
        let n = nearMatrices, fm = farMatrices
        near.data.withMutableTransforms { t in for i in 0..<min(t.count, n.count) { t[i] = n[i] } }
        if far.entity.isEnabled { far.data.withMutableTransforms { t in for i in 0..<min(t.count, fm.count) { t[i] = fm[i] } } }
    }
}

/// ~200 instanced fish following a slow loop around the reef terrace: the school centre runs an ellipse, every
/// fish keeps an offset in the school's moving frame plus its own wiggle, and faces its own heading.
@MainActor
final class FishSchool {
    let root = Entity()
    let count = 200
    private var data: LowLevelInstanceData?
    private var offsets: [SIMD3<Float>] = []
    private var phases: [Float] = []
    private var sizes: [Float] = []
    private var visible = 200
    private var origin: SIMD3<Float> = .zero
    private var f: SIMD3<Float> = [0, 0, -1]
    private var r: SIMD3<Float> = [1, 0, 0]

    func build(origin: SIMD3<Float>, forward: SIMD3<Float>, right: SIMD3<Float>, color: UIColor, rng: inout WorldKit.RNG) {
        self.origin = origin; f = forward; r = right
        offsets.removeAll(); phases.removeAll(); sizes.removeAll()
        for _ in 0..<count {
            // Ellipsoidal school, denser in the middle.
            let u = rng.next(), v = rng.range(0, 6.2832), w = rng.range(-1, 1)
            let rad = pow(u, 0.6)
            let ring = sqrt(max(0, 1 - w * w)) * rad
            offsets.append([cos(v) * ring * 1.9, w * rad * 0.55, sin(v) * ring * 1.1])
            phases.append(rng.range(0, 6.2832))
            sizes.append(rng.range(0.75, 1.35))
        }
        let mesh = FishSchool.fishMesh()
        guard let data = try? LowLevelInstanceData(instanceCount: count) else { return }
        self.data = data
        let entity = ModelEntity(mesh: mesh, materials: [FishSchool.material(color)])
        let bounds = BoundingBox(min: [-12, -1, -12], max: [12, 6, 12])
        if let comp = try? MeshInstancesComponent(mesh: mesh, instances: data, bounds: bounds) { entity.components.set(comp) }
        root.addChild(entity)
        update(time: 0)
    }

    private static func material(_ color: UIColor) -> UnlitMaterial {
        var m = UnlitMaterial(applyPostProcessToneMap: true)
        m.color = .init(tint: color, texture: nil)
        m.blending = .opaque
        m.faceCulling = .none
        return m
    }

    /// 11 cm fish, nose at +x: a flattened diamond body and a triangular tail (double-sided material).
    private static func fishMesh() -> MeshResource {
        let p: [SIMD3<Float>] = [
            [0.055, 0, 0], [0.008, 0.024, 0], [0.008, -0.02, 0], [-0.03, 0, 0],
            [-0.058, 0.026, 0], [-0.058, -0.026, 0], [0.004, 0.001, 0.011], [0.004, 0.001, -0.011],
        ]
        let idx: [UInt32] = [0, 1, 6, 1, 3, 6, 3, 2, 6, 2, 0, 6, 0, 7, 1, 1, 7, 3, 3, 7, 2, 2, 7, 0, 3, 4, 5]
        var d = MeshDescriptor(name: "sea-fish")
        d.positions = MeshBuffers.Positions(p)
        d.normals = MeshBuffers.Normals(p.map { _ in SIMD3<Float>(0, 0, 1) })
        d.textureCoordinates = MeshBuffers.TextureCoordinates(p.map { SIMD2<Float>($0.x * 8 + 0.5, $0.y * 8 + 0.5) })
        d.primitives = .triangles(idx)
        return (try? MeshResource.generate(from: [d])) ?? MeshResource.generateBox(width: 0.1, height: 0.03, depth: 0.02)
    }

    func setVisible(fraction: Float) { visible = max(20, min(count, Int(Float(count) * fraction))) }

    func update(time: Float) {
        guard let data else { return }
        // School centre on an ellipse 2–6 m ahead, 1.4–3 m up; never closer than ~2 m to the wearer.
        let a = 0.075 * time
        let centre = origin + f * (4.0 + 2.0 * cos(a)) + r * (4.6 * sin(a)) + SIMD3<Float>(0, 2.2 + 0.8 * sin(2 * a + 1), 0)
        let tangent = f * (-2.0 * sin(a)) + r * (4.6 * cos(a)) + SIMD3<Float>(0, 1.6 * cos(2 * a + 1), 0)
        let dir = simd_normalize(tangent)
        let side = simd_normalize(simd_cross(dir, [0, 1, 0]))
        let up = SIMD3<Float>(0, 1, 0)
        let breathe = 1 + 0.18 * sin(time * 0.31)
        data.withMutableTransforms { t in
            for i in 0..<count {
                if i >= visible {
                    t[i] = simd_float4x4(diagonal: [0, 0, 0, 1])
                    continue
                }
                let o = offsets[i], ph = phases[i]
                let wiggle = SIMD3<Float>(0.18 * sin(1.3 * time + ph), 0.07 * sin(1.7 * time + ph * 1.1), 0.12 * sin(2.1 * time + ph * 1.7))
                let pos = centre + dir * (o.x * breathe + wiggle.x) + up * (o.y + wiggle.y) + side * (o.z * breathe + wiggle.z)
                let heading = simd_normalize(dir + side * (0.28 * cos(2.1 * time + ph * 1.7)) + up * (0.12 * cos(1.7 * time + ph * 1.1)))
                let yaw = atan2(-heading.z, heading.x)
                let pitch = asin(max(-1, min(1, heading.y)))
                let q = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [0, 0, 1])
                var m = simd_float4x4(q)
                let s = sizes[i]
                m.columns.0 *= s; m.columns.1 *= s; m.columns.2 *= s
                m.columns.3 = SIMD4<Float>(pos, 1)
                t[i] = m
            }
        }
    }
}

/// The whale: a flattened-ellipsoid body, blunt head, tail stock, animated fluke and two pectoral fins, all one
/// dark unlit silhouette. It circles the reef at ~19 m so it passes the wearer's right every lap.
@MainActor
final class WhaleSilhouette {
    let root = Entity()
    private let fluke = Entity()
    private var fins: [Entity] = []
    private var origin: SIMD3<Float> = .zero
    private var f: SIMD3<Float> = [0, 0, -1]
    private var r: SIMD3<Float> = [1, 0, 0]
    private let radius: Float = 24
    private let period: Float = 100

    func build(origin: SIMD3<Float>, forward: SIMD3<Float>, right: SIMD3<Float>) {
        self.origin = origin; f = forward; r = right
        // A shade darker than the haze it swims in, so it reads as a shape in the murk rather than a hole in it.
        let skin = WorldKit.unlit(UIColor(hex: "#12365A"), opacity: 0.92)
        let body = ModelEntity(mesh: .generateSphere(radius: 1), materials: [skin])
        body.scale = [6.0, 1.55, 1.9]
        let head = ModelEntity(mesh: .generateSphere(radius: 1), materials: [skin])
        head.scale = [2.6, 1.65, 2.0]
        head.position = [3.4, 0.05, 0]
        let stock = ModelEntity(mesh: .generateSphere(radius: 1), materials: [skin])
        stock.scale = [2.7, 0.55, 0.7]
        stock.position = [-6.6, 0.25, 0]
        let flukeBlade = ModelEntity(mesh: .generatePlane(width: 4.0, depth: 1.6), materials: [skin])
        flukeBlade.position = [-0.9, 0, 0]
        fluke.addChild(flukeBlade)
        fluke.position = [-8.4, 0.3, 0]
        for side in [Float(-1), 1] {
            let fin = ModelEntity(mesh: .generatePlane(width: 2.4, depth: 1.0), materials: [skin])
            fin.position = [0, 0, side * 0.5]
            let hinge = Entity()
            hinge.addChild(fin)
            hinge.position = [1.4, -0.6, side * 1.6]
            hinge.orientation = simd_quatf(angle: side * -0.35, axis: [1, 0, 0])
            root.addChild(hinge)
            fins.append(hinge)
        }
        root.addChild(body); root.addChild(head); root.addChild(stock); root.addChild(fluke)
        root.scale = SIMD3(repeating: 0.85)
        update(time: 0)
    }

    func update(time: Float) {
        let a = 0.6 + 6.2832 * time / period
        let height = 8.0 + 0.8 * sin(time * 0.12)
        root.position = origin + (r * cos(a) + f * sin(a)) * radius + SIMD3<Float>(0, height, 0)
        let tangent = -r * sin(a) + f * cos(a)
        let roll = simd_quatf(angle: 0.08 * sin(time * 0.3), axis: [1, 0, 0])
        root.orientation = simd_quatf(angle: atan2(-tangent.z, tangent.x), axis: [0, 1, 0]) * roll
        fluke.orientation = simd_quatf(angle: 0.28 * sin(time * 1.15), axis: [0, 0, 1])
        for (i, fin) in fins.enumerated() {
            let side: Float = i == 0 ? -1 : 1
            fin.orientation = simd_quatf(angle: side * (-0.35 + 0.12 * sin(time * 0.9 + Float(i))), axis: [1, 0, 0])
        }
    }
}
