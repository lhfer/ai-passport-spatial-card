import RealityKit
import SwiftUI
import UIKit

/// The set every lab scene builds on.
///
/// Spaces:
/// - `root`: world space (the immersive space's origin, on the floor under the wearer).
/// - `desk`: the desk's top surface, +Y up, origin directly under the device.
/// - `caseFrame`: the case's top-face centre, same axes as S. Case-shaped effects (outline scans, the button edge,
///   the top-edge hinge, the footprint) belong here.
/// - `deviceFrame`: the screen frame **S** — origin at the centre of the LCD's *lit area* on the top face, +Y the
///   screen normal, +Z towards the bottom edge (the reader), −Z towards the top edge (the lanyard end). The lit area
///   is not centred on the case (`screenOffset`), which is why the two frames are separate. Screen-shaped effects
///   (the card rising, the well, light leaving the screen) belong here.
@MainActor
final class LabStage {
    /// The case (x width, y thickness, z length), metres: 60 × 8 × 96 mm by ruler (2026-09-25). (The trained
    /// reference object and the headset's anchor box say 60 × 8.5 × 95.)
    static let deviceSize: SIMD3<Float> = [0.060, 0.008, 0.096]
    /// The LCD's lit area (card.json `device.activeAreaMm`, nominal), metres.
    static let screenSize: SIMD2<Float> = [0.03672, 0.04896]
    /// The lit area's centre relative to the case centre, in S (x across, z towards the reader), metres. By ruler
    /// (2026-09-25) the lit area starts 10 mm from the case's left edge and 12 mm from its top (lanyard) edge:
    /// x = −30 + 10 + 18.36 = −1.64 mm, z = −48 + 12 + 24.48 = −11.52 mm.
    static let screenOffset: SIMD2<Float> = [-0.00164, -0.01152]

    let root = Entity()
    let desk = Entity()
    let caseFrame = Entity()
    let deviceFrame = Entity()
    /// The proxy body and screen. Disable it when a lab wants the bare frame.
    let device = Entity()
    private(set) var screen = ModelEntity()

    private var tapHandlers: [(Entity) -> Void] = []
    private let startedAt = Date()

    init() {
        root.name = "lab.root"
        desk.name = "lab.desk"
        caseFrame.name = "lab.caseFrame"
        deviceFrame.name = "lab.deviceFrame"
        device.name = "lab.device"
        desk.position = [0, LabLaunch.deskHeight, -LabLaunch.distance]
        root.addChild(desk)
        if LabLaunch.showsDesk { desk.addChild(Self.makeDeskTop()) }
        if LabLaunch.night { root.addChild(Self.makeNightDome()) }
        caseFrame.position = [0, Self.deviceSize.y, 0]
        desk.addChild(caseFrame)
        deviceFrame.position = [Self.screenOffset.x, 0, Self.screenOffset.y]
        caseFrame.addChild(deviceFrame)
        caseFrame.addChild(device)
        buildDevice()
    }

    /// Seconds since the stage was built.
    var time: Double { Date().timeIntervalSince(startedAt) }

    /// Per-frame work; `dt` is clamped to 0.05 s by `EngineTickSystem`.
    func onTick(_ tick: @escaping (Float) -> Void) {
        let driver = Entity()
        driver.name = "lab.tick"
        driver.components.set(EngineTickComponent(tick: tick))
        root.addChild(driver)
    }

    /// A scripted beat: runs once, `seconds` after the call.
    func at(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            body()
        }
    }

    /// Spatial taps on any entity that has `InputTargetComponent` + a collision shape (see `makeTappable`).
    func onTap(_ handler: @escaping (Entity) -> Void) { tapHandlers.append(handler) }

    func makeTappable(_ entity: Entity, shape: ShapeResource) {
        entity.components.set(InputTargetComponent())
        entity.components.set(CollisionComponent(shapes: [shape]))
        entity.components.set(HoverEffectComponent())
    }

    func handleTap(on entity: Entity) {
        for handler in tapHandlers { handler(entity) }
    }

    func log(_ message: String) {
        print("[lab] \(String(format: "%6.2f", time)) s  \(message)")
    }

    // MARK: - Set

    private static func makeDeskTop() -> ModelEntity {
        var wood = PhysicallyBasedMaterial()
        wood.baseColor = .init(tint: UIColor(hex: "#3B2A1D"))
        wood.roughness = .init(floatLiteral: 0.72)
        wood.metallic = .init(floatLiteral: 0)
        let top = ModelEntity(mesh: .generateBox(width: 1.1, height: 0.02, depth: 0.6, cornerRadius: 0.004),
                              materials: [wood])
        top.name = "lab.deskTop"
        top.position = [0, -0.01, 0.1]
        top.components.set(GroundingShadowComponent(castsShadow: false, receivesShadow: true))
        return top
    }

    /// A 6 m inward-facing sphere in the art bible's `night` blue: a dim room for judging glow and gold.
    private static func makeNightDome() -> ModelEntity {
        let dome = ModelEntity(mesh: .generateSphere(radius: 6), materials: [UnlitMaterial(color: UIColor(hex: "#0B1230"))])
        dome.name = "lab.nightDome"
        dome.scale = [-1, 1, 1]
        dome.position = [0, 1.5, 0]
        return dome
    }

    /// Smoked translucent case (the "Smoked Vibe" unit) with the base theme on a 36.7 × 49 mm screen.
    private func buildDevice() {
        let size = Self.deviceSize
        var shell = PhysicallyBasedMaterial()
        shell.baseColor = .init(tint: UIColor(hex: "#16181D"))
        shell.roughness = .init(floatLiteral: 0.3)
        shell.metallic = .init(floatLiteral: 0)
        shell.clearcoat = .init(floatLiteral: 1)
        shell.blending = .transparent(opacity: .init(floatLiteral: 0.88))
        let body = ModelEntity(mesh: .generateBox(width: size.x, height: size.y, depth: size.z, cornerRadius: 0.004),
                               materials: [shell])
        body.name = "lab.device.body"
        body.position = [0, -size.y / 2, 0]
        body.components.set(GroundingShadowComponent(castsShadow: true))
        device.addChild(body)

        var glass = UnlitMaterial(color: .black)
        if let image = UIImage(named: "PassportBase")?.cgImage,
           let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
            glass.color = .init(tint: .white, texture: .init(texture))
        }
        let panel = ModelEntity(mesh: .generatePlane(width: Self.screenSize.x, depth: Self.screenSize.y, cornerRadius: 0.003),
                                materials: [glass])
        panel.name = "lab.device.screen"
        panel.position = [Self.screenOffset.x, 0.0003, Self.screenOffset.y]
        device.addChild(panel)
        screen = panel
    }
}
