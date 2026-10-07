import Foundation
import RealityKit
import UIKit

/// **The screen's star burst** (v4 A2): a 2D starlight burst *on the device's own screen*, the stand-in for
/// the firmware animation the real LCD will play (the headset only watches it happen).
///
/// A flat layer exactly the LCD's size, 0.3 mm above the proxy screen, drawn additively with the eight-frame
/// flip-book `MagicTextures.screenBurst` (flash → rays shooting out → flung stars, 0.15 s). It never leaves
/// the screen rectangle — the pixels live on the LCD — and it is gone 0.1 s after its last frame, so it is
/// no resident object inside the device outline (art bible: nothing resident over the real screen).
@MainActor
final class ScreenBurst {
    let entity: ModelEntity
    private var material: UnlitMaterial
    private var frame = -1
    private var clock: Float = 0
    private var running = false
    /// Frames play across `duration`; the last one then fades out across `afterglow`.
    var duration: Float = 0.15
    var afterglow: Float = 0.10

    private init(entity: ModelEntity, material: UnlitMaterial) {
        self.entity = entity
        self.material = material
    }

    /// `size` = the lit area (m); `lift` = height above the device's top face (S's origin).
    static func make(size: SIMD2<Float>, lift: Float) async -> ScreenBurst {
        let material = await MagicMaterials.additive(MagicTextures.shared.screenBurst)
        let entity = ModelEntity(mesh: .generatePlane(width: size.x, depth: size.y), materials: [material])
        entity.name = "v4.screenBurst"
        entity.position = [0, lift, 0]
        entity.isEnabled = false
        return ScreenBurst(entity: entity, material: material)
    }

    var isRunning: Bool { running }

    func play() {
        clock = 0
        running = true
        frame = -1
        entity.components.set(OpacityComponent(opacity: 1))
        entity.isEnabled = true
        show(0)
    }

    /// Put the burst at `time` seconds into its run (the rig's shared clock).
    func set(time: Float) {
        clock = time
        guard running else { return }
        if time >= duration + afterglow {
            running = false
            entity.isEnabled = false
            return
        }
        let frames = MagicTextures.screenBurstFrames
        let index = min(frames - 1, Int(time / duration * Float(frames)))
        show(index)
        let fade = time > duration ? 1 - (time - duration) / afterglow : 1
        entity.components.set(OpacityComponent(opacity: max(0, fade)))
    }

    func stop() {
        running = false
        entity.isEnabled = false
    }

    /// Select one cell of the 8 × 1 flip-book (only when it changes: it is a material write).
    private func show(_ index: Int) {
        guard index != frame else { return }
        frame = index
        let frames = Float(MagicTextures.screenBurstFrames)
        material.textureCoordinateTransform = .init(offset: [Float(index) / frames, 0], scale: [1 / frames, 1], rotation: 0)
        entity.model?.materials = [material]
    }
}
