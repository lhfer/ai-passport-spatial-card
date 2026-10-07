import Foundation
import RealityKit
import UIKit

/// **The key-beat glint** (v4 A2; art bible §4 闪光星): a four-point star, 6–12 mm, 0.25–0.4 s, at most six
/// on screen — only on the beats that deserve one (a landing, the end of the recognition, the gold card).
///
/// A fixed pool of six: a seventh flash takes the oldest slot, so "≤ 6 on screen" holds by construction. Each
/// flash snaps open (≈ 22 % of its life, with a hint of overshoot), turns a few degrees and closes to nothing
/// — the "ding" is the shape of that envelope. Each slot is a billboarded holder (RealityKit owns its
/// rotation) with the star quad inside it, turned about its own normal. Driven by `update(dt:)`.
@MainActor
final class StarGlint {
    static let maxOnScreen = 6
    static let sizeRange: ClosedRange<Float> = 0.006...0.012
    static let durationRange: ClosedRange<Float> = 0.25...0.40

    let root = Entity()
    private var slots: [Slot] = []
    private var clock: Float = 0
    private var paused = false

    private struct Slot {
        let holder: Entity
        let quad: ModelEntity
        var start: Float = -1
        var duration: Float = 0.32
        var size: Float = 0.010
        var spin: Float = 0.3
        var active = false
    }

    private init() {}

    static func make() async -> StarGlint {
        let glint = StarGlint()
        glint.root.name = "v4.glints"
        let material = await MagicMaterials.additive(MagicTextures.shared.starGlint)
        for i in 0..<maxOnScreen {
            let holder = Entity()
            holder.name = "v4.glint\(i)"
            holder.components.set(BillboardComponent())
            holder.isEnabled = false
            // A 1 m quad scaled to the star's size, so one mesh serves every size.
            let quad = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [material])
            quad.name = "v4.glint\(i).star"
            holder.addChild(quad)
            glint.root.addChild(holder)
            glint.slots.append(Slot(holder: holder, quad: quad))
        }
        return glint
    }

    var activeCount: Int { slots.filter(\.active).count }

    /// A glint at `position` (in `root`'s space). Size and duration are clamped to the bible's ranges.
    func flash(at position: SIMD3<Float>, size: Float = 0.011, duration: Float = 0.34, spin: Float = 0.35) {
        let index = slots.firstIndex(where: { !$0.active })
            ?? slots.indices.min(by: { slots[$0].start < slots[$1].start }) ?? 0
        slots[index].start = clock
        slots[index].duration = min(Self.durationRange.upperBound, max(Self.durationRange.lowerBound, duration))
        slots[index].size = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, size))
        slots[index].spin = spin
        slots[index].active = true
        slots[index].holder.position = position
        slots[index].holder.isEnabled = true
        apply(index, at: 0)
    }

    /// Holds every glint where it is (the lab's still frames).
    func pause(_ on: Bool) { paused = on }

    func update(dt: Float) {
        guard !paused else { return }
        clock += dt
        for i in slots.indices where slots[i].active {
            let t = (clock - slots[i].start) / max(0.01, slots[i].duration)
            if t >= 1 {
                slots[i].active = false
                slots[i].holder.isEnabled = false
            } else {
                apply(i, at: t)
            }
        }
    }

    func hideAll() {
        for i in slots.indices {
            slots[i].active = false
            slots[i].holder.isEnabled = false
        }
    }

    /// The envelope: open fast with a 6 % overshoot, close slower to a point; a small turn throughout.
    private func apply(_ index: Int, at t: Float) {
        let attack: Float = 0.22
        let open: Float
        if t < attack {
            let x = t / attack
            open = 1 + 0.06 * sin(.pi * x) - pow(1 - x, 3)
        } else {
            let x = (t - attack) / (1 - attack)
            open = pow(1 - x, 1.6)
        }
        let scale = max(0.0001, slots[index].size * open)
        slots[index].quad.transform = Transform(scale: [scale, scale, scale],
                                                rotation: simd_quatf(angle: slots[index].spin * t, axis: [0, 0, 1]),
                                                translation: .zero)
    }
}
