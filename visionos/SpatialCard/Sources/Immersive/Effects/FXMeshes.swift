import Foundation
import RealityKit

/// Small procedural meshes for the glow layer.
enum FXMeshes {
    /// Open cylinder band (no caps) between `yMin` and `yMax`, normals inward, seen from inside.
    static func cylinderBand(radius: Float, yMin: Float, yMax: Float, segments: Int = 48) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for s in 0...segments {
            let theta = Float(s) / Float(segments) * 2 * .pi
            let n = SIMD3<Float>(-cos(theta), 0, -sin(theta))
            positions.append([cos(theta) * radius, yMin, sin(theta) * radius]); normals.append(n); uvs.append([Float(s) / Float(segments), 0])
            positions.append([cos(theta) * radius, yMax, sin(theta) * radius]); normals.append(n); uvs.append([Float(s) / Float(segments), 1])
        }
        for s in 0..<segments {
            let a = UInt32(s * 2), b = a + 1, c = a + 2, d = a + 3
            indices += [a, c, b, b, c, d, a, b, c, b, d, c]   // both windings: visible from either side
        }
        var d = MeshDescriptor(name: "cylinder-band")
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        d.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [d])) ?? MeshResource.generateSphere(radius: radius)
    }

    /// Hemisphere (`upper` = y ≥ 0, else y ≤ 0) with normals pointing inward, for shells seen from inside.
    static func hemisphere(radius: Float, upper: Bool, rings: Int = 12, segments: Int = 32) -> MeshResource {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []
        for r in 0...rings {
            let phi = (Float(r) / Float(rings)) * (.pi / 2)          // 0 = pole, π/2 = equator
            let y = cos(phi) * (upper ? 1 : -1)
            let ring = sin(phi)
            for s in 0...segments {
                let theta = Float(s) / Float(segments) * 2 * .pi
                let p = SIMD3<Float>(cos(theta) * ring, y, sin(theta) * ring)
                positions.append(p * radius)
                normals.append(-p)
                uvs.append([Float(s) / Float(segments), Float(r) / Float(rings)])
            }
        }
        let stride = UInt32(segments + 1)
        for r in 0..<rings {
            for s in 0..<segments {
                let a = UInt32(r) * stride + UInt32(s), b = a + 1, c = a + stride, d = c + 1
                if upper { indices += [a, b, c, b, d, c] } else { indices += [a, c, b, b, c, d] }
            }
        }
        var d = MeshDescriptor(name: upper ? "hemisphere-upper" : "hemisphere-lower")
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        d.primitives = .triangles(indices)
        return (try? MeshResource.generate(from: [d])) ?? MeshResource.generateSphere(radius: radius)
    }

    /// Flat rounded-rectangle ring in the X-Y plane (normal +Z): outer size `width × height`,
    /// corner radius `radius`, band width `thickness` toward the inside. Used for the bevel frame.
    static func roundedRectRing(width: Float, height: Float, radius: Float, thickness: Float, segmentsPerCorner: Int = 10) -> MeshResource {
        let outer = roundedRectOutline(width: width, height: height, radius: radius, segmentsPerCorner: segmentsPerCorner)
        let inner = roundedRectOutline(width: width - 2 * thickness, height: height - 2 * thickness,
                                       radius: max(0.001, radius - thickness), segmentsPerCorner: segmentsPerCorner)
        let n = outer.count
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(n * 2)
        for i in 0..<n {
            positions.append([outer[i].x, outer[i].y, 0])
            positions.append([inner[i].x, inner[i].y, 0])
            normals.append([0, 0, 1]); normals.append([0, 0, 1])
            let u = Float(i) / Float(n)
            uvs.append([u, 0]); uvs.append([u, 1])
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(n * 6)
        for i in 0..<n {
            let o0 = UInt32(i * 2), i0 = o0 + 1
            let o1 = UInt32(((i + 1) % n) * 2), i1 = o1 + 1
            indices += [o0, i0, o1, i0, i1, o1]
        }
        var descriptor = MeshDescriptor(name: "roundedRectRing")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return MeshResource.generatePlane(width: width, height: height, cornerRadius: radius)
        }
    }

    /// Solid rounded-rectangle slab in the X-Y plane, centred on the origin: front and back faces (triangle
    /// fans, normals ±Z) joined by a side band whose normals point outward and are averaged across the corners,
    /// so a clear-coated material puts a continuous highlight around the edge.
    ///
    /// `MeshResource.generateBox(cornerRadius:)` caps the radius at half the thickness (6 mm on a 12 mm plate),
    /// which cannot make the 30 mm corners the card needs — hence this mesh.
    static func roundedSlab(width: Float, height: Float, depth: Float, radius: Float, segmentsPerCorner: Int = 10) -> MeshResource {
        let outline = roundedRectOutline(width: width, height: height, radius: radius, segmentsPerCorner: segmentsPerCorner)
        let n = outline.count
        guard n > 2, depth > 0 else { return MeshResource.generatePlane(width: width, height: height, cornerRadius: radius) }
        let hz = depth / 2
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        // Per-vertex outward normal of the outline: the mean of the two edges meeting at it (equal on a straight
        // edge, a smooth sweep around a corner).
        var edgeNormals: [SIMD2<Float>] = []
        edgeNormals.reserveCapacity(n)
        for i in 0..<n {
            let t = outline[(i + 1) % n] - outline[i]
            let e = SIMD2<Float>(t.y, -t.x)                       // outward for a counter-clockwise outline
            edgeNormals.append(simd_length(e) > 1e-6 ? simd_normalize(e) : [1, 0])
        }

        func addFace(z: Float, normal: SIMD3<Float>, flip: Bool) {
            let center = UInt32(positions.count)
            positions.append([0, 0, z]); normals.append(normal); uvs.append([0.5, 0.5])
            for point in outline {
                positions.append([point.x, point.y, z])
                normals.append(normal)
                uvs.append([point.x / width + 0.5, 0.5 - point.y / height])
            }
            for i in 0..<n {
                let a = center + 1 + UInt32(i), b = center + 1 + UInt32((i + 1) % n)
                indices += flip ? [center, b, a] : [center, a, b]
            }
        }
        addFace(z: hz, normal: [0, 0, 1], flip: false)
        addFace(z: -hz, normal: [0, 0, -1], flip: true)

        // Side band: two rings (front / back) with the averaged outward normals.
        let bandStart = UInt32(positions.count)
        for i in 0..<n {
            let previous = edgeNormals[(i + n - 1) % n], current = edgeNormals[i]
            let sum = previous + current
            let flat = simd_length(sum) > 1e-6 ? simd_normalize(sum) : current
            let normal = SIMD3<Float>(flat.x, flat.y, 0)
            let u = Float(i) / Float(n)
            positions.append([outline[i].x, outline[i].y, hz]); normals.append(normal); uvs.append([u, 0])
            positions.append([outline[i].x, outline[i].y, -hz]); normals.append(normal); uvs.append([u, 1])
        }
        for i in 0..<n {
            let f0 = bandStart + UInt32(i * 2), b0 = f0 + 1
            let f1 = bandStart + UInt32(((i + 1) % n) * 2), b1 = f1 + 1
            indices += [f0, b0, b1, f0, b1, f1]
        }

        var descriptor = MeshDescriptor(name: "roundedSlab")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return MeshResource.generatePlane(width: width, height: height, cornerRadius: radius)
        }
    }

    /// Parallelogram in the X-Y plane (normal +Z), centred on the origin: `width × height` with the top edge
    /// pushed `skew` metres to the right of the bottom one. The glint that crosses a note cover is a leaning
    /// band, and skewing the quad keeps its **travel** horizontal — rotating the entity instead would tilt the
    /// sweep's path as well. UVs run 0…1 across the band (u) and along it (v).
    static func skewedQuad(width: Float, height: Float, skew: Float) -> MeshResource {
        let hw = width / 2, hh = height / 2, hs = skew / 2
        let positions: [SIMD3<Float>] = [
            [-hw - hs, -hh, 0], [hw - hs, -hh, 0], [-hw + hs, hh, 0], [hw + hs, hh, 0]
        ]
        var descriptor = MeshDescriptor(name: "skewedQuad")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals([SIMD3<Float>](repeating: [0, 0, 1], count: 4))
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates([[0, 1], [1, 1], [0, 0], [1, 0]])
        descriptor.primitives = .triangles([0, 1, 2, 1, 3, 2])
        return (try? MeshResource.generate(from: [descriptor])) ?? MeshResource.generatePlane(width: width, height: height)
    }

    /// Counter-clockwise outline of a rounded rectangle centred on the origin.
    static func roundedRectOutline(width: Float, height: Float, radius: Float, segmentsPerCorner: Int) -> [SIMD2<Float>] {
        let hw = width / 2, hh = height / 2
        let r = min(radius, min(hw, hh))
        let centers: [SIMD2<Float>] = [[hw - r, hh - r], [-hw + r, hh - r], [-hw + r, -hh + r], [hw - r, -hh + r]]
        var points: [SIMD2<Float>] = []
        for (corner, c) in centers.enumerated() {
            let start = Float(corner) * .pi / 2
            for s in 0...segmentsPerCorner {
                let a = start + (Float(s) / Float(segmentsPerCorner)) * .pi / 2
                points.append(c + SIMD2<Float>(cos(a), sin(a)) * r)
            }
        }
        return points
    }
}

