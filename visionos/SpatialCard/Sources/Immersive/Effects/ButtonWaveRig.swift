import Foundation
import RealityKit
import simd
import UIKit

/// **Button feedback 2.0 — the ring that answers the key** (V3-4 §1).
///
/// 24 thin emissive segments around the device's outline, at opacity 0 until something lights them. A press
/// sends two wavefronts out from the key in opposite directions at 1 m/s; they meet on the far side. A long
/// press keeps sending them, one lap every 0.6 s. The folded card's "sleep" patrol (§8) borrows the same ring
/// at a third of the brightness and a tenth of the speed.
///
/// The structure is `BoxScanRig`'s: many small entities, one staggered tween each, the stagger computed by a
/// pure value type (`ButtonWaveLayout`) so the geometry can be tested without a scene.
///
/// **H0.** Every segment is centred on `ButtonWaveLayout.halfExtent` — the audited prism plus 5 mm plus half
/// the segment's own width — so its inner edge is 5 mm clear of the prism. On top of that it is opacity 0 at
/// rest and lit for a quarter of a second, either of which the auditor already skips. The ring is outside by
/// construction, not by exemption.
///
/// **V3-5 §3.** What was *not* outside was the auditor's own view of it. Without a probe the auditor judges
/// an entity on its axis-aligned `visualBounds`, and the four corner segments (6, 11, 18, 23) lie at ~45°,
/// where that box is ±5 mm bigger than the rectangle inside it and crosses the prism's corner by 0.3–2.1 mm.
/// The second headset round duly reported `buttonWave.11 / .18 inside for 2–3 s` for two segments that were
/// never over the device. Each segment now carries its own four corners (`ButtonWaveLayout.localCorners`) —
/// an exact test of the rotated rectangle, which is the same thing `ButtonWaveTests` has always checked.
@MainActor
final class ButtonWaveRig {
    let root = Entity()
    private var segments: [ModelEntity] = []
    private var footprint: DeviceFootprint
    private var tint: UIColor
    /// The lap the long press / the patrol is running, cancelled by the next press or by `stop`.
    private var loop: Task<Void, Never>?

    /// One wave's rise / hold / fall, in seconds — 0.25 s in total, as the brief asks. The numbers live in
    /// `ButtonWaveLayout` (V3-5 §3) so the envelope they drive is a pure function with a test on it.
    static let rise = ButtonWaveLayout.rise
    static let hold = ButtonWaveLayout.hold
    static let fall = ButtonWaveLayout.fall
    /// A long press sends a lap this often.
    static let holdPeriod: Double = 0.6
    /// **V3-5 §7c: 4 → 6 (×1.5).** The in-hand edge ring is turned down to 0.35 and the wave turned up, so
    /// the running light is the brighter of the two on camera rather than the dimmer.
    static let emissiveIntensity: Float = 6

    init(footprint: DeviceFootprint, tint: UIColor) {
        self.footprint = footprint
        self.tint = tint
        root.name = "buttonWave"
        root.components.set(BloomComponent(scope: .hierarchical))
        var bloom = BloomOptionsComponent()
        bloom.strength = 0.5
        bloom.threshold = 1.0
        root.components.set(bloom)
        root.isEnabled = false
        rebuild()
    }

    /// The device measured itself (or `--fake-box` changed): re-cut the ring.
    func configure(footprint: DeviceFootprint) {
        guard footprint != self.footprint else { return }
        self.footprint = footprint
        rebuild()
    }

    /// The world's accent while a world is open; the desk look otherwise.
    func setTint(_ colour: UIColor) {
        guard colour != tint else { return }
        tint = colour
        for segment in segments {
            segment.model?.materials = [HologramController.emissive(tint, intensity: ButtonWaveRig.emissiveIntensity, opacity: 1)]
        }
    }

    private func rebuild() {
        for segment in segments { segment.removeFromParent() }
        let layout = ButtonWaveLayout.segments(footprint: footprint)
        segments = layout.enumerated().map { index, slot in
            let mesh = MeshResource.generatePlane(width: ButtonWaveLayout.segmentLength,
                                                  depth: ButtonWaveLayout.segmentWidth,
                                                  cornerRadius: ButtonWaveLayout.segmentWidth / 2)
            let segment = ModelEntity(mesh: mesh,
                                      materials: [HologramController.emissive(tint, intensity: ButtonWaveRig.emissiveIntensity, opacity: 1)])
            segment.name = "buttonWave.\(index)"
            segment.position = slot.position
            segment.orientation = simd_quatf(angle: slot.yaw, axis: [0, 1, 0])
            segment.components.set(OpacityComponent(opacity: 0))
            // **V3-5 §3.** Judged on its own four corners rather than on a box drawn round them: the four
            // corner segments lie at ~45° and their axis-aligned bounds reach 0.3–2.1 mm into the prism
            // although the rectangles themselves are 4 mm clear of it. That is what the second headset
            // round reported as `buttonWave.11 / .18 inside for 2–3 s`. See `ButtonWaveLayout.localCorners`.
            segment.components.set(FootprintProbeComponent(.points(ButtonWaveLayout.localCorners)))
            root.addChild(segment)
            return segment
        }
    }

