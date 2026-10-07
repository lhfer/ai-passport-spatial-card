import Foundation
import simd

extension V4 {
    /// **A1 · a RealityKit ShaderGraph material, written in code, emitted as USD text.**
    ///
    /// Why USD and not MaterialX, although the SDK has `ShaderGraphMaterial(materialXLabel:data:)`: a MaterialX document
    /// goes through CoreRealityIO's `UsdMtlxRead` first, and that reader only turns the **top-level surface shader's
    /// own inputs** into material parameters (`parameterNames` of a nodegraph-driven material is `["color"]`, and setting
    /// it is a silent no-op because the input is connected). A nodegraph's interface inputs never become parameters —
    /// see `MaterialXProbe` Q03 / Q04 / Q21 / Q22. The USD layout Reality Composer Pro saves has no such limit: every
    /// `inputs:*` on the `Material` prim is a parameter and any node may connect to it, so `sweep`, `progress` and the
    /// rest are settable per frame with `setParameter(name:value:)`.
    ///
    /// Writing that USD by hand means spelling out every connection path and type twice; this builder does it once,
    /// from typed ports, and resolves the MaterialX nodedef ids (`ND_multiply_color3FA`, …) from the operand types. It
    /// is simd + Foundation only so the unit tests can check every graph (no dangling connection, the parameter list the
    /// wrappers expect) without a renderer.
    struct ShadeGraph {
        /// MaterialX value types, with their USD spelling.
        enum Kind: String, CaseIterable {
            case float, color3, color4, vector2, vector3, vector4, half, boolean, integer, string, surfaceshader

            var usdType: String {
                switch self {
                case .float: return "float"
                case .color3: return "color3f"
                case .color4: return "color4f"
                case .vector2: return "float2"
                case .vector3: return "float3"
                case .vector4: return "float4"
                case .half: return "half"
                case .boolean: return "bool"
                case .integer: return "int"
                case .string: return "string"
                case .surfaceshader: return "token"
                }
            }

            /// The suffix MaterialX nodedef names use for this type (`ND_add_<suffix>`).
            var nodedefSuffix: String { rawValue }

            /// Types with more than one float channel (the ones `…FA` nodedefs pair with a float).
            var isVector: Bool { [.color3, .color4, .vector2, .vector3, .vector4].contains(self) }
        }

        /// A constant.
        enum Value: Equatable {
            case float(Float)
            case color3(SIMD3<Float>)
            case vector2(SIMD2<Float>)
            case vector3(SIMD3<Float>)
            case vector4(SIMD4<Float>)
            case half(Float)
            case boolean(Bool)
            case integer(Int)
            case string(String)

            var kind: Kind {
                switch self {
                case .float: return .float
                case .color3: return .color3
                case .vector2: return .vector2
                case .vector3: return .vector3
                case .vector4: return .vector4
                case .half: return .half
                case .boolean: return .boolean
                case .integer: return .integer
                case .string: return .string
                }
            }

            /// USD literal, locale-independent (`String(format:)` without a locale is POSIX).
            var usdLiteral: String {
                switch self {
                case .float(let v), .half(let v): return Self.number(v)
                case .color3(let v), .vector3(let v): return "(\(Self.number(v.x)), \(Self.number(v.y)), \(Self.number(v.z)))"
                case .vector2(let v): return "(\(Self.number(v.x)), \(Self.number(v.y)))"
                case .vector4(let v):
                    return "(\(Self.number(v.x)), \(Self.number(v.y)), \(Self.number(v.z)), \(Self.number(v.w)))"
                case .boolean(let b): return b ? "1" : "0"
                case .integer(let i): return String(i)
                case .string(let s): return "\"\(s)\""
                }
            }

            static func number(_ v: Float) -> String {
                guard v.isFinite else { return "0" }
                return String(format: "%.6g", Double(v))
            }

            /// An sRGB `#RRGGBB` colour as the linear triple ShaderGraph colour constants are written in.
            static func srgb(_ hex: String) -> Value { .color3(V4.ShadeGraph.linear(hex: hex)) }
        }

        /// Something that produces a value in the graph: a node output or a material parameter.
        struct Port: Equatable {
            /// `</Root/Mat/Node.outputs:out>` or `</Root/Mat.inputs:name>`.
            let target: String
            let kind: Kind
        }

        /// What feeds an input.
        enum Source: Equatable {
            case port(Port)
            case value(Value)