// MARK: - Lofted fan (V3-2a H0)

extension FXMeshes {
    /// A hollow shell lofted from a **superellipse** on the device plane up to an ellipse at `height`: the
    /// volumetric beam with its middle cut out.
    ///
    /// V3-2a H0 forbids persistent geometry inside the device's footprint, and the projector's three cones
    /// all had their apex exactly on the screen. A cone cannot be hollowed; this shell can — its foot is a
    /// rounded rectangle that goes **around** the device (an `n = 4` superellipse, which contains the
    /// footprint's corners at the half extents the rig computes) and it opens out to the same elliptical
    /// cross-section the flattened cones used to have, so the light still reads as a fan across the card.
    ///
    /// `topOffset` shears the shell: the hand form leans it from the device's outline to the card's bottom
    /// edge on the hinge instead of straight up.
    ///
    /// UVs: `u` runs around, `v` is **1 at the foot** and 0 at the top — the convention `fx.coneGlow` and
    /// `fx.coneGlowTop` are drawn for.
    static func loftedFan(height: Float, bottomHalf: SIMD2<Float>, topHalf: SIMD2<Float>,
                          topOffset: SIMD3<Float> = .zero, segments: Int = 64) -> MeshResource {
        let n = max(8, segments)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        positions.reserveCapacity(n * 2)
        for i in 0..<n {
            let t = Float(i) / Float(n) * 2 * .pi
            let c = cos(t), s = sin(t)
            // Superellipse (n = 4): x = a·sgn(c)·|c|^0.5, z = b·sgn(s)·|s|^0.5.
            let foot = SIMD3<Float>(bottomHalf.x * (c < 0 ? -1 : 1) * sqrt(abs(c)), 0,
                                    bottomHalf.y * (s < 0 ? -1 : 1) * sqrt(abs(s)))
            let top = SIMD3<Float>(topHalf.x * c, height, topHalf.y * s) + topOffset
            positions.append(foot)
            positions.append(top)
            // Outward normal of the shell at this station, near enough for an additive glow.
            let outward = simd_normalize(SIMD3<Float>(foot.x, 0, foot.z) + SIMD3<Float>(1e-6, 0, 0))
            normals.append(outward); normals.append(outward)
            let u = Float(i) / Float(n)
            uvs.append([u, 1]); uvs.append([u, 0])
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(n * 6)
        for i in 0..<n {
            let b0 = UInt32(i * 2), t0 = b0 + 1
            let b1 = UInt32(((i + 1) % n) * 2), t1 = b1 + 1
            indices += [b0, t0, b1, t0, t1, b1]
        }
        var descriptor = MeshDescriptor(name: "loftedFan")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        descriptor.primitives = .triangles(indices)
        do {
            return try MeshResource.generate(from: [descriptor])
        } catch {
            return MeshResource.generateCone(height: height, radius: max(topHalf.x, topHalf.y))
        }
    }
}
