import Foundation
import RealityKit
import UIKit

/// Round 4 of the probe (`--materials-probe`): the USD path, built with `V4.ShadeGraph`, answering what the library
/// depends on — additive blending, IBL in a graph, the view vector's sign, colour space, bloom, and visionOS 27's
/// code-first `ShaderGraphMaterial.Program`.
@MainActor
enum MaterialProbeUSD {
    typealias G = V4.ShadeGraph

    static func load(_ graph: G) async throws -> ShaderGraphMaterial {
        let problems = graph.problems()
        precondition(problems.isEmpty, "\(graph.name): \(problems)")
        return try await ShaderGraphMaterial(named: graph.materialPath, from: Data(graph.usda().utf8))
    }

    static func tile(_ material: some RealityKit.Material, at slot: Int, on parent: Entity, backdrop: Bool = false) -> ModelEntity {
        let position = SIMD3<Float>(Float(slot % 8) * 0.06, -Float(slot / 8) * 0.06, 0)
        let tile = ModelEntity(mesh: .generatePlane(width: 0.05, height: 0.05, cornerRadius: 0.004), materials: [material])
        tile.position = position
        parent.addChild(tile)
        if backdrop {
            // A white card behind the right half: additive light brightens it, alpha blending veils it.
            let white = ModelEntity(mesh: .generatePlane(width: 0.025, height: 0.05), materials: [UnlitMaterial(color: .white)])
            white.position = position + [0.0125, 0, -0.004]
            parent.addChild(white)
        }
        return tile
    }

