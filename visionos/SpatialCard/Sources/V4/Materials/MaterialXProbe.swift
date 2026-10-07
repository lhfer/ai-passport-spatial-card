import Foundation
import RealityKit
import UIKit

/// `--lab materials --materials-probe`: loads a ladder of tiny MaterialX documents and logs, for each one, whether
/// `ShaderGraphMaterial(materialXLabel:data:)` accepted it, how long it took, the exact error text when it did not,
/// and which names `parameterNames` exposes. Every finding in the A1 report about "what the SDK does" is reproducible
/// with this one flag — the probe is the evidence, not a scratch file.
@MainActor
enum MaterialXProbe {
    struct Case {
        var label: String
        var note: String
        var xml: String
        /// A parameter the probe tries to set after loading (name, value), to prove `setParameter` reaches the graph.
        var set: (String, MaterialParameters.Value)?
    }

    /// Runs every case and lays the loaded ones out as small tiles on `parent` (a row, left to right).
    static func run(on parent: Entity, log: (String) -> Void) async {
        var x: Float = 0
        for probe in cases {
            let start = CACurrentMediaTime()
            do {
                var material = try await ShaderGraphMaterial(materialXLabel: probe.label, data: Data(probe.xml.utf8))
                let ms = (CACurrentMediaTime() - start) * 1000
                var setResult = "-"
                if let (name, value) = probe.set {
                    do {
                        try material.setParameter(name: name, value: value)
                        setResult = "set \(name) ok"
                    } catch {
                        setResult = "set \(name) FAILED: \(error) / \(error.localizedDescription)"
                    }
                }
                log(String(format: "[probe] OK   %@ (%.1f ms) params=%@ %@ — %@",
                           probe.label, ms, material.parameterNames.sorted().description, setResult, probe.note))
                let tile = ModelEntity(mesh: .generatePlane(width: 0.05, height: 0.05, cornerRadius: 0.004), materials: [material])
                tile.position = slot(x)
                parent.addChild(tile)
            } catch {
                let ms = (CACurrentMediaTime() - start) * 1000
                let ns = error as NSError
                log(String(format: "[probe] FAIL %@ (%.1f ms) error=%@ | localized=%@ | domain=%@ code=%ld — %@",
                           probe.label, ms, String(describing: error), error.localizedDescription, ns.domain, ns.code,
                           probe.note))
            }
            x += 0.06
        }
        await runUSD(on: parent, x: &x, log: log)
        await runShaderGraphAPI(on: parent, x: x, log: log)
    }

    /// The same ladder for USD text: a `Material` prim whose `inputs:*` feed the graph (the Reality Composer Pro shape).
    static func runUSD(on parent: Entity, x: inout Float, log: (String) -> Void) async {
        for probe in usdCases {
            let start = CACurrentMediaTime()
            do {
                var material = try await ShaderGraphMaterial(named: probe.label, from: Data(probe.xml.utf8))
                let ms = (CACurrentMediaTime() - start) * 1000
                var setResult = "-"
                if let (name, value) = probe.set {
                    do {
                        try material.setParameter(name: name, value: value)
                        setResult = "set \(name) ok"
                    } catch {
                        setResult = "set \(name) FAILED: \(error)"
                    }
                }
                log(String(format: "[probe] OK   %@ (%.1f ms) params=%@ %@ — %@",
                           probe.label, ms, material.parameterNames.sorted().description, setResult, probe.note))
                let tile = ModelEntity(mesh: .generatePlane(width: 0.05, height: 0.05, cornerRadius: 0.004), materials: [material])
                tile.position = slot(x)
                parent.addChild(tile)
            } catch {
                let ms = (CACurrentMediaTime() - start) * 1000
                let ns = error as NSError
                log(String(format: "[probe] FAIL %@ (%.1f ms) error=%@ | localized=%@ | domain=%@ code=%ld — %@",
                           probe.label, ms, String(describing: error), error.localizedDescription, ns.domain, ns.code,
                           probe.note))
            }
            x += 0.06
        }
    }

