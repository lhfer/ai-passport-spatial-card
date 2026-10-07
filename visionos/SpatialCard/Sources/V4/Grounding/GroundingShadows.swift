import RealityKit

/// Contact shadows for whole hierarchies (A3 目标 1.1).
///
/// `GroundingShadowComponent` "doesn't apply to hierarchies" (its own documentation): a card built from a slab, a
/// rim and a cover casts nothing unless every model in it carries the component. It also must **not** go on glow
/// quads and light pools — light casting a shadow is the one thing that instantly reads as fake — so the walk takes
/// a skip rule. Two more rules from the documentation shape the callers: one-sided geometry only casts when its
/// faces point at the receiver (so card faces are closed slabs, or double-sided), and neither virtual nor physical
/// lights move the shadow — it is always "a light directly above".
@MainActor
enum GroundingShadows {
    struct Options {
        var castsShadow = true
        /// Off for casters by default: a card receiving its own shadow darkens its face, and the desk (virtual or
        /// real) is the only thing that should.
        var receivesShadow = false
        /// Near real furniture the system fades the shadow by default; `.constant` keeps it.
        var fade: GroundingShadowComponent.FadeBehaviorNearPhysicalObjects = .default
    }

    /// Names that mark light, not matter. Anything named like this is skipped by `apply`'s default rule.
    static let lightNameMarkers = ["glow", "pool", "spill", "light", "dust", "halo"]

    /// Sets the component on `root` and every descendant with a `ModelComponent` that `skip` does not exclude.
    /// Returns how many entities now cast.
    @discardableResult
    static func apply(to root: Entity, options: Options = Options(),
                      skip: @MainActor (Entity) -> Bool = GroundingShadows.isLight) -> Int {
        var count = 0
        visit(root) { entity in
            guard entity.components.has(ModelComponent.self), !skip(entity) else { return }
            entity.components.set(GroundingShadowComponent(castsShadow: options.castsShadow,
                                                           receivesShadow: options.receivesShadow,
                                                           fadeBehaviorNearPhysicalObjects: options.fade))
            count += 1
        }
        return count
    }

    /// Removes the component from the whole subtree (the lab's `--grounding-shadows off`).
    static func remove(from root: Entity) {
        visit(root) { $0.components.remove(GroundingShadowComponent.self) }
    }

    /// Makes an entity invisible to other casters' shadows — a light pool must stay lit where the card's shadow
    /// falls on the desk under it.
    static func optOut(_ entity: Entity) {
        entity.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: false))
    }

    /// The default skip rule: entities whose name marks them as light.
    static func isLight(_ entity: Entity) -> Bool {
        let name = entity.name.lowercased()
        return lightNameMarkers.contains { name.contains($0) }
    }

    private static func visit(_ entity: Entity, _ body: (Entity) -> Void) {
        body(entity)
        for child in entity.children { visit(child, body) }
    }
}