            var kind: Kind {
                switch self {
                case .port(let p): return p.kind
                case .value(let v): return v.kind
                }
            }
        }

        struct Input: Equatable {
            var name: String
            var source: Source
            /// `uniform` in USD: the `space` strings, `index`, the surface's compile-time booleans.
            var uniform: Bool
        }

        struct Node: Equatable {
            var name: String
            var nodedef: String
            var inputs: [Input]
            var outputs: [(name: String, kind: Kind)]

            static func == (a: Node, b: Node) -> Bool {
                a.name == b.name && a.nodedef == b.nodedef && a.inputs == b.inputs
                    && a.outputs.map(\.name) == b.outputs.map(\.name) && a.outputs.map(\.kind) == b.outputs.map(\.kind)
            }
        }

        /// The material prim's name; the material lives at `/Root/<name>`.
        let name: String
        private(set) var parameters: [(name: String, value: Value)] = []
        private(set) var nodes: [Node] = []
        private(set) var surface: Port?
        private var counter = 0

        init(name: String) {
            self.name = name
        }

        var materialPath: String { "/Root/\(name)" }

        // MARK: - Building

        /// A material parameter: an `inputs:<name>` on the Material prim, settable at run time.
        @discardableResult
        mutating func parameter(_ name: String, _ value: Value) -> Port {
            precondition(!parameters.contains { $0.name == name }, "duplicate parameter \(name)")
            parameters.append((name, value))
            return Port(target: "<\(materialPath).inputs:\(name)>", kind: value.kind)
        }

        /// A node with several outputs; returns them by name.
        mutating func node(_ nodedef: String, name: String? = nil, inputs: [(String, Source)] = [],
                           uniforms: [(String, Value)] = [], outputs: [(String, Kind)]) -> [String: Port] {
            counter += 1
            let nodeName = name ?? "n\(counter)_" + Self.shortName(nodedef)
            precondition(!nodes.contains { $0.name == nodeName }, "duplicate node \(nodeName)")
            var all = inputs.map { Input(name: $0.0, source: $0.1, uniform: false) }
            all += uniforms.map { Input(name: $0.0, source: .value($0.1), uniform: true) }
            nodes.append(Node(name: nodeName, nodedef: nodedef, inputs: all, outputs: outputs.map { (name: $0.0, kind: $0.1) }))
            var ports: [String: Port] = [:]
            for (outName, kind) in outputs {
                ports[outName] = Port(target: "<\(materialPath)/\(nodeName).outputs:\(outName)>", kind: kind)
            }
            return ports
        }

        /// A node with the single output `out`.
        mutating func node(_ nodedef: String, name: String? = nil, inputs: [(String, Source)] = [],
                           uniforms: [(String, Value)] = [], out kind: Kind) -> Port {
            node(nodedef, name: name, inputs: inputs, uniforms: uniforms, outputs: [("out", kind)])["out"]!
        }

        /// Which surface shader the material renders with.
        mutating func setSurface(_ port: Port) {
            precondition(port.kind == .surfaceshader, "surface must be a surfaceshader port")
            surface = port
        }

        // MARK: - Output

