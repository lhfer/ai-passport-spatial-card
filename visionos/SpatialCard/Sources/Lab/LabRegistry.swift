/// Every lab scene by `--lab` id. Each v4 work package adds its own line here and nothing else in this file;
/// the scene itself lives in its own file under `Sources/Lab/` (or next to the module it exercises).
@MainActor
enum LabRegistry {
    static let scenes: [String: (LabStage) async -> Void] = [
        // The bare set — virtual desk + proxy device — for framing checks.
        "stage": { stage in stage.log("stage ready") },
        "materials": { stage in await MaterialsLab.build(stage) },
        "card": { stage in await CardLab.run(stage) },
        "ribbon": { stage in await RibbonLab.run(stage) },
        "grounding": { stage in await GroundingLab.build(stage) },
    ]
}