    /// visionOS 27's code-first graph API (`ShaderGraph` + `ShaderGraphMaterial.Program`): one argument → unlit colour,
    /// deliberately **without** `inputValues` — the expected failure is `missingInputValues(["tint"])`. The working
    /// version (initial values given) is `MaterialProbeUSD` R14.
    static func runShaderGraphAPI(on parent: Entity, x: Float, log: (String) -> Void) async {
        let start = CACurrentMediaTime()
        do {
            let library = ShaderGraph.NodeLibrary(version: .materialX138)
            guard let unlitDef = library.definition(named: "ND_realitykit_unlit_surfaceshader") else {
                log("[probe] FAIL SG_api: no ND_realitykit_unlit_surfaceshader in NodeLibrary(.materialX138)")
                return
            }
            log("[probe] SG_api unlit inputs: " + unlitDef.inputs.map { "\($0.name):\($0.type)" }.joined(separator: ", "))
            let colorType = unlitDef.inputs.first { $0.name == "color" }?.type ?? .float3
            let graph = try ShaderGraph(named: "SGProbe",
                                        inputs: [.init(name: "tint", type: colorType)],
                                        outputs: [.init(name: "surface", type: .surfaceShader)])
            let unlit = try library.makeNode(from: unlitDef)
            let unlitKey = try graph.addNode(unlit)
            try graph.connect(graph.arguments.name, outputPort: "tint", to: unlitKey, inputPort: "color")
            try graph.connect(unlitKey, outputPort: "out", to: graph.results.name, inputPort: "surface")
            let descriptor = try ShaderGraphMaterial.Program.Descriptor(inferredFrom: graph)
            let program = try await ShaderGraphMaterial.Program(descriptor: descriptor)
            var material = ShaderGraphMaterial(program: program)
            var setResult = "-"
            do {
                try material.setParameter(name: "tint", value: .color(UIColor.orange.cgColor))
                setResult = "set tint ok"
            } catch {
                setResult = "set tint FAILED: \(error)"
            }
            let ms = (CACurrentMediaTime() - start) * 1000
            log(String(format: "[probe] OK   SG_api (%.1f ms) params=%@ %@", ms, material.parameterNames.sorted().description, setResult))
            let tile = ModelEntity(mesh: .generatePlane(width: 0.05, height: 0.05, cornerRadius: 0.004), materials: [material])
            tile.position = slot(x)
            parent.addChild(tile)
        } catch {
            log("[probe] FAIL SG_api_without_inputValues (expected FAIL) error=\(error) | \(error.localizedDescription)")
        }
    }

    /// Tiles in rows of eight (x advances 6 cm per case).
    static func slot(_ x: Float) -> SIMD3<Float> {
        let i = Int((x / 0.06).rounded())
        return [Float(i % 8) * 0.06, -Float(i / 8) * 0.06, 0]
    }

    /// Wraps a body in a MaterialX document.
    static func doc(_ body: String, version: String = "1.38") -> String {
        """
        <?xml version="1.0"?>
        <materialx version="\(version)">
        \(body)
        </materialx>
        """
    }

    /// Unlit material (through the in-document RealityKit nodedef) whose colour is the float output of the node named
    /// `probe_out` in `nodes` — the node-availability probes.
    static func floatProbe(_ label: String, _ nodes: String, defs: String = "", note: String,
                           set: (String, MaterialParameters.Value)? = nil) -> Case {
        Case(label: label, note: note, xml: doc("""
          \(MaterialXLibrary.unlitDef)
          \(defs)
          <nodegraph name="NG_\(label)">
            \(nodes)
            <convert name="probe_color" type="color3">
              <input name="in" type="float" nodename="probe_out" />
            </convert>
            <output name="out" type="color3" nodename="probe_color" />
          </nodegraph>
          <realitykit_unlit_surfaceshader name="S_\(label)" type="surfaceshader" nodedef="ND_realitykit_unlit_surfaceshader">
            <input name="color" type="color3" nodegraph="NG_\(label)" output="out" />
          </realitykit_unlit_surfaceshader>
          <surfacematerial name="\(label)" type="material">
            <input name="surfaceshader" type="surfaceshader" nodename="S_\(label)" />
          </surfacematerial>
        """), set: set)
    }