        /// The whole layer: `/Root` (an Xform) holding the one Material. Load it with
        /// `ShaderGraphMaterial(named: graph.materialPath, from: Data(graph.usda().utf8))`.
        func usda() -> String {
            var lines: [String] = []
            lines.append("#usda 1.0")
            lines.append("(")
            lines.append("    defaultPrim = \"Root\"")
            lines.append("    metersPerUnit = 1")
            lines.append("    upAxis = \"Y\"")
            lines.append(")")
            lines.append("")
            lines.append("def Xform \"Root\"")
            lines.append("{")
            lines.append("    def Material \"\(name)\"")
            lines.append("    {")
            for (paramName, value) in parameters {
                lines.append("        \(value.kind.usdType) inputs:\(paramName) = \(value.usdLiteral)")
            }
            if let surface {
                lines.append("        token outputs:mtlx:surface.connect = \(surface.target)")
            }
            lines.append("        token outputs:realitykit:vertex")
            for node in nodes {
                lines.append("")
                lines.append("        def Shader \"\(node.name)\"")
                lines.append("        {")
                lines.append("            uniform token info:id = \"\(node.nodedef)\"")
                for input in node.inputs {
                    let uniform = input.uniform ? "uniform " : ""
                    switch input.source {
                    case .port(let port):
                        lines.append("            \(uniform)\(port.kind.usdType) inputs:\(input.name).connect = \(port.target)")
                    case .value(let value):
                        lines.append("            \(uniform)\(value.kind.usdType) inputs:\(input.name) = \(value.usdLiteral)")
                    }
                }
                for output in node.outputs {
                    lines.append("            \(output.kind.usdType) outputs:\(output.name)")
                }
                lines.append("        }")
            }
            lines.append("    }")
            lines.append("}")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        /// Structural problems the importer would only report as `internalImportError`: a connection to a port that
        /// does not exist, a missing surface, a parameter nothing reads.
        func problems() -> [String] {
            var issues: [String] = []
            var known = Set(parameters.map { "<\(materialPath).inputs:\($0.name)>" })
            for node in nodes {
                for output in node.outputs { known.insert("<\(materialPath)/\(node.name).outputs:\(output.name)>") }
            }
            var used = Set<String>()
            for node in nodes {
                for input in node.inputs {
                    if case .port(let port) = input.source {
                        used.insert(port.target)
                        if !known.contains(port.target) { issues.append("\(node.name).\(input.name) → missing \(port.target)") }
                    }
                }
            }
            if let surface {
                used.insert(surface.target)
                if !known.contains(surface.target) { issues.append("surface → missing \(surface.target)") }
            } else {
                issues.append("no surface")
            }
            for (paramName, _) in parameters where !used.contains("<\(materialPath).inputs:\(paramName)>") {
                issues.append("parameter \(paramName) is never read")
            }
            return issues
        }

        var parameterNames: [String] { parameters.map(\.name) }

        // MARK: - Helpers

        static func shortName(_ nodedef: String) -> String {
            var s = nodedef
            if s.hasPrefix("ND_realitykit_") { s.removeFirst("ND_realitykit_".count) } else if s.hasPrefix("ND_") { s.removeFirst(3) }
            return String(s.prefix(24))
        }

        /// sRGB hex → linear RGB (the IEC 61966-2-1 curve, not a 2.2 gamma).
        static func linear(hex: String) -> SIMD3<Float> {
            var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("#") { s.removeFirst() }
            let value = UInt32(s, radix: 16) ?? 0
            let c = SIMD3<Float>(Float((value >> 16) & 0xFF), Float((value >> 8) & 0xFF), Float(value & 0xFF)) / 255
            return SIMD3(linear(c.x), linear(c.y), linear(c.z))
        }

        static func linear(_ c: Float) -> Float {
            // (Qualified: the builder's own `pow` node helper shadows the libm one inside this type.)
            c <= 0.04045 ? c / 12.92 : Float(Foundation.pow(Double((c + 0.055) / 1.055), 2.4))
        }

        /// The nodedef of a two-input arithmetic node for these operand types: `ND_multiply_float`,
        /// `ND_multiply_color3` (same type) or `ND_multiply_color3FA` (vector × float). Nil when MaterialX has none
        /// (float × vector — the caller swaps or converts).
        static func binaryNodedef(_ op: String, _ a: Kind, _ b: Kind) -> String? {
            if a == b, a == .float || a.isVector { return "ND_\(op)_\(a.nodedefSuffix)" }
            if a.isVector, b == .float { return "ND_\(op)_\(a.nodedefSuffix)FA" }
            return nil
        }
    }
}

// MARK: - Math and geometry nodes

extension V4.ShadeGraph {
    typealias Src = Source

    static func f(_ v: Float) -> Source { .value(.float(v)) }

    /// `a + b`, `a - b`, `a * b`, `a / b`, `min`, `max`, `pow` with MaterialX's overload rules. A float on the left of a
    /// vector is commuted when the operation allows it and converted otherwise.
    mutating func binary(_ op: String, _ a: Source, _ b: Source) -> Port {
        let commutes = ["add", "multiply", "min", "max"].contains(op)
        if let def = Self.binaryNodedef(op, a.kind, b.kind) {
            return node(def, inputs: [("in1", a), ("in2", b)], out: a.kind == .float ? b.kind : a.kind)
        }
        if a.kind == .float, b.kind.isVector {
            if commutes, let def = Self.binaryNodedef(op, b.kind, .float) {
                return node(def, inputs: [("in1", b), ("in2", a)], out: b.kind)
            }
            let widened = convert(a, to: b.kind)
            return node("ND_\(op)_\(b.kind.nodedefSuffix)", inputs: [("in1", .port(widened)), ("in2", b)], out: b.kind)
        }
        preconditionFailure("no \(op) for \(a.kind) and \(b.kind)")
    }

