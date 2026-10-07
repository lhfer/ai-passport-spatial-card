import Foundation
import Observation
import RealityKit
import SwiftUI
import UIKit

/// Dev-only probes for the four visionOS 27 platform assumptions the FX design depends on
/// (design doc §6 P0). A white "实验" orb on the desk cycles them; each experiment shows an
/// instruction / result label floating in front of the wearer and prints `[p0]` lines.
///
/// 1. Bloom: identical emissive spheres, only the left one carries `BloomComponent`.
/// 2. `preferredSurroundingsEffect(.colorMultiply)` animated per frame — is it smooth?
/// 4. `ClippingComponent` sweeping over a RealityKit quad and a SwiftUI attachment — is the attachment clipped?
///
/// P0-3 (image tracking under `.full`) was removed after its result was recorded — see `isEnabled`.
@MainActor
@Observable
final class P0Probes {
    enum Experiment: Int, CaseIterable {
        case off, bloom, colorMultiply, clipping

        var title: String {
            switch self {
            case .off: return "实验关闭"
            case .bloom: return "P0-1 泛光"
            case .colorMultiply: return "P0-2 透视调色"
            case .clipping: return "P0-4 裁切 vs SwiftUI"
            }
        }
    }

    /// Off in normal builds; launch with `--p0` to get the probe orb back.
    /// P0-3 result recorded 2026-09-15 on visionOS 27.0 (24M362): mixed 6 s = 35 image-anchor
    /// updates, .full 8 s = 0 → image tracking stops entirely under full immersion. Worlds run in
    /// .mixed behind an occluding shell and the gate holds the last pose (`held(.world)`) under .full;
    /// the experiment itself is gone so nothing but the world engine ever asks for `.full`.
    static let isEnabled = CommandLine.arguments.contains("--p0")
    static let orbName = "p0.orb"
    static let labelAttachmentID = "p0-label"
    static let swiftUIAttachmentID = "p0-swiftui"

    private(set) var current: Experiment = .off
    private(set) var label = ""
    /// Whole-passthrough tint requested by experiment 2.
    private(set) var surroundingsTint: Color?
    /// Results, keyed by experiment, for the report.
    private(set) var results: [String] = []

    let rig = Entity()
    private let labelHolder = Entity()
    private let swiftUIHolder = Entity()
    private var task: Task<Void, Never>?

    init() {
        rig.isEnabled = false
        labelHolder.components.set(BillboardComponent())
        labelHolder.position = [0, 0.16, 0]
        rig.addChild(labelHolder)
    }

    func attachLabel(_ entity: Entity) { labelHolder.addChild(entity) }
    func attachSwiftUI(_ entity: Entity) { swiftUIHolder.addChild(entity) }

    /// Tap on the probe orb: stop the current experiment and start the next one.
    func advance(devicePose: simd_float4x4?) {
        stop()
        let next = Experiment(rawValue: (current.rawValue + 1) % Experiment.allCases.count) ?? .off
        current = next
        guard next != .off else {
            rig.isEnabled = false
            label = ""
            return
        }
        place(devicePose: devicePose)
        rig.isEnabled = true
        switch next {
        case .off: break
        case .bloom: runBloom()
        case .colorMultiply: runColorMultiply()
        case .clipping: runClipping()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        surroundingsTint = nil
        for child in rig.children where child !== labelHolder {
            child.removeFromParent()
        }
        swiftUIHolder.removeFromParent()
    }

    // MARK: - Placement

    /// ~0.8 m ahead of the head, a little below eye level, turned toward the wearer (yaw only).
    private func place(devicePose: simd_float4x4?) {
        guard let d = devicePose else {
            rig.position = [0, 1.1, -0.8]
            return
        }
        let eye = SIMD3<Float>(d.columns.3.x, d.columns.3.y, d.columns.3.z)
        var forward = -SIMD3<Float>(d.columns.2.x, d.columns.2.y, d.columns.2.z)
        forward.y = 0
        if simd_length(forward) < 0.01 { forward = [0, 0, -1] }
        forward = simd_normalize(forward)
        rig.position = eye + forward * 0.8 + SIMD3<Float>(0, -0.12, 0)
        rig.orientation = simd_quatf(angle: atan2(-forward.x, -forward.z), axis: [0, 1, 0])
    }

    // MARK: - Experiments

    private func emissiveSphere(radius: Float, color: UIColor, intensity: Float) -> ModelEntity {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color, texture: nil)
        material.emissiveColor = .init(color: color, texture: nil)
        material.emissiveIntensity = intensity
        material.roughness = .init(floatLiteral: 0.4)
        return ModelEntity(mesh: .generateSphere(radius: radius), materials: [material])
    }