    static var cases: [Case] {
        [
            // Negative control (round 1): a RealityKit surface node with no nodedef in the document. CoreRealityIO's
            // MaterialX library is plain 1.38 stdlib/pbrlib/bxdf, so the node resolves to nothing and ShaderGraph says
            // "A surface node is required" → LoadError.internalImportError.
            Case(label: "P01_unlit_no_def", note: "realitykit_unlit_surfaceshader WITHOUT nodedef (expected FAIL)", xml: doc("""
              <realitykit_unlit_surfaceshader name="S" type="surfaceshader">
                <input name="color" type="color3" value="1, 0.2, 0.2" />
              </realitykit_unlit_surfaceshader>
              <surfacematerial name="P01_unlit_no_def" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: nil),
            // Standard MaterialX unlit surface: Apple maps ND_surface_unlit onto its unlit shader.
            Case(label: "Q01_surface_unlit", note: "stdlib surface_unlit, emission_color", xml: doc("""
              <surface_unlit name="S" type="surfaceshader">
                <input name="emission_color" type="color3" value="1, 0.3, 0.3" />
              </surface_unlit>
              <surfacematerial name="Q01_surface_unlit" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: ("emission_color", .color(UIColor.green.cgColor))),
            // RealityKit unlit with its nodedef copied into the document.
            Case(label: "Q02_unlit_def", note: "realitykit_unlit_surfaceshader + in-doc nodedef", xml: doc("""
              \(MaterialXLibrary.unlitDef)
              <realitykit_unlit_surfaceshader name="S" type="surfaceshader" nodedef="ND_realitykit_unlit_surfaceshader">
                <input name="color" type="color3" value="1, 0.6, 0.2" />
              </realitykit_unlit_surfaceshader>
              <surfacematerial name="Q02_unlit_def" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: ("color", .color(UIColor.green.cgColor))),
            // The same, declared MaterialX 1.39 (the runtime ships 1.38 and 1.39.4 libraries).
            Case(label: "Q02b_unlit_def_139", note: "realitykit_unlit_surfaceshader + in-doc nodedef, version 1.39", xml: doc("""
              \(MaterialXLibrary.unlitDef)
              <realitykit_unlit_surfaceshader name="S" type="surfaceshader" nodedef="ND_realitykit_unlit_surfaceshader">
                <input name="color" type="color3" value="0.2, 0.9, 0.9" />
              </realitykit_unlit_surfaceshader>
              <surfacematerial name="Q02b_unlit_def_139" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """, version: "1.39"), set: ("color", .color(UIColor.cyan.cgColor))),
            // Nodegraph interface input, shader outside.
            Case(label: "Q03_ng_interface", note: "nodegraph <input tint> + interfacename, realitykit unlit outside", xml: doc("""
              \(MaterialXLibrary.unlitDef)
              <nodegraph name="NG">
                <input name="tint" type="color3" value="0.2, 0.4, 1" />
                <multiply name="m" type="color3">
                  <input name="in1" type="color3" interfacename="tint" />
                  <input name="in2" type="float" value="1.0" />
                </multiply>
                <output name="color_out" type="color3" nodename="m" />
              </nodegraph>
              <realitykit_unlit_surfaceshader name="S" type="surfaceshader" nodedef="ND_realitykit_unlit_surfaceshader">
                <input name="color" type="color3" nodegraph="NG" output="color_out" />
              </realitykit_unlit_surfaceshader>
              <surfacematerial name="Q03_ng_interface" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: ("tint", .color(UIColor.yellow.cgColor))),
            // Nodegraph containing the shader.
            Case(label: "Q04_ng_shader_inside", note: "nodegraph outputs the surfaceshader", xml: doc("""
              \(MaterialXLibrary.unlitDef)
              <nodegraph name="NG">
                <input name="tint" type="color3" value="0.2, 1, 0.4" />
                <realitykit_unlit_surfaceshader name="S" type="surfaceshader" nodedef="ND_realitykit_unlit_surfaceshader">
                  <input name="color" type="color3" interfacename="tint" />
                </realitykit_unlit_surfaceshader>
                <output name="out" type="surfaceshader" nodename="S" />
              </nodegraph>
              <surfacematerial name="Q04_ng_shader_inside" type="material">
                <input name="surfaceshader" type="surfaceshader" nodegraph="NG" output="out" />
              </surfacematerial>
            """), set: ("tint", .color(UIColor.magenta.cgColor))),
            // Two interface inputs, the shape every real material uses.
            Case(label: "Q05_two_params", note: "color3 + float interface inputs, transparent", xml: doc("""
              \(MaterialXLibrary.unlitDef)
              <nodegraph name="NG">
                <input name="tint" type="color3" value="1, 1, 1" />
                <input name="opacity" type="float" value="0.5" />
                <multiply name="m" type="color3">
                  <input name="in1" type="color3" interfacename="tint" />
                  <input name="in2" type="float" value="1.0" />
                </multiply>
                <multiply name="o" type="float">
                  <input name="in1" type="float" interfacename="opacity" />
                  <input name="in2" type="float" value="1.0" />
                </multiply>
                <output name="color_out" type="color3" nodename="m" />
                <output name="opacity_out" type="float" nodename="o" />
              </nodegraph>
              <realitykit_unlit_surfaceshader name="S" type="surfaceshader" nodedef="ND_realitykit_unlit_surfaceshader">
                <input name="color" type="color3" nodegraph="NG" output="color_out" />
                <input name="opacity" type="float" nodegraph="NG" output="opacity_out" />
              </realitykit_unlit_surfaceshader>
              <surfacematerial name="Q05_two_params" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: ("opacity", .float(0.9))),
            // RealityKit PBR with its nodedef in the document.
            Case(label: "Q06_pbr_def", note: "realitykit_pbr_surfaceshader + in-doc nodedef", xml: doc("""
              \(MaterialXLibrary.pbrDef)
              <realitykit_pbr_surfaceshader name="S" type="surfaceshader" nodedef="ND_realitykit_pbr_surfaceshader">
                <input name="baseColor" type="color3" value="0.9, 0.8, 0.5" />
                <input name="roughness" type="float" value="0.3" />
                <input name="metallic" type="float" value="1" />
              </realitykit_pbr_surfaceshader>
              <surfacematerial name="Q06_pbr_def" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: nil),
            // Standard surfaces.
            Case(label: "Q07_standard_surface", note: "stdlib standard_surface", xml: doc("""
              <standard_surface name="S" type="surfaceshader">
                <input name="base_color" type="color3" value="0.4, 0.8, 1" />
                <input name="metalness" type="float" value="0.5" />
              </standard_surface>
              <surfacematerial name="Q07_standard_surface" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: nil),
            Case(label: "Q08_usdpreview", note: "UsdPreviewSurface", xml: doc("""
              <UsdPreviewSurface name="S" type="surfaceshader">
                <input name="diffuseColor" type="color3" value="0.9, 0.9, 0.3" />
                <input name="opacity" type="float" value="0.5" />
              </UsdPreviewSurface>
              <surfacematerial name="Q08_usdpreview" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: nil),
            // Node availability.
            floatProbe("Q10_viewdir", """
              <realitykit_viewdirection name="v" type="vector3" nodedef="ND_realitykit_viewdirection_vector3"><input name="space" type="string" value="world" /></realitykit_viewdirection>
              <normal name="n" type="vector3"><input name="space" type="string" value="world" /></normal>
              <dotproduct name="probe_out" type="float"><input name="in1" type="vector3" nodename="v" /><input name="in2" type="vector3" nodename="n" /></dotproduct>
            """, defs: MaterialXLibrary.viewDirectionDef, note: "realitykit_viewdirection(world) · normal(world)"),
            floatProbe("Q11_campos", """
              <realitykit_cameraposition name="c" type="vector3" nodedef="ND_realitykit_cameraposition_vector3"><input name="space" type="string" value="world" /></realitykit_cameraposition>
              <position name="p" type="vector3"><input name="space" type="string" value="world" /></position>
              <subtract name="d" type="vector3"><input name="in1" type="vector3" nodename="c" /><input name="in2" type="vector3" nodename="p" /></subtract>
              <magnitude name="probe_out" type="float"><input name="in" type="vector3" nodename="d" /></magnitude>
            """, defs: MaterialXLibrary.cameraPositionDef, note: "realitykit_cameraposition − position(world)"),
            floatProbe("Q12_noise3d", """
              <position name="p" type="vector3"><input name="space" type="string" value="object" /></position>
              <multiply name="ps" type="vector3"><input name="in1" type="vector3" nodename="p" /><input name="in2" type="float" value="60" /></multiply>
              <noise3d name="probe_out" type="float"><input name="position" type="vector3" nodename="ps" /><input name="amplitude" type="float" value="0.5" /><input name="pivot" type="float" value="0.5" /></noise3d>
            """, note: "noise3d on object position"),
            floatProbe("Q13_fractal3d", """
              <position name="p" type="vector3"><input name="space" type="string" value="object" /></position>
              <multiply name="ps" type="vector3"><input name="in1" type="vector3" nodename="p" /><input name="in2" type="float" value="60" /></multiply>
              <fractal3d name="probe_out" type="float"><input name="position" type="vector3" nodename="ps" /><input name="octaves" type="integer" value="3" /></fractal3d>
            """, note: "fractal3d"),
            floatProbe("Q14_time", """
              <time name="t" type="float" />
              <sin name="probe_out" type="float"><input name="in" type="float" nodename="t" /></sin>
            """, note: "time → sin"),
            floatProbe("Q15_noise2d_uv", """
              <texcoord name="uv" type="vector2" />
              <multiply name="uvs" type="vector2"><input name="in1" type="vector2" nodename="uv" /><input name="in2" type="float" value="12" /></multiply>
              <noise2d name="probe_out" type="float"><input name="texcoord" type="vector2" nodename="uvs" /><input name="amplitude" type="float" value="0.5" /><input name="pivot" type="float" value="0.5" /></noise2d>
            """, note: "texcoord → noise2d"),
            floatProbe("Q16_worley", """
              <texcoord name="uv" type="vector2" />
              <multiply name="uvs" type="vector2"><input name="in1" type="vector2" nodename="uv" /><input name="in2" type="float" value="8" /></multiply>
              <worleynoise2d name="probe_out" type="float"><input name="texcoord" type="vector2" nodename="uvs" /></worleynoise2d>
            """, note: "worleynoise2d"),
            Case(label: "Q17_envrad", note: "realitykit_environment_radiance specular → unlit", xml: doc("""
              \(MaterialXLibrary.unlitDef)
              \(MaterialXLibrary.environmentRadianceDef)
              <nodegraph name="NG">
                <realitykit_environment_radiance name="env" type="multioutput" nodedef="ND_realitykit_environment_radiance">
                  <input name="roughness" type="half" value="0.1" />
                  <input name="specular" type="half" value="1" />
                </realitykit_environment_radiance>
                <output name="out" type="color3" nodename="env" output="specularRadiance" />
              </nodegraph>
              <realitykit_unlit_surfaceshader name="S" type="surfaceshader" nodedef="ND_realitykit_unlit_surfaceshader">
                <input name="color" type="color3" nodegraph="NG" output="out" />
              </realitykit_unlit_surfaceshader>
              <surfacematerial name="Q17_envrad" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: nil),
            Case(label: "Q18_bgblur", note: "realitykit_surface_background_blur_color3 → unlit", xml: doc("""
              \(MaterialXLibrary.unlitDef)
              \(MaterialXLibrary.backgroundBlurDef)
              <nodegraph name="NG">
                <realitykit_surface_background_blur_color3 name="blur" type="color3" nodedef="ND_realitykit_background_blur_color3" />
                <output name="out" type="color3" nodename="blur" />
              </nodegraph>
              <realitykit_unlit_surfaceshader name="S" type="surfaceshader" nodedef="ND_realitykit_unlit_surfaceshader">
                <input name="color" type="color3" nodegraph="NG" output="out" />
              </realitykit_unlit_surfaceshader>
              <surfacematerial name="Q18_bgblur" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: nil),
            floatProbe("Q19_hsv", """
              <texcoord name="uv" type="vector2" />
              <separate2 name="s" type="multioutput"><input name="in" type="vector2" nodename="uv" /></separate2>
              <combine3 name="hsv" type="color3"><input name="in1" type="float" nodename="s" output="outx" /><input name="in2" type="float" value="0.6" /><input name="in3" type="float" value="1" /></combine3>
              <hsvtorgb name="rgb" type="color3"><input name="in" type="color3" nodename="hsv" /></hsvtorgb>
              <extract name="probe_out" type="float"><input name="in" type="color3" nodename="rgb" /><input name="index" type="integer" value="0" /></extract>
            """, note: "separate2/combine3/hsvtorgb/extract"),
            // Can a nodegraph input be fed from a top-level node (and does that node's input become a parameter)?
            Case(label: "Q21_ng_input_from_constant", note: "nodegraph input connected to top-level constant", xml: doc("""
              \(MaterialXLibrary.unlitDef)
              <constant name="gainConst" type="float">
                <input name="value" type="float" value="0.5" />
              </constant>
              <nodegraph name="NG">
                <input name="gain" type="float" nodename="gainConst" />
                <multiply name="m" type="color3">
                  <input name="in1" type="color3" value="1, 0.5, 1" />
                  <input name="in2" type="float" interfacename="gain" />
                </multiply>
                <output name="color_out" type="color3" nodename="m" />
              </nodegraph>
              <realitykit_unlit_surfaceshader name="S" type="surfaceshader" nodedef="ND_realitykit_unlit_surfaceshader">
                <input name="color" type="color3" nodegraph="NG" output="color_out" />
              </realitykit_unlit_surfaceshader>
              <surfacematerial name="Q21_ng_input_from_constant" type="material">
                <input name="surfaceshader" type="surfaceshader" nodename="S" />
              </surfacematerial>
            """), set: ("value", .float(1))),
            // Setting a parameter whose shader input is connected to a graph: override, or no-op? (The tile stays grey
            // noise if it is a no-op and turns solid red if it overrides.)
            floatProbe("Q22_set_connected", """
              <position name="p" type="vector3"><input name="space" type="string" value="object" /></position>
              <multiply name="ps" type="vector3"><input name="in1" type="vector3" nodename="p" /><input name="in2" type="float" value="60" /></multiply>
              <noise3d name="probe_out" type="float"><input name="position" type="vector3" nodename="ps" /><input name="amplitude" type="float" value="0.5" /><input name="pivot" type="float" value="0.5" /></noise3d>
            """, note: "set color on a connected input", set: ("color", .color(UIColor.red.cgColor))),
            floatProbe("Q20_ifgreater_smooth", """
              <texcoord name="uv" type="vector2" />
              <extract name="u" type="float"><input name="in" type="vector2" nodename="uv" /><input name="index" type="integer" value="0" /></extract>
              <smoothstep name="sm" type="float"><input name="in" type="float" nodename="u" /><input name="low" type="float" value="0.3" /><input name="high" type="float" value="0.7" /></smoothstep>
              <ifgreater name="probe_out" type="float"><input name="value1" type="float" nodename="u" /><input name="value2" type="float" value="0.5" /><input name="in1" type="float" nodename="sm" /><input name="in2" type="float" value="0.1" /></ifgreater>
            """, note: "smoothstep + ifgreater"),
        ]
    }

    /// A USD layer with one material under /Root (Reality Composer Pro's layout).
    static func usda(_ material: String) -> String {
        """
        #usda 1.0
        (
            defaultPrim = "Root"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Root"
        {
        \(material)
        }
        """
    }

    static var usdCases: [Case] {
        [
            Case(label: "/Root/U01_interface", note: "USD Material inputs:tint + inputs:gain → multiply → unlit", xml: usda("""
                def Material "U01_interface"
                {
                    color3f inputs:tint = (0.2, 0.4, 1)
                    float inputs:gain = 1
                    token outputs:mtlx:surface.connect = </Root/U01_interface/Unlit.outputs:out>
                    token outputs:realitykit:vertex

                    def Shader "Mul"
                    {
                        uniform token info:id = "ND_multiply_color3FA"
                        color3f inputs:in1.connect = </Root/U01_interface.inputs:tint>
                        float inputs:in2.connect = </Root/U01_interface.inputs:gain>
                        color3f outputs:out
                    }

                    def Shader "Unlit"
                    {
                        uniform token info:id = "ND_realitykit_unlit_surfaceshader"
                        bool inputs:applyPostProcessToneMap = 0
                        color3f inputs:color.connect = </Root/U01_interface/Mul.outputs:out>
                        float inputs:opacity = 1
                        token outputs:out
                    }
                }
            """), set: ("tint", .color(UIColor.orange.cgColor))),
            Case(label: "/Root/U02_view", note: "USD: viewdirection·normal drives colour, gain parameter", xml: usda("""
                def Material "U02_view"
                {
                    float inputs:gain = 1
                    token outputs:mtlx:surface.connect = </Root/U02_view/Unlit.outputs:out>
                    token outputs:realitykit:vertex

                    def Shader "View"
                    {
                        uniform token info:id = "ND_realitykit_viewdirection_vector3"
                        uniform string inputs:space = "world"
                        float3 outputs:out
                    }

                    def Shader "Normal"
                    {
                        uniform token info:id = "ND_normal_vector3"
                        uniform string inputs:space = "world"
                        float3 outputs:out
                    }

                    def Shader "Dot"
                    {
                        uniform token info:id = "ND_dotproduct_vector3"
                        float3 inputs:in1.connect = </Root/U02_view/View.outputs:out>
                        float3 inputs:in2.connect = </Root/U02_view/Normal.outputs:out>
                        float outputs:out
                    }

                    def Shader "Gain"
                    {
                        uniform token info:id = "ND_multiply_float"
                        float inputs:in1.connect = </Root/U02_view/Dot.outputs:out>
                        float inputs:in2.connect = </Root/U02_view.inputs:gain>
                        float outputs:out
                    }

                    def Shader "ToColor"
                    {
                        uniform token info:id = "ND_convert_float_color3"
                        float inputs:in.connect = </Root/U02_view/Gain.outputs:out>
                        color3f outputs:out
                    }

                    def Shader "Unlit"
                    {
                        uniform token info:id = "ND_realitykit_unlit_surfaceshader"
                        bool inputs:applyPostProcessToneMap = 0
                        color3f inputs:color.connect = </Root/U02_view/ToColor.outputs:out>
                        token outputs:out
                    }
                }
            """), set: ("gain", .float(0.5))),
        ]
    }
}
