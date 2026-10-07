import Metal
import RealityKit
import UIKit

/// The warm pool of light a glowing card throws on the desk under it (A3 目标 1.3): an **additive** radial gradient
/// lying 1 mm above the desk, whose intensity and spread follow `V4.LightPool` (the card's height and brightness).
///
/// Three decisions, each forced by something:
/// - **Additive, not alpha.** An alpha-blended gold decal *paints over* the desk — on passthrough it reads as a
///   sticker. `UnlitMaterial.Program` with `blendMode = .add` (visionOS 2+) only ever adds light, which is what a
///   glow on a real table does.
/// - **A hole over the device.** The pool is centred under the card, i.e. right on the AI Passport. The art bible's
///   H0 rule forbids persistent virtual geometry over the hardware (the film has to read its screen), so the mesh is
///   a ring whose inner edge is the device footprint plus a margin — the light stops exactly where the device's
///   body begins, which is also where a real shadowing object would stop it.
/// - **No new mesh or material per frame.** The ring is a `LowLevelMesh`: when the pool changes size its 192 vertices
///   are rewritten in place (the outer outline follows the pool's ellipse, the UVs map the gradient onto it), and its
///   intensity is an `OpacityComponent`. The material is built once.
@MainActor
final class DeskLightPool {
    /// Lies in the x–z plane of whatever it is parented to (S: the device's screen frame), 1 mm above the desk.
    let entity: ModelEntity
    var model: V4.LightPool
    private let mesh: LowLevelMesh
    private let ring: V4.LightPoolRing
    private(set) var intensity: Float = -1
    private(set) var halfExtent: SIMD2<Float> = .zero
    /// UV rewrites skipped because the extent moved less than this (metres).
    /// UV / outline rewrites are skipped while the extent moves less than this (metres): 0.5 mm on a 0.35–0.45 m
    /// pool is invisible, and it keeps the rewrite to every ~8th frame of the ±3 cm bob instead of every frame.
    private let extentEpsilon: Float = 0.0005
    /// Opacity writes are skipped for changes smaller than this (≈ 1 % of the pool's range).
    private let intensityEpsilon: Float = 0.004
    /// The ring flattened to scalars for the per-frame rewrite: inner x / z, outer ray direction x / z. In a Debug
    /// build every SIMD operator is an unspecialised generic call; a SIMD loop over 192 vertices cost 0.4 ms at p95,
    /// the scalar one below a small fraction of that.
    private let innerX: [Float], innerZ: [Float], rayX: [Float], rayZ: [Float]

    /// Warm gold → amber (the art bible's `gold` / `amber`, and a deeper amber at the rim). The first pass started
    /// at `goldHot`, near white, and on a dark desk an additive near-white only reads as "lighter brown".
    static let coreColor = UIColor(hex: "#FFD58A")
    static let midColor = UIColor(hex: "#FFB347")
    static let rimColor = UIColor(hex: "#E0822E")

    /// One interleaved vertex: position, normal, uv (32 bytes).
    private struct Vertex {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    /// - Parameters:
    ///   - holeHalf: half-extent (x, S z) kept clear over the device: its footprint plus the tracking margin.
    ///   - holeRadius: corner radius of that clear rectangle.
    init(model: V4.LightPool = V4.LightPool(), holeHalf: SIMD2<Float>, holeRadius: Float) async throws {
        self.model = model
        ring = V4.LightPoolRing.make(holeHalf: holeHalf, holeRadius: holeRadius, outerHalf: model.maxHalfExtent)
        innerX = ring.positions[..<ring.count].map { $0.x }
        innerZ = ring.positions[..<ring.count].map { $0.y }
        rayX = ring.directions.map { $0.x }
        rayZ = ring.directions.map { $0.y }
        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: ring.positions.count,
            vertexAttributes: [
                .init(semantic: .position, format: .float3, layoutIndex: 0, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
                .init(semantic: .normal, format: .float3, layoutIndex: 0, offset: MemoryLayout<Vertex>.offset(of: \.normal)!),
                .init(semantic: .uv0, format: .float2, layoutIndex: 0, offset: MemoryLayout<Vertex>.offset(of: \.uv)!),
            ],
            vertexLayouts: [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)],
            indexCapacity: ring.indices.count,
            indexType: .uint32)
        mesh = try LowLevelMesh(descriptor: descriptor)
        let indices = ring.indices
        mesh.withUnsafeMutableIndices { raw in
            let target = raw.bindMemory(to: UInt32.self)
            for (i, index) in indices.enumerated() { target[i] = index }
        }
        let outer = model.maxHalfExtent
        let bounds = BoundingBox(min: [-outer.x, -0.001, -outer.y], max: [outer.x, 0.001, outer.y])
        mesh.parts.replaceAll([LowLevelMesh.Part(indexCount: indices.count, topology: .triangle, bounds: bounds)])

        var material = UnlitMaterial(program: await DeskLightPool.additiveProgram())
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        var texture = MaterialParameters.Texture(try DeskLightPool.gradientTexture())
        texture.sampler = MaterialParameters.Texture.Sampler(samplerDescriptor)
        material.color = .init(tint: .white, texture: texture)
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.faceCulling = .none
        material.writesDepth = false

        entity = ModelEntity(mesh: try await MeshResource(from: mesh), materials: [material])
        entity.name = "grounding.lightPool"
        // Light is not matter: the pool neither casts nor receives the card's grounding shadow.
        GroundingShadows.optOut(entity)
        entity.components.set(OpacityComponent(opacity: 0))
        // Fills the vertex buffer (the extent starts at zero, so the first update always writes).
        update(height: 0.1, brightness: 1)
    }

