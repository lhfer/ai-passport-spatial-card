import Foundation

/// The RealityKit node definitions a MaterialX document has to carry itself.
///
/// `ShaderGraphMaterial(materialXLabel:data:)` does not compile MaterialX directly: CoreRealityIO first translates the
/// document to USD (`UsdMtlxRead`, `mtlxToUsdShade.cpp`), and that reader only knows the plain MaterialX 1.38 libraries
/// bundled in `CoreRealityIO.framework/libraries` (stdlib / pbrlib / bxdf). A `realitykit_*` node therefore resolves to
/// no nodedef, its USD prim gets no `info:id`, and ShaderGraph rejects the material with
/// `com.apple.shadergraph Code=12 "A surface node is required"` (surfaced to Swift as `LoadError.internalImportError`).
///
/// Declaring the nodedef **in the document** — copied verbatim from the simulator runtime's
/// `ShaderGraph.framework/MaterialX/Apple/apple_nodedefs/apple_defs.mtlx` — lets the reader stamp the USD prim with the
/// nodedef's name, which is exactly the id ShaderGraph's own library resolves. Each instance also names its nodedef
/// (`nodedef="ND_…"`) so no overload guessing is involved.
enum MaterialXLibrary {
    /// `ND_realitykit_unlit_surfaceshader` (apple_defs.mtlx).
    static let unlitDef = """
      <nodedef name="ND_realitykit_unlit_surfaceshader" node="realitykit_unlit_surfaceshader" nodegroup="realitykit">
        <input name="color" type="color3" value="1, 1, 1" />
        <input name="opacity" type="float" value="1" />
        <input name="opacityThreshold" type="float" value="0" />
        <input name="applyPostProcessToneMap" type="boolean" value="true" uniform="true" />
        <input name="hasPremultipliedAlpha" type="boolean" value="false" uniform="true" />
        <output name="out" type="surfaceshader" />
      </nodedef>
    """

    /// `ND_realitykit_pbr_surfaceshader` (apple_defs.mtlx — the original, un-versioned signature).
    static let pbrDef = """
      <nodedef name="ND_realitykit_pbr_surfaceshader" node="realitykit_pbr_surfaceshader" nodegroup="realitykit">
        <input name="baseColor" type="color3" value="0.18, 0.18, 0.18" />
        <input name="emissiveColor" type="color3" value="0, 0, 0" />
        <input name="normal" type="vector3" value="0, 0, 1" />
        <input name="roughness" type="float" value="0.5" />
        <input name="metallic" type="float" value="0" />
        <input name="ambientOcclusion" type="float" value="1" />
        <input name="specular" type="float" value="0.5" />
        <input name="opacity" type="float" value="1" />
        <input name="opacityThreshold" type="float" value="0" />
        <input name="clearcoat" type="float" value="0" />
        <input name="clearcoatRoughness" type="float" value="0.01" />
        <input name="clearcoatNormal" type="vector3" value="0, 0, 1" />
        <input name="hasPremultipliedAlpha" type="boolean" value="false" uniform="true" />
        <output name="out" type="surfaceshader" />
      </nodedef>
    """

    /// `ND_realitykit_viewdirection_vector3`: the direction from the surface point towards the eye (per eye).
    static let viewDirectionDef = """
      <nodedef name="ND_realitykit_viewdirection_vector3" node="realitykit_viewdirection" nodegroup="realitykit">
        <input name="space" type="string" enum="model,object,world,tangent" value="world" uniform="true" />
        <output name="out" type="vector3" default="0, 0, 1" />
      </nodedef>
    """

    /// `ND_realitykit_cameraposition_vector3`.
    static let cameraPositionDef = """
      <nodedef name="ND_realitykit_cameraposition_vector3" node="realitykit_cameraposition" nodegroup="realitykit">
        <input name="space" type="string" enum="model,object,world,tangent" value="world" uniform="true" />
        <output name="out" type="vector3" default="0, 0, 0" />
      </nodedef>
    """

    /// `ND_realitykit_environment_radiance`: samples the scene's IBL (diffuse + specular) for a normal.
    static let environmentRadianceDef = """
      <nodedef name="ND_realitykit_environment_radiance" node="realitykit_environment_radiance" nodegroup="realitykit">
        <input name="baseColor" type="color3" value="1.0,1.0,1.0" />
        <input name="roughness" type="half" value="0" />
        <input name="specular" type="half" value="0" />
        <input name="metallic" type="half" value="0" />
        <input name="normal" type="vector3" defaultgeomprop="Nworld" />
        <output name="diffuseRadiance" type="color3" />
        <output name="specularRadiance" type="color3" />
      </nodedef>
    """

    /// `ND_realitykit_background_blur_color3`: the blurred passthrough / scene behind the surface.
    static let backgroundBlurDef = """
      <nodedef name="ND_realitykit_background_blur_color3" node="realitykit_surface_background_blur_color3" nodegroup="realitykit">
        <output name="out" type="color3" />
      </nodedef>
    """
}
