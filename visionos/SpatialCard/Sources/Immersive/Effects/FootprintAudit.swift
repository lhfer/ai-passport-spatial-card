import Foundation
import RealityKit
import simd

/// How one entity is judged against the footprint prism. Without this component an entity is judged on its
/// axis-aligned visual bounds, which is right for the solid quads and slabs that the rule is really about.
struct FootprintProbeComponent: Component {
    enum Kind: Equatable {
        /// Never reported: the `--preview` device stand-in (it *is* the hardware in a run with no hardware)
        /// and the brief FX the rule exempts by name.
        case exempt
        /// Hollow: the clear opening this shape leaves over the device, as a half extent in S. Reported only
        /// when the footprint does not fit through it.
        case hole(SIMD2<Float>)
        /// The same for a round opening (an annulus): the radius of its clear middle.
        case circularHole(Float)
        /// Thin and oblique (a 1.4 mm ray, a cone's spine): judged on these sample points in the entity's own
        /// space rather than on a bounding box that spans the whole flight from the device to the card.
        case points([SIMD3<Float>])
        /// **V3-2a2 S0**: the hinged card's slab and rim. Tolerated *only* while the card really hangs off
        /// the hinge (the auditor checks the parent chain, it does not take the caller's word for it) and
        /// only while nothing of it reaches further back than `maxDepth` from the device's top edge —
        /// i.e. it overhangs the bezel and no more. Anything else, including V3-1's 35 mm hover form, is
        /// reported exactly as an unprobed slab would be.
        case hingeOverhang(maxDepth: Float)
    }

    var kind: Kind

    init(_ kind: Kind) { self.kind = kind }
}

/// Walks the tree once a second and reports anything that has been sitting inside the prism for more than
/// 1.5 s without a break. `--footprint-check` turns it on; it is off by default and costs nothing then.
///
/// Brief FX are exempt *in time* rather than by name: the ink cinematic, the fold and the unfold are allowed
/// to cross the screen, so the caller opens a pause window around them (and the pause itself is logged, so a
/// silent audit can be told apart from an audit that was not running).
@MainActor
final class FootprintAuditor {
    /// Anything inside for longer than this is a finding.
    static let dwell: Float = 1.5
    /// How often the tree is walked.
    static let period: Float = 1

    var footprint = DeviceFootprint.aiPassport

    private var sinceLastWalk: Float = 0
    /// Continuous seconds each entity has been inside, keyed by identity (names repeat across the tree).
    private var inside: [ObjectIdentifier: (name: String, seconds: Float)] = [:]
    private var pausedFor: Float = 0
    private var pauseReason = ""

    /// Suspend the audit for `seconds` — the caller's promise that what is about to cross the screen is a
    /// brief effect, not a state.
    func pause(_ seconds: Float, reason: String) {
        guard seconds > pausedFor else { return }
        pausedFor = seconds
        pauseReason = reason
        inside.removeAll()
        print(String(format: "[footprint] audit paused (%@, %.1f s)", reason, seconds))
    }

    /// The hinge on the device's top edge (`HologramController.handPivot`). A `.hingeOverhang` probe is only
    /// tolerated on a shape that actually hangs off it — set once, read on every walk.
    weak var hinge: Entity?

    /// One frame. `roots` are the subtrees the rule covers (`anchorRoot` and `surface`); `space` is the frame every
    /// bound is measured in — the **case** frame C since v4 B1 (the prism is the case; the LCD hard zone sits at
    /// `footprint.lcdCenter` inside it).
    func step(dt: Float, roots: [Entity], space: Entity) {
        if pausedFor > 0 {
            pausedFor -= dt
            sinceLastWalk = 0
            return
        }
        sinceLastWalk += dt
        guard sinceLastWalk >= FootprintAuditor.period else { return }
        let elapsed = sinceLastWalk
        sinceLastWalk = 0
        var stillInside: [ObjectIdentifier: (name: String, seconds: Float)] = [:]
        for root in roots {
            walk(root, space: space, opacity: 1, into: &stillInside, elapsed: elapsed)
        }
        inside = stillInside
        for entry in inside.values.sorted(by: { $0.name < $1.name }) where entry.seconds > FootprintAuditor.dwell {
            print(String(format: "[footprint] %@ inside for %.1f s", entry.name, entry.seconds))
        }
    }

    /// Everything starts over (a hide, a world, a replay): nothing is "still" inside across a teardown.
    func reset() { inside.removeAll() }

    private func walk(_ entity: Entity, space: Entity, opacity: Float,
                      into found: inout [ObjectIdentifier: (name: String, seconds: Float)], elapsed: Float) {
        guard entity.isEnabled else { return }
        // An entity that has been faded to nothing is not on camera, whatever its bounds say. Opacity is
        // hierarchical in RealityKit, so it accumulates on the way down.
        let alpha = opacity * (entity.components[OpacityComponent.self]?.opacity ?? 1)
        guard alpha > 0.02 else { return }
        if let model = entity as? ModelEntity, model.model != nil {
            let probe = entity.components[FootprintProbeComponent.self]?.kind
            if isInside(model, space: space, probe: probe) {
                let key = ObjectIdentifier(model)
                let name = model.name.isEmpty ? "<unnamed \(type(of: model))>" : model.name
                found[key] = (name, (inside[key]?.seconds ?? 0) + elapsed)
            }
        }
        for child in entity.children {
            walk(child, space: space, opacity: alpha, into: &found, elapsed: elapsed)
        }
    }

    private func isInside(_ model: ModelEntity, space: Entity, probe: FootprintProbeComponent.Kind?) -> Bool {
        switch probe {
        case .exempt?:
            return false
        // v4 B1: a hollow shape is judged where it actually stands in `space`. v3 could assume every opening was
        // centred on the prism (one frame for case and screen); with the case frame 11.5 mm off the screen's, the
        // desk halo (under the screen) and the socket ring (around the case) are not centred on the same point.
        case .hole(let opening)?:
            let c = model.convert(position: .zero, to: space)
            guard footprint.containsHeight(c.y) else { return false }
            return !footprint.fitsThrough(hole: opening, center: [c.x, c.z])
        case .circularHole(let radius)?:
            let c = model.convert(position: .zero, to: space)
            guard footprint.containsHeight(c.y) else { return false }
            return !footprint.fitsThrough(circularHole: radius, center: [c.x, c.z])
        case .points(let samples)?:
            return samples.contains { footprint.contains(model.convert(position: $0, to: space)) }
        case .hingeOverhang(let maxDepth)?:
            let bounds = model.visualBounds(recursive: false, relativeTo: space)
            guard footprint.intersects(min: bounds.min, max: bounds.max) else { return false }
            guard isOnTheHinge(model) else { return true }
            return !footprint.toleratesOverhang(min: bounds.min, max: bounds.max, maxDepth: maxDepth)
        case nil:
            let bounds = model.visualBounds(recursive: false, relativeTo: space)
            return footprint.intersects(min: bounds.min, max: bounds.max)
        }
    }

    /// Is this entity a descendant of the hinge? The audit asks the tree rather than trusting a flag, so a
    /// path that forgets to detach the card cannot buy itself the bezel tolerance.
    private func isOnTheHinge(_ entity: Entity) -> Bool {
        guard let hinge else { return false }
        var node: Entity? = entity
        while let current = node {
            if current === hinge { return true }
            node = current.parent
        }
        return false
    }
}