    // MARK: - The wave

    /// One lap, leaving `key` in both directions. Returns the delays it used (the caller logs the meet time).
    @discardableResult
    func flash(key: ButtonGlintLayout.Key, edge: ButtonGlintLayout.Edge,
               peak: Float = 1, speed: Float = ButtonWaveLayout.speed) -> [Float] {
        root.isEnabled = true
        let delays = ButtonWaveLayout.delays(footprint: footprint, key: key, edge: edge,
                                             count: segments.count, speed: speed)
        for (index, segment) in segments.enumerated() {
            guard index < delays.count else { continue }
            segment.isEnabled = true
            segment.components.set(WaveSegmentComponent(delay: delays[index], rise: ButtonWaveRig.rise,
                                                        hold: ButtonWaveRig.hold, fall: ButtonWaveRig.fall,
                                                        peak: peak))
        }
        return delays
    }

    /// A long press: laps until `stopHold`.
    func startHold(key: ButtonGlintLayout.Key, edge: ButtonGlintLayout.Edge) {
        loop?.cancel()
        loop = Task { @MainActor [weak self] in
            // **v4 B3.** The firmware reports a long press once (`ev:"long"`) and never its release, so "until it ends"
            // used to mean "until the next key": a long OK left the laps running round the device indefinitely. Long OK
            // is the collapse now, and the collapsed passport's only picture is the gold point — the laps stop after
            // `holdLaps`, about as long as a thumb stays down after the long press registers.
            for _ in 0..<ButtonWaveRig.holdLaps {
                guard let self, !Task.isCancelled else { return }
                self.flash(key: key, edge: edge, peak: 0.85)
                try? await Task.sleep(for: .milliseconds(Int(ButtonWaveRig.holdPeriod * 1000)))
            }
        }
    }

    /// How many laps a long press runs (`holdPeriod` apart).
    static let holdLaps = 2

    func stopHold() {
        loop?.cancel()
        loop = nil
    }

    /// **§8's sleep patrol.** A slow, dim lap every `period` seconds, starting at the OK key so the light
    /// always sets off from the same place the wearer's thumb rests.
    func startPatrol(period: Double, edge: ButtonGlintLayout.Edge, peak: Float = 0.3) {
        loop?.cancel()
        // One lap has to be slower than the press wave or it reads as a second button press: a full lap in
        // half the patrol period.
        let speed = Float(ButtonWaveLayout.perimeter(footprint)) / Float(max(0.5, period / 2))
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.flash(key: .ok, edge: edge, peak: peak, speed: speed)
                try? await Task.sleep(for: .milliseconds(Int(period * 1000)))
            }
        }
    }

    /// Every segment dark, every lap cancelled.
    func stop() {
        loop?.cancel()
        loop = nil
        for segment in segments {
            segment.components.remove(WaveSegmentComponent.self)
            segment.components.set(OpacityComponent(opacity: 0))
        }
        root.isEnabled = false
    }

    var segmentCount: Int { segments.count }
    var meetSeconds: Float { ButtonWaveLayout.meetSeconds(footprint) }
}

// MARK: - The one-segment envelope

/// One segment of the wave: dark for `delay`, then 0 → `peak` over `rise`, held for `hold`, back to 0 over
/// `fall`. A `TweenComponent` can only do one leg of that, and three chained tweens per segment per press is
/// 72 `Task`s a click; this is one component and one system.
struct WaveSegmentComponent: Component {
    var delay: Float
    var rise: Float
    var hold: Float
    var fall: Float
    var peak: Float
    var elapsed: Float = 0
}

final class WaveSegmentSystem: System {
    private static let query = EntityQuery(where: .has(WaveSegmentComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("waveSegment", since: cpuStart) }
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: WaveSegmentSystem.query, updatingSystemWhen: .rendering) {
            guard var wave = entity.components[WaveSegmentComponent.self] else { continue }
            wave.elapsed += dt
            // **V3-5 §3.** The curve itself is `ButtonWaveLayout.envelope` — a pure function, so "a finished
            // wave leaves the segment at exactly 0" is an assertion in `ButtonWaveTests` rather than a
            // reading of this loop.
            guard let opacity = ButtonWaveLayout.envelope(t: wave.elapsed - wave.delay, rise: wave.rise,
                                                          hold: wave.hold, fall: wave.fall, peak: wave.peak) else {
                entity.components.set(OpacityComponent(opacity: 0))
                entity.components.remove(WaveSegmentComponent.self)
                // v4 B2: a dark segment leaves the tree (24 of them stayed enabled at opacity 0 after every press);
                // the next `flash` switches it back on.
                entity.isEnabled = false
                continue
            }
            entity.components.set(OpacityComponent(opacity: opacity))
            entity.components.set(wave)
        }
    }
}
