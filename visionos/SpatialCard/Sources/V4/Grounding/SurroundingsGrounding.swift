import RealityKit
import UIKit

/// Virtual things that answer the real room (A3 目标 1.2 and the light-spill half of 1.3).
///
/// - **Occlusion** — `EnvironmentBlendingComponent(preferredBlendingMode: .occluded(by: .surroundings))` (visionOS 26)
///   lets real furniture hide virtual content behind it. Its documentation carries the two costs this lab measures:
///   an occluded entity "always renders behind other virtual contents that don't have occlusion enabled", and it
///   "doesn't receive input events from the user if it's behind a real-world object". Whether it reaches
///   descendants is not documented, so `setOcclusion` can set it on one entity or on every entity of a subtree.
/// - **Light spill** — `PointLightComponent.SurroundingsLight` / `SpotLightComponent.SurroundingsLight` (visionOS 27):
///   "the spot light illuminates the physical and immersive environment". Added next to a light on the same entity,
///   it is the only public way to let a virtual glow light a *real* desk.
/// - **Device occluder** — an `OcclusionMaterial` box the size of the tracked device. The environment depth that
///   drives `EnvironmentBlendingComponent` is far too coarse for an 8.5 mm object; a box at the object-tracked pose
///   hides exactly what the real AI Passport hides (the pool under it, dust falling behind it), so the hardware
///   always reads as *in front* — H0 by construction.
@MainActor
enum SurroundingsGrounding {
    // MARK: Occlusion

    static func setOcclusion(_ occluded: Bool, on root: Entity, recursive: Bool) {
        let component = EnvironmentBlendingComponent(preferredBlendingMode: occluded ? .occluded(by: .surroundings) : .default)
        func visit(_ entity: Entity) {
            entity.components.set(component)
            guard recursive else { return }
            for child in entity.children { visit(child) }
        }
        visit(root)
    }

    static func isOccluded(_ entity: Entity) -> Bool {
        entity.components[EnvironmentBlendingComponent.self]?.preferredBlendingMode == .occluded(by: .surroundings)
    }

    // MARK: Light spill

    /// A warm point light that, with `surroundings`, is also asked to light the real room.
    static func makePointSpill(color: UIColor, intensity: Float, radius: Float, surroundings: Bool) -> Entity {
        let light = Entity()
        light.name = "grounding.spill.point"
        var point = PointLightComponent(cgColor: color.cgColor, intensity: intensity, attenuationRadius: radius)
        point.attenuationFalloffExponent = 2
        light.components.set(point)
        if surroundings { light.components.set(PointLightComponent.SurroundingsLight()) }
        return light
    }

    /// A warm spot light pointing down its local −Z; with `surroundings` it is asked to light the real room too.
    static func makeSpotSpill(color: UIColor, intensity: Float, innerAngle: Float, outerAngle: Float,
                              range: Float, surroundings: Bool) -> Entity {
        let light = Entity()
        light.name = "grounding.spill.spot"
        light.components.set(SpotLightComponent(color: color, intensity: intensity, innerAngleInDegrees: innerAngle,
                                                outerAngleInDegrees: outerAngle, attenuationRadius: range))
        if surroundings { light.components.set(SpotLightComponent.SurroundingsLight()) }
        return light
    }

    // MARK: Device occluder

    /// A box the size of the device (x width, y thickness, z length) that shows the real world through anything
    /// virtual behind it. `inset` shrinks it so a virtual stand-in drawn at the same place still wins the depth test.
    static func makeDeviceOccluder(size: SIMD3<Float>, inset: Float = 0.0003) -> ModelEntity {
        let s = simd_max(size - SIMD3<Float>(repeating: 2 * inset), SIMD3<Float>(repeating: 0.001))
        let box = ModelEntity(mesh: .generateBox(width: s.x, height: s.y, depth: s.z, cornerRadius: min(0.004, s.y / 2)),
                              materials: [OcclusionMaterial()])
        box.name = "grounding.deviceOccluder"
        box.position = [0, -size.y / 2, 0]
        return box
    }
}