    static func run(on parent: Entity, log: (String) -> Void) async {
        let gold = G.Value.srgb("#FFD58A")
        var slot = 0
        func record(_ label: String, _ start: CFTimeInterval, _ material: ShaderGraphMaterial) {
            log(String(format: "[probe] OK   %@ (%.1f ms) params=%@", label, (CACurrentMediaTime() - start) * 1000,
                       material.parameterNames.sorted().description))
        }
        func fail(_ label: String, _ error: Error) {
            let ns = error as NSError
            log("[probe] FAIL \(label) error=\(error) | \(error.localizedDescription) | \(ns.domain) \(ns.code)")
        }

        // R1 premultiplied, opacity 0 → additive.
        do {
            let start = CACurrentMediaTime()
            var g = G(name: "R1_premult_add")
            let color = g.parameter("color", gold)
            g.setSurface(g.unlitSurface(color: color.s, opacity: G.f(0), premultiplied: true))
            let m = try await load(g)
            record("R1_premult_add (white backdrop on the right half)", start, m)
            _ = tile(m, at: slot, on: parent, backdrop: true)
        } catch { fail("R1_premult_add", error) }
        slot += 1

        // R2 plain alpha 0.5, for comparison.
        var alphaMaterial: ShaderGraphMaterial?
        do {
            let start = CACurrentMediaTime()
            var g = G(name: "R2_alpha")
            let color = g.parameter("color", gold)
            g.setSurface(g.unlitSurface(color: color.s, opacity: G.f(0.5), premultiplied: false))
            let m = try await load(g)
            alphaMaterial = m
            record("R2_alpha 0.5 (white backdrop on the right half)", start, m)
            _ = tile(m, at: slot, on: parent, backdrop: true)
        } catch { fail("R2_alpha", error) }
        slot += 1

        // R3 the same material switched to additive through visionOS 27's Program descriptor.
        if var m = alphaMaterial {
            do {
                let start = CACurrentMediaTime()
                var descriptor = m.program.descriptor
                log("[probe] R3 loaded program: blendMode=\(String(describing: descriptor.blendMode)) lighting=\(descriptor.lightingModel) inputs=\(descriptor.inputValues.keys.sorted())")
                descriptor.blendMode = .add
                m.program = try await ShaderGraphMaterial.Program(descriptor: descriptor)
                record("R3_program_blend_add (white backdrop on the right half)", start, m)
                _ = tile(m, at: slot, on: parent, backdrop: true)
            } catch { fail("R3_program_blend_add", error) }
        }
        slot += 1

        // R4 environment radiance in an unlit graph.
        do {
            let start = CACurrentMediaTime()
            var g = G(name: "R4_env_unlit")
            let gain = g.parameter("gain", .float(1))
            let n = g.normal(space: "world")
            let env = g.environmentRadiance(normal: n.s, roughness: 0.2)
            let c = g.mul(g.add(env.specular.s, env.diffuse.s).s, gain.s)
            g.setSurface(g.unlitSurface(color: c.s, opacity: G.f(1), premultiplied: false))
            let m = try await load(g)
            record("R4_env_unlit", start, m)
            _ = tile(m, at: slot, on: parent)
        } catch { fail("R4_env_unlit", error) }
        slot += 1

        // R5 environment radiance feeding a PBR surface's emissive.
        do {
            let start = CACurrentMediaTime()
            var g = G(name: "R5_env_pbr")
            let gain = g.parameter("gain", .float(1))
            let n = g.normal(space: "world")
            let env = g.environmentRadiance(normal: n.s, roughness: 0.2)
            let c = g.mul(g.add(env.specular.s, env.diffuse.s).s, gain.s)
            g.setSurface(g.pbrSurface(baseColor: .value(.color3([0, 0, 0])), emissive: c.s, roughness: G.f(1),
                                      specular: G.f(0), opacity: G.f(1), premultiplied: false))
            let m = try await load(g)
            record("R5_env_pbr_emissive", start, m)
            _ = tile(m, at: slot, on: parent)
        } catch { fail("R5_env_pbr", error) }
        slot += 1

        // R6 / R7 glass: PBR, clear-coated, 5 % body — premultiplied vs not (does the reflection survive the opacity?).
        for premultiplied in [true, false] {
            let label = premultiplied ? "R6_glass_premult" : "R7_glass_alpha"
            do {
                let start = CACurrentMediaTime()
                var g = G(name: label)
                let opacity = g.parameter("opacity", .float(0.05))
                let base: G.Source = premultiplied ? g.mul(.value(.color3([1, 1, 1])), opacity.s).s : .value(.color3([1, 1, 1]))
                g.setSurface(g.pbrSurface(baseColor: base, emissive: .value(.color3([0, 0, 0])), roughness: G.f(0.08),
                                          specular: G.f(1), opacity: opacity.s, clearcoat: G.f(1),
                                          clearcoatRoughness: G.f(0.02), premultiplied: premultiplied))
                let m = try await load(g)
                record(label, start, m)
                _ = tile(m, at: slot, on: parent, backdrop: true)
            } catch { fail(label, error) }
            slot += 1
        }

        // R8 which way the view direction points: white if it points at the eye (the tile faces +Z, the eye).
        do {
            let start = CACurrentMediaTime()
            var g = G(name: "R8_viewdir_sign")
            let gain = g.parameter("gain", .float(1))
            let v = g.viewDirection(space: "object")
            let z = g.extract(v.s, 2)
            let c = g.convert(g.mul(g.clamp(z.s).s, gain.s).s, to: .color3)
            g.setSurface(g.unlitSurface(color: c.s, opacity: G.f(1), premultiplied: false))
            let m = try await load(g)
            record("R8_viewdir_sign (white = points to the eye)", start, m)
            _ = tile(m, at: slot, on: parent)
        } catch { fail("R8_viewdir_sign", error) }
        slot += 1

        // R9 transformvector object → world of +Z: blue if the tile faces world +Z.
        do {
            let start = CACurrentMediaTime()
            var g = G(name: "R9_transformvector")
            let gain = g.parameter("gain", .float(1))
            let w = g.transformVector(.value(.vector3([0, 0, 1])), from: "object", to: "world")
            let c = g.convert(g.mul(g.abs(w.s).s, gain.s).s, to: .color3)
            g.setSurface(g.unlitSurface(color: c.s, opacity: G.f(1), premultiplied: false))
            let m = try await load(g)
            record("R9_transformvector (blue = faces world +Z)", start, m)
            _ = tile(m, at: slot, on: parent)
        } catch { fail("R9_transformvector", error) }
        slot += 1

        // R10 / R11 colour space: linearised constant vs CGColor through setParameter — should match.
        do {
            let start = CACurrentMediaTime()
            var g = G(name: "R10_const_oldgold")
            let gain = g.parameter("gain", .float(1))
            let c = g.mul(.value(.srgb("#C9A45C")), gain.s)
            g.setSurface(g.unlitSurface(color: c.s, opacity: G.f(1), premultiplied: false))
            let m = try await load(g)
            record("R10_const_oldgold (linearised #C9A45C)", start, m)
            _ = tile(m, at: slot, on: parent)
        } catch { fail("R10_const", error) }
        slot += 1
        do {
            let start = CACurrentMediaTime()
            var g = G(name: "R11_param_oldgold")
            let color = g.parameter("color", .color3([1, 0, 1]))
            g.setSurface(g.unlitSurface(color: color.s, opacity: G.f(1), premultiplied: false))
            var m = try await load(g)
            try m.setParameter(name: "color", value: .color(UIColor(hex: "#C9A45C").cgColor))
            record("R11_param_oldgold (setParameter CGColor #C9A45C)", start, m)
            _ = tile(m, at: slot, on: parent)
        } catch { fail("R11_param", error) }
        slot += 1

        // R12 / R13 bloom: unlit HDR vs PBR emissive HDR, both under a BloomComponent.
        do {
            let start = CACurrentMediaTime()
            var g = G(name: "R12_unlit_hdr")
            let gain = g.parameter("gain", .float(4))
            let c = g.mul(.value(gold), gain.s)
            g.setSurface(g.unlitSurface(color: c.s, opacity: G.f(1), premultiplied: false))
            let m = try await load(g)
            record("R12_unlit_hdr x4 + BloomComponent", start, m)
            let t = tile(m, at: slot, on: parent)
            t.scale = [0.3, 0.3, 1]
            t.components.set(BloomComponent(scope: .hierarchical))
        } catch { fail("R12", error) }
        slot += 1
        do {
            let start = CACurrentMediaTime()
            var g = G(name: "R13_pbr_emissive_hdr")
            let gain = g.parameter("gain", .float(4))
            let c = g.mul(.value(gold), gain.s)
            g.setSurface(g.pbrSurface(baseColor: .value(.color3([0, 0, 0])), emissive: c.s, roughness: G.f(1),
                                      specular: G.f(0), opacity: G.f(1), premultiplied: false))
            let m = try await load(g)
            record("R13_pbr_emissive_hdr x4 + BloomComponent", start, m)
            let t = tile(m, at: slot, on: parent)
            t.scale = [0.3, 0.3, 1]
            t.components.set(BloomComponent(scope: .hierarchical))
        } catch { fail("R13", error) }
        slot += 1

        // R14 visionOS 27 code-first graph, with its input's initial value.
        do {
            let start = CACurrentMediaTime()
            let library = ShaderGraph.NodeLibrary(version: .materialX138)
            guard let unlitDef = library.definition(named: "ND_realitykit_unlit_surfaceshader") else { throw CocoaError(.featureUnsupported) }
            let graph = try ShaderGraph(named: "SGProbe", inputs: [.init(name: "tint", type: .cgColor3)],
                                        outputs: [.init(name: "surface", type: .surfaceShader)])
            let unlitKey = try graph.addNode(try library.makeNode(from: unlitDef))
            try graph.connect(graph.arguments.name, outputPort: "tint", to: unlitKey, inputPort: "color")
            try graph.connect(unlitKey, outputPort: "out", to: graph.results.name, inputPort: "surface")
            let descriptor = try ShaderGraphMaterial.Program.Descriptor(
                inferredFrom: graph, inputValues: ["tint": .color(UIColor.cyan.cgColor)])
            var m = ShaderGraphMaterial(program: try await ShaderGraphMaterial.Program(descriptor: descriptor))
            try m.setParameter(name: "tint", value: .color(UIColor.orange.cgColor))
            record("R14_swift_shadergraph_api (orange after setParameter)", start, m)
            _ = tile(m, at: slot, on: parent)
        } catch { fail("R14_swift_shadergraph_api", error) }
        slot += 1
    }
}