    private func runBloom() {
        let color = UIColor(red: 0.75, green: 0.95, blue: 1.0, alpha: 1)
        let bloomed = emissiveSphere(radius: 0.025, color: color, intensity: 6)
        bloomed.position = [-0.12, 0, 0]
        bloomed.components.set(BloomComponent(scope: .hierarchical))
        var options = BloomOptionsComponent()
        options.strength = 0.9
        options.threshold = 0.9
        options.blurRadius = 2
        bloomed.components.set(options)
        let plain = emissiveSphere(radius: 0.025, color: color, intensity: 6)
        plain.position = [0.12, 0, 0]
        rig.addChild(bloomed)
        rig.addChild(plain)
        label = "P0-1 泛光：两球材质完全一样，只有左球挂了 BloomComponent(hierarchical)。左球周围有柔和的光溢出吗？（再捏一下实验球进入下一项）"
        print("[p0] bloom spheres placed (left = bloom, right = plain)")
    }

    private func runColorMultiply() {
        label = "P0-2 透视调色：透视会在 6 s 内从白 → 深绿 → 白。过渡是否平滑（有没有一格一格跳、色带、闪烁）？"
        task = Task { @MainActor [weak self] in
            let start = Date()
            var frames = 0
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)
                if t > 6 { break }
                // Triangle 0→1→0 over 6 s, white → #0D3A14 → white.
                let k = t < 3 ? t / 3 : (6 - t) / 3
                let r = 1 - (1 - 0.05) * k, g = 1 - (1 - 0.23) * k, b = 1 - (1 - 0.08) * k
                self?.surroundingsTint = Color(red: r, green: g, blue: b)
                frames += 1
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.surroundingsTint = nil
            print("[p0] colorMultiply ramp done, \(frames) updates in 6 s")
            self?.label = "P0-2 结束：6 s 内推送了 \(frames) 次颜色。请告诉我过渡是否平滑。"
        }
    }

    private func runClipping() {
        // A red quad and a SwiftUI label side by side, both children of one clipped entity.
        let clipped = Entity()
        var clipping = ClippingComponent(bounds: BoundingBox(min: [-0.16, -0.06, -0.05], max: [0.16, 0.06, 0.05]))
        clipping.featheredEdge = .init(symmetricEdgeInset: [0.01, 0, 0], falloff: .cubic)
        clipping.shouldClipChildren = true
        clipping.shouldClipSelf = false
        clipped.components.set(clipping)
        var material = UnlitMaterial(color: UIColor(red: 1, green: 0.3, blue: 0.3, alpha: 1))
        material.blending = .opaque
        let quad = ModelEntity(mesh: .generatePlane(width: 0.1, height: 0.08), materials: [material])
        quad.position = [-0.07, 0, 0]
        clipped.addChild(quad)
        swiftUIHolder.position = [0.07, 0, 0]
        clipped.addChild(swiftUIHolder)
        rig.addChild(clipped)
        label = "P0-4 裁切：一个裁切框从右往左反复扫过红方块和「SwiftUI」文字。红块被切掉时，文字也被切掉了吗？边缘有羽化吗？"
        task = Task { @MainActor in
            let start = Date()
            while !Task.isCancelled {
                let t = Float(Date().timeIntervalSince(start))
                // Right edge sweeps from +0.16 to -0.16 and back every 4 s.
                let phase = (sin(t * .pi / 2) + 1) / 2
                var c = clipped.components[ClippingComponent.self] ?? clipping
                c.bounds = BoundingBox(min: [-0.16, -0.06, -0.05], max: [-0.16 + 0.32 * phase, 0.06, 0.05])
                clipped.components.set(c)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }
}

/// Instruction / result text for the probe, shown on the rig's label holder.
struct P0Label: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 420)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The SwiftUI half of the clipping experiment.
struct P0SwiftUISample: View {
    var body: some View {
        Text("SwiftUI")
            .font(.system(size: 28, weight: .bold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
