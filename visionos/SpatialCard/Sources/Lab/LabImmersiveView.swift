import RealityKit
import SwiftUI

/// The immersive content for `--lab <id>`: builds the `LabStage` and hands it to the lab scene.
struct LabImmersiveView: View {
    let labID: String
    @State private var stage: LabStage?

    var body: some View {
        RealityView { content in
            let stage = LabStage()
            self.stage = stage
            content.add(stage.root)
            stage.log("lab '\(labID)': desk top at \(LabLaunch.deskHeight) m, device \(LabLaunch.distance) m ahead")
            if let build = LabRegistry.scenes[labID] {
                await build(stage)
            } else {
                stage.log("unknown lab '\(labID)'; known: \(LabRegistry.scenes.keys.sorted().joined(separator: ", "))")
            }
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in stage?.handleTap(on: value.entity) }
        )
        .task {
            guard let seconds = LabLaunch.exitAfter else { return }
            try? await Task.sleep(for: .seconds(seconds))
            stage?.log("exit after \(seconds) s")
            exit(0)
        }
    }
}
