import Foundation
import Metal
import RealityKit

/// Meshes the hero card needs beyond v3's `FXMeshes` (which it reuses for the slab and the rings).
enum HeroCardMeshes {
    /// Outline of a rounded rectangle, counter-clockwise, in the card's frame.
    static func outline(_ rect: V4.HeroCardRect, radius: Float, segmentsPerCorner: Int = 12) -> [SIMD2<Float>] {
        FXMeshes.roundedRectOutline(width: rect.width, height: rect.height, radius: radius,
                                    segmentsPerCorner: segmentsPerCorner)
            .map { $0 + rect.center }
    }

    /// A flat rounded rectangle (normal +Z) as a triangle fan, with positions relative to `origin` and UVs from
    /// `uv(point in the card frame)` — e.g. the art window sampling exactly its part of the avatar's sky.
    static func roundedPlane(_ rect: V4.HeroCardRect, radius: Float, origin: SIMD2<Float>,
                             uv: (SIMD2<Float>) -> SIMD2<Float>) -> MeshResource {
        let ring = outline(rect, radius: radius)
        var positions: [SIMD3<Float>] = [[rect.midX - origin.x, rect.midY - origin.y, 0]]
        var uvs: [SIMD2<Float>] = [flipV(uv(rect.center))]
        for p in ring {
            positions.append([p.x - origin.x, p.y - origin.y, 0])
            uvs.append(flipV(uv(p)))
        }
        var indices: [UInt32] = []
        let n = UInt32(ring.count)
        for i in 0..<n { indices += [0, 1 + i, 1 + (i + 1) % n] }
        var descriptor = MeshDescriptor(name: "v4.card.roundedPlane")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals([SIMD3<Float>](repeating: [0, 0, 1], count: positions.count))
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            print("[card] roundedPlane failed: \(error)")
            return .generatePlane(width: rect.width, height: rect.height, cornerRadius: radius)
        }
    }

    /// RealityKit's texture space has v up; the images and the maths here use v down.
    private static func flipV(_ uv: SIMD2<Float>) -> SIMD2<Float> { [uv.x, 1 - uv.y] }
}

/// A rounded-rectangle face whose **UVs are rewritten in place** (a `LowLevelMesh` UV buffer), so a texture can
/// slide across a fixed outline without a new mesh or material per frame (common rules: no per-frame mesh or
/// material creation). The placeholder surface uses it twice: the foil's hues flowing with the view, and the light
/// sweep's band crossing the card. A1's ShaderGraph foil can do both in the shader and not need it.
@MainActor
final class HeroCardLiveFace {
    private struct Vertex {
        var px: Float, py: Float, pz: Float
        var nx: Float, ny: Float, nz: Float
    }

    let mesh: LowLevelMesh
    let resource: MeshResource
    /// Positions in the card frame (the fan's centre first), for the UV functions.
    let points: [SIMD2<Float>]

    init?(rect: V4.HeroCardRect, radius: Float) {
        let ring = HeroCardMeshes.outline(rect, radius: radius)
        points = [rect.center] + ring
        let vertexCount = points.count
        let indexCount = ring.count * 3
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, layoutIndex: 0, offset: 0),
            .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: MemoryLayout<Float>.stride * 3),
            .init(semantic: .uv0, format: .float2, layoutIndex: 1, offset: 0),
        ]
        let layouts: [LowLevelMesh.Layout] = [
            .init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride),
            .init(bufferIndex: 1, bufferStride: MemoryLayout<SIMD2<Float>>.stride),
        ]
        let descriptor = LowLevelMesh.Descriptor(vertexCapacity: vertexCount, vertexAttributes: attributes,
                                                 vertexLayouts: layouts, indexCapacity: indexCount, indexType: .uint32)
        do {
            mesh = try LowLevelMesh(descriptor: descriptor)
        } catch {
            print("[card] LowLevelMesh failed: \(error)")
            return nil
        }
        let pts = points
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let vertices = raw.bindMemory(to: Vertex.self)
            for (i, p) in pts.enumerated() {
                vertices[i] = Vertex(px: p.x, py: p.y, pz: 0, nx: 0, ny: 0, nz: 1)
            }
        }
        mesh.withUnsafeMutableBytes(bufferIndex: 1) { raw in
            let uvs = raw.bindMemory(to: SIMD2<Float>.self)
            for i in 0..<pts.count { uvs[i] = [0.5, 0.5] }
        }
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            let n = UInt32(ring.count)
            for i in 0..<n {
                indices[Int(i) * 3] = 0
                indices[Int(i) * 3 + 1] = 1 + i
                indices[Int(i) * 3 + 2] = 1 + (i + 1) % n
            }
        }
        let bounds = BoundingBox(min: [rect.minX, rect.minY, -0.0005], max: [rect.maxX, rect.maxY, 0.0005])
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indexCount, topology: .triangle, bounds: bounds)])
        do {
            resource = try MeshResource(from: mesh)
        } catch {
            print("[card] MeshResource(from: LowLevelMesh) failed: \(error)")
            return nil
        }
    }

    /// Rewrites every UV from its point in the card frame (v up, RealityKit's convention). A few dozen vertices.
    func setUVs(_ uv: (SIMD2<Float>) -> SIMD2<Float>) {
        let pts = points
        mesh.withUnsafeMutableBytes(bufferIndex: 1) { raw in
            let uvs = raw.bindMemory(to: SIMD2<Float>.self)
            for (i, p) in pts.enumerated() { uvs[i] = uv(p) }
        }
    }
}