    mutating func add(_ a: Source, _ b: Source) -> Port { binary("add", a, b) }
    mutating func sub(_ a: Source, _ b: Source) -> Port { binary("subtract", a, b) }
    mutating func mul(_ a: Source, _ b: Source) -> Port { binary("multiply", a, b) }
    mutating func div(_ a: Source, _ b: Source) -> Port { binary("divide", a, b) }
    mutating func min(_ a: Source, _ b: Source) -> Port { binary("min", a, b) }
    mutating func max(_ a: Source, _ b: Source) -> Port { binary("max", a, b) }
    mutating func pow(_ a: Source, _ b: Source) -> Port { binary("power", a, b) }

    /// `1 - x` for a float.
    mutating func oneMinus(_ x: Source) -> Port { sub(Self.f(1), x) }

    /// MaterialX `mix`: `bg·(1 − t) + fg·t` — written here as "from `a` to `b` by `t`".
    mutating func mix(_ a: Source, _ b: Source, _ t: Source) -> Port {
        precondition(a.kind == b.kind, "mix operands differ: \(a.kind) / \(b.kind)")
        return node("ND_mix_\(a.kind.nodedefSuffix)", inputs: [("fg", b), ("bg", a), ("mix", t)], out: a.kind)
    }

    mutating func clamp(_ x: Source, _ low: Float = 0, _ high: Float = 1) -> Port {
        let def = x.kind == .float ? "ND_clamp_float" : "ND_clamp_\(x.kind.nodedefSuffix)FA"
        return node(def, inputs: [("in", x), ("low", Self.f(low)), ("high", Self.f(high))], out: x.kind)
    }

    /// Hermite step of a float `x` between `low` and `high` (0 below, 1 above).
    mutating func smoothstep(_ low: Source, _ high: Source, _ x: Source) -> Port {
        node("ND_smoothstep_float", inputs: [("in", x), ("low", low), ("high", high)], out: .float)
    }

    mutating func abs(_ x: Source) -> Port { node("ND_absval_\(x.kind.nodedefSuffix)", inputs: [("in", x)], out: x.kind) }
    mutating func sin(_ x: Source) -> Port { node("ND_sin_float", inputs: [("in", x)], out: .float) }
    mutating func floor(_ x: Source) -> Port { node("ND_floor_float", inputs: [("in", x)], out: .float) }
    /// `x − floor(x)` (MaterialX `modulo` is GLSL `mod`, so negative inputs wrap into [0, 1) too).
    mutating func fract(_ x: Source) -> Port { node("ND_modulo_float", inputs: [("in1", x), ("in2", Self.f(1))], out: .float) }

    mutating func dot(_ a: Source, _ b: Source) -> Port {
        node("ND_dotproduct_\(a.kind.nodedefSuffix)", inputs: [("in1", a), ("in2", b)], out: .float)
    }

    mutating func normalize(_ v: Source) -> Port { node("ND_normalize_\(v.kind.nodedefSuffix)", inputs: [("in", v)], out: v.kind) }
    mutating func length(_ v: Source) -> Port { node("ND_magnitude_\(v.kind.nodedefSuffix)", inputs: [("in", v)], out: .float) }

    mutating func convert(_ x: Source, to kind: Kind) -> Port {
        node("ND_convert_\(x.kind.nodedefSuffix)_\(kind.nodedefSuffix)", inputs: [("in", x)], out: kind)
    }

    /// One channel of a vector (`index` is a uniform in MaterialX).
    mutating func extract(_ v: Source, _ index: Int) -> Port {
        node("ND_extract_\(v.kind.nodedefSuffix)", inputs: [("in", v)], uniforms: [("index", .integer(index))], out: .float)
    }

    mutating func combine2(_ x: Source, _ y: Source) -> Port {
        node("ND_combine2_vector2", inputs: [("in1", x), ("in2", y)], out: .vector2)
    }

    mutating func combine3(_ x: Source, _ y: Source, _ z: Source, as kind: Kind = .vector3) -> Port {
        node("ND_combine3_\(kind.nodedefSuffix)", inputs: [("in1", x), ("in2", y), ("in3", z)], out: kind)
    }

    // Geometry

    mutating func position(space: String = "object") -> Port {
        node("ND_position_vector3", uniforms: [("space", .string(space))], out: .vector3)
    }

    mutating func normal(space: String = "world") -> Port {
        node("ND_normal_vector3", uniforms: [("space", .string(space))], out: .vector3)
    }