    /// The one additive program every glow of this module shares (built once; `UnlitMaterial.Program` creation is
    /// async and not free).
    static func additiveProgram() async -> UnlitMaterial.Program {
        if let cached = additive { return cached }
        var descriptor = UnlitMaterial.Program.Descriptor()
        descriptor.blendMode = .add
        descriptor.applyPostProcessToneMap = false
        let program = await UnlitMaterial.Program(descriptor: descriptor)
        additive = program
        return program
    }

    private static var additive: UnlitMaterial.Program?

    /// An additive, double-sided, depth-read-only glow: `texture` × `tint`.
    static func additiveMaterial(texture: TextureResource, tint: UIColor) async -> UnlitMaterial {
        var material = UnlitMaterial(program: await additiveProgram())
        material.color = .init(tint: tint, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }

    /// Per frame. `height` is the card's lowest edge above the desk (metres), `brightness` its glow (1 = at rest).
    func update(height: Float, brightness: Float) {
        let newIntensity = model.intensity(height: height, brightness: brightness)
        if abs(newIntensity - intensity) > intensityEpsilon {
            intensity = newIntensity
            entity.components.set(OpacityComponent(opacity: min(1, newIntensity)))
        }
        let newExtent = model.halfExtent(height: height)
        guard simd_reduce_max(simd_abs(newExtent - halfExtent)) > extentEpsilon else { return }
        writeVertices(halfExtent: newExtent)
    }

    /// Re-fits the ring to a pool of `halfExtent` and rewrites the vertex buffer in place — the scalar twin of
    /// `V4.LightPoolRing.forEachFitted` (which the unit tests check), with no allocation and no SIMD in the loop.
    private func writeVertices(halfExtent newExtent: SIMD2<Float>) {
        halfExtent = newExtent
        let hx = max(newExtent.x, 1e-4), hz = max(newExtent.y, 1e-4)
        let ux = 1 / (2 * hx), uz = 1 / (2 * hz)
        let n = innerX.count
        let stride = MemoryLayout<Vertex>.stride / MemoryLayout<Float>.stride
        let offsetUV = MemoryLayout<Vertex>.offset(of: \.uv)! / MemoryLayout<Float>.stride
        let offsetNormal = MemoryLayout<Vertex>.offset(of: \.normal)! / MemoryLayout<Float>.stride
        innerX.withUnsafeBufferPointer { ix in
        innerZ.withUnsafeBufferPointer { iz in
        rayX.withUnsafeBufferPointer { dx in
        rayZ.withUnsafeBufferPointer { dz in
            mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
                let f = raw.bindMemory(to: Float.self)
                func put(_ i: Int, _ x: Float, _ z: Float) {
                    let b = i * stride
                    f[b] = x; f[b + 1] = 0; f[b + 2] = z
                    f[b + offsetNormal] = 0; f[b + offsetNormal + 1] = 1; f[b + offsetNormal + 2] = 0
                    f[b + offsetUV] = 0.5 + x * ux
                    f[b + offsetUV + 1] = 0.5 - z * uz
                }
                for i in 0..<n { put(i, ix[i], iz[i]) }
                for i in 0..<n {
                    let cx = dx[i], cz = dz[i]
                    let r = hx * hz / max(1e-6, ((hz * cx) * (hz * cx) + (hx * cz) * (hx * cz)).squareRoot())
                    put(n + i, cx * r, cz * r)
                }
            }
        }}}}
    }

    /// 256² premultiplied warm radial gradient reaching zero on the inscribed circle (the ring's outer edge), with a
    /// hot core and ±½ LSB dither: an 8-bit gradient this dark bands visibly on a dim desk otherwise.
    static func gradientTexture(size: Int = 256) throws -> TextureResource {
        func components(_ color: UIColor) -> SIMD3<Float> {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return [Float(r), Float(g), Float(b)]
        }
        let core = components(coreColor), mid = components(midColor), rim = components(rimColor)
        func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
            let t = max(0, min(1, (x - e0) / (e1 - e0)))
            return t * t * (3 - 2 * t)
        }
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        var seed: UInt32 = 0x9E37_79B9
        for y in 0..<size {
            let fy = (Float(y) + 0.5) / Float(size) * 2 - 1
            for x in 0..<size {
                let fx = (Float(x) + 0.5) / Float(size) * 2 - 1
                let r = min(1, sqrt(fx * fx + fy * fy))
                let q = 1 - r * r
                // Broad body plus a tighter hot core; exactly 0 at r = 1 with zero slope, so the rim has no edge.
                let falloff = 0.78 * q * q + 0.22 * pow(q, 7)
                var color = simd_mix(core, mid, SIMD3<Float>(repeating: smoothstep(0, 0.4, r)))
                color = simd_mix(color, rim, SIMD3<Float>(repeating: smoothstep(0.4, 1, r)))
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let dither = (Float(seed >> 8) / Float(1 << 24) - 0.5) / 255
                let i = (y * size + x) * 4
                for c in 0..<3 {
                    let v = max(0, min(1, color[c] * falloff + (falloff > 0 ? dither : 0)))
                    pixels[i + c] = UInt8(v * 255 + 0.5)
                }
                pixels[i + 3] = UInt8(max(0, min(1, falloff)) * 255 + 0.5)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw CocoaError(.coderInvalidValue)
        }
        return try TextureResource(image: image, withName: "grounding.lightPool.gradient",
                                   options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
    }
}
