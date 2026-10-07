/// Namespace for v4's pure logic. Everything in `Sources/V4/Pure/` is simd + Foundation only (no RealityKit,
/// SwiftUI or ARKit), so project.yml compiles the whole folder into the unit-test bundle as well as the app —
/// timelines, curves and layouts get checked without an app host.
enum V4 {}