    /// RealityKit's per-eye view direction (unit length; which way it points is logged by the probe).
    mutating func viewDirection(space: String = "world") -> Port {
        node("ND_realitykit_viewdirection_vector3", uniforms: [("space", .string(space))], out: .vector3)
    }

    mutating func texcoord() -> Port {
        node("ND_texcoord_vector2", uniforms: [("index", .integer(0))], out: .vector2)
    }

    mutating func time() -> Port { node("ND_time_float", out: .float) }

    mutating func transformVector(_ v: Source, from: String, to: String) -> Port {
        node("ND_transformvector_vector3", inputs: [("in", v)],
             uniforms: [("fromspace", .string(from)), ("tospace", .string(to))], out: .vector3)
    }

    /// 3D Perlin noise in [pivot − amplitude, pivot + amplitude] (roughly).
    mutating func noise3d(_ position: Source, amplitude: Float = 0.5, pivot: Float = 0.5) -> Port {
        node("ND_noise3d_float", inputs: [("position", position), ("amplitude", Self.f(amplitude)), ("pivot", Self.f(pivot))],
             out: .float)
    }

    mutating func fractal3d(_ position: Source, octaves: Int = 3, amplitude: Float = 1, lacunarity: Float = 2,
                            diminish: Float = 0.5) -> Port {
        node("ND_fractal3d_float", inputs: [("position", position), ("amplitude", Self.f(amplitude)),
                                            ("octaves", .value(.integer(octaves))), ("lacunarity", Self.f(lacunarity)),
                                            ("diminish", Self.f(diminish))], out: .float)
    }

    /// What is behind the surface, blurred (RealityKit's frosted-glass sample). Renders in the simulator (probe Q18:
    /// the room / night dome behind, softened); whether it reaches passthrough on the headset is unverified.
    mutating func backgroundBlur() -> Port {
        node("ND_realitykit_background_blur_color3", out: .color3)
    }

    /// The scene's image-based light for a normal (diffuse + specular).
    mutating func environmentRadiance(normal: Source, roughness: Float, specular: Float = 1, metallic: Float = 0,
                                      baseColor: SIMD3<Float> = [1, 1, 1]) -> (diffuse: Port, specular: Port) {
        let ports = node("ND_realitykit_environment_radiance",
                         inputs: [("normal", normal), ("roughness", .value(.half(roughness))),
                                  ("specular", .value(.half(specular))), ("metallic", .value(.half(metallic))),
                                  ("baseColor", .value(.color3(baseColor)))],
                         outputs: [("diffuseRadiance", .color3), ("specularRadiance", .color3)])
        return (ports["diffuseRadiance"]!, ports["specularRadiance"]!)
    }

    // Surfaces

    /// RealityKit's unlit surface. `premultiplied`: the colour is already multiplied by the opacity, so a zero opacity
    /// with a non-zero colour is pure additive light — the one blend that lets a body and a glow share a material.
    mutating func unlitSurface(color: Source, opacity: Source, premultiplied: Bool, toneMapped: Bool = false,
                               name: String = "Surface") -> Port {
        node("ND_realitykit_unlit_surfaceshader", name: name, inputs: [("color", color), ("opacity", opacity)],
             uniforms: [("applyPostProcessToneMap", .boolean(toneMapped)), ("hasPremultipliedAlpha", .boolean(premultiplied))],
             out: .surfaceshader)
    }

    /// RealityKit's PBR surface (the subset the library uses).
    mutating func pbrSurface(baseColor: Source, emissive: Source, roughness: Source, metallic: Source = V4.ShadeGraph.f(0),
                             specular: Source = V4.ShadeGraph.f(0.5), opacity: Source, clearcoat: Source = V4.ShadeGraph.f(0),
                             clearcoatRoughness: Source = V4.ShadeGraph.f(0.05), premultiplied: Bool,
                             name: String = "Surface") -> Port {
        node("ND_realitykit_pbr_surfaceshader", name: name,
             inputs: [("baseColor", baseColor), ("emissiveColor", emissive), ("roughness", roughness), ("metallic", metallic),
                      ("specular", specular), ("opacity", opacity), ("clearcoat", clearcoat),
                      ("clearcoatRoughness", clearcoatRoughness)],
             uniforms: [("hasPremultipliedAlpha", .boolean(premultiplied))], out: .surfaceshader)
    }
}

extension V4.ShadeGraph.Port {
    /// This output as an input source.
    var s: V4.ShadeGraph.Source { .port(self) }
}
