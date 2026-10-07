import Foundation
import RealityKit

/// Meshes the v4 materials are drawn on. All of them follow the library's convention (`V4.MagicMaterialGraphs`):
/// the card in the object's X-Y plane, centred, +Z the face normal — the graphs read `position(object)` in metres, so
/// the geometry only has to be the right size, not carry special UVs.
@MainActor
enum MagicMeshes {
    /// A flat rounded rectangle (triangle fan), normal +Z, UVs spanning its bounding box (u → +x, v → −y).
    static func roundedPlane(width: Float, height: Float, radius: Float, segmentsPerCorner: Int = 12) -> MeshResource {
        let outline = FXMeshes.roundedRectOutline(width: width, height: height, radius: radius, segmentsPerCorner: segmentsPerCorner)
        var positions: [SIMD3<Float>] = [[0, 0, 0]]
        var uvs: [SIMD2<Float>] = [[0.5, 0.5]]
        for point in outline {
            positions.append([point.x, point.y, 0])
            uvs.append([point.x / width + 0.5, 0.5 - point.y / height])
        }
        var indices: [UInt32] = []
        let n = UInt32(outline.count)
        for i in 0..<n {
            indices += [0, 1 + i, 1 + (i + 1) % n]
        }
        var descriptor = MeshDescriptor(name: "v4RoundedPlane")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals([SIMD3<Float>](repeating: [0, 0, 1], count: positions.count))
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor]))
            ?? MeshResource.generatePlane(width: width, height: height, cornerRadius: radius)
    }

    /// The 12 mm slab (v3's `FXMeshes.roundedSlab`, reused: face UVs + a side band with averaged normals).
    static func slab(width: Float, height: Float, depth: Float, radius: Float) -> MeshResource {
        FXMeshes.roundedSlab(width: width, height: height, depth: depth, radius: radius)
    }

    /// A band around a rounded outline, `inside` metres inward and `outside` metres outward of it — enough area for
    /// the gold line, its halo and the light spilling past the edge, and nothing more, so the edge costs a ring of
    /// pixels rather than the whole card. Counter-clockwise from +Z (v3's `roundedRectRing` winds the other way,
    /// which only works with culling off).
    static func ring(width: Float, height: Float, radius: Float, inside: Float, outside: Float,
                     segmentsPerCorner: Int = 16) -> MeshResource {
        let outer = FXMeshes.roundedRectOutline(width: width + 2 * outside, height: height + 2 * outside,
                                                radius: radius + outside, segmentsPerCorner: segmentsPerCorner)
        let inner = FXMeshes.roundedRectOutline(width: width - 2 * inside, height: height - 2 * inside,
                                                radius: max(0.0005, radius - inside), segmentsPerCorner: segmentsPerCorner)
        let n = min(outer.count, inner.count)
        var positions: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(n * 2)
        for i in 0..<n {
            positions.append([outer[i].x, outer[i].y, 0])
            positions.append([inner[i].x, inner[i].y, 0])
            let u = Float(i) / Float(n)
            uvs.append([u, 0])
            uvs.append([u, 1])
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(n * 6)
        for i in 0..<n {
            let o0 = UInt32(i * 2), i0 = o0 + 1
            let o1 = UInt32(((i + 1) % n) * 2), i1 = o1 + 1
            indices += [o0, o1, i0, i0, o1, i1]
        }
        var descriptor = MeshDescriptor(name: "v4Ring")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals([SIMD3<Float>](repeating: [0, 0, 1], count: positions.count))
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [descriptor]))
            ?? FXMeshes.roundedRectRing(width: width, height: height, radius: radius, thickness: inside)
    }

    /// The gold line's ring on a slab outline: 7 mm inside (inset + line + halo), 6 mm outside (the spill).
    static func goldEdgeRing(width: Float, height: Float, radius: Float) -> MeshResource {
        ring(width: width, height: height, radius: radius, inside: 0.007, outside: 0.006)
    }
}
