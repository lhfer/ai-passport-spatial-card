import RealityKit
import SwiftUI
import UIKit

/// The card a living cover sits in (A3 封面区): the art bible's note card — a 3 mm plate with 6 mm corners and a thin
/// gold line inset 1.5 mm — laid out like a Xiaohongshu feed card: the cover on top, the title in a band below. The ♥
/// count is a separate SwiftUI pill the caller hangs **in front of** the cover's corner, which is also the brief's test
/// of "can SwiftUI sit in front of a spatial scene".
@MainActor
enum LivingCoverFrame {
    struct Style {
        /// Plate margin around the cover (sides and top).
        var border: Float = 0.0045
        /// Band under the cover for the title (0 = none).
        var captionBand: Float = 0.022
        var thickness: Float = 0.003
        var cornerRadius: Float = 0.006
        /// The gold line: inset from the plate's edge, and its width.
        var goldInset: Float = 0.0015
        var goldWidth: Float = 0.0012
        var plateColor = UIColor(hex: "#101634")
        var goldColor = UIColor(hex: "#C9A45C")
    }

    struct Built {
        let root: Entity
        /// Where the cover's `root` goes: centred on the cover's place on the plate's front face, +Z out.
        let mount: Entity
        /// Centre of the title band on the plate's front face.
        let band: Entity
        let plate: ModelEntity
        let gold: ModelEntity
        let plateSize: SIMD2<Float>
    }

    static func make(coverSize: SIMD2<Float>, style: Style = Style()) -> Built {
        let root = Entity()
        root.name = "coverFrame"
        let plateSize = SIMD2<Float>(coverSize.x + 2 * style.border, coverSize.y + 2 * style.border + style.captionBand)

        var plateMaterial = PhysicallyBasedMaterial()
        plateMaterial.baseColor = .init(tint: style.plateColor)
        plateMaterial.roughness = .init(floatLiteral: 0.3)
        plateMaterial.metallic = .init(floatLiteral: 0)
        plateMaterial.clearcoat = .init(floatLiteral: 1)
        plateMaterial.clearcoatRoughness = .init(floatLiteral: 0.08)
        // Opaque and lit on purpose: only opaque lit materials cast a grounding shadow (A4 §2, and this lab's
        // `--grounding-shadow-probe`), so the plate is what grounds the card.
        let plate = ModelEntity(mesh: FXMeshes.roundedSlab(width: plateSize.x, height: plateSize.y, depth: style.thickness,
                                                           radius: style.cornerRadius),
                                materials: [plateMaterial])
        plate.name = "coverFrame.plate"
        root.addChild(plate)

        var goldMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        goldMaterial.color = .init(tint: style.goldColor)
        let goldOuter = plateSize - SIMD2<Float>(repeating: 2 * style.goldInset)
        let gold = ModelEntity(mesh: FXMeshes.roundedRectRing(width: goldOuter.x, height: goldOuter.y,
                                                              radius: max(0.001, style.cornerRadius - style.goldInset),
                                                              thickness: style.goldWidth),
                               materials: [goldMaterial])
        gold.name = "coverFrame.goldEdge"
        gold.position = [0, 0, style.thickness / 2 + 0.0002]
        root.addChild(gold)

        let face = style.thickness / 2 + 0.0004
        let mount = Entity()
        mount.name = "coverFrame.mount"
        mount.position = [0, plateSize.y / 2 - style.border - coverSize.y / 2, face]
        root.addChild(mount)
        let band = Entity()
        band.name = "coverFrame.band"
        band.position = [0, -plateSize.y / 2 + style.border / 2 + style.captionBand / 2, face]
        root.addChild(band)
        // The frame, like the cover, always draws behind its own SwiftUI title and ♥ pill (see `LivingCover.sortBehindUI`).
        plate.components.set(ModelSortGroupComponent(group: .planarUIAlwaysBehind, order: -2))
        gold.components.set(ModelSortGroupComponent(group: .planarUIAlwaysBehind, order: -1))
        return Built(root: root, mount: mount, band: band, plate: plate, gold: gold, plateSize: plateSize)
    }

    /// The title as a SwiftUI attachment: `ViewAttachmentComponent(rootView:)` (visionOS 26) — no RealityView
    /// attachments closure needed. Width in points follows the band (1 m = 1360 pt, `HologramLayout`).
    static func makeTitle(_ title: String, width: Float, height: Float) -> Entity {
        let entity = Entity()
        entity.name = "coverFrame.title"
        let size = CGSize(width: CGFloat(width * HologramLayout.pointsPerMeter), height: CGFloat(height * HologramLayout.pointsPerMeter))
        entity.components.set(ViewAttachmentComponent(rootView: LivingCoverTitle(title: title, size: size)))
        return entity
    }

    /// The ♥ count pill, to be hung in front of the cover.
    static func makeLikes(_ likes: String) -> Entity {
        let entity = Entity()
        entity.name = "coverFrame.likes"
        entity.components.set(ViewAttachmentComponent(rootView: LivingCoverLikes(likes: likes)))
        return entity
    }
}

private enum LivingCoverPalette {
    static let gold = Color(red: 1.0, green: 0.835, blue: 0.541)
    static let goldHot = Color(red: 1.0, green: 0.953, blue: 0.839)
    static let xhsRed = Color(red: 1.0, green: 0.141, blue: 0.259)
    static let night = Color(red: 0.043, green: 0.071, blue: 0.188)
}

/// The note's title under its cover — PingFang (the system font), white-gold on the plate's night blue.
struct LivingCoverTitle: View {
    let title: String
    let size: CGSize

    var body: some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(LivingCoverPalette.goldHot)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
            .minimumScaleFactor(0.85)
            .frame(width: size.width, height: size.height, alignment: .leading)
    }
}

/// ♥ + count: the heart is the only `xhsRed` in the picture (art bible §1), the number a serif gold numeral with
/// monospaced digits (§6).
struct LivingCoverLikes: View {
    let likes: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "heart.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(LivingCoverPalette.xhsRed)
            Text(likes)
                .font(.system(size: 11, weight: .semibold, design: .serif))
                .monospacedDigit()
                .foregroundStyle(LivingCoverPalette.gold)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(LivingCoverPalette.night.opacity(0.78)))
        .overlay(Capsule().strokeBorder(LivingCoverPalette.gold.opacity(0.55), lineWidth: 0.6))
    }
}
