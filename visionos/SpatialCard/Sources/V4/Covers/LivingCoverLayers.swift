import Accelerate
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import QuartzCore
import Vision

/// The pixels behind the living cover's **lift** mode (A3 目标 2.2): the subject's mask, and the three layers built
/// from it — the cut-out subject, its soft shadow, and a background with the subject's hole filled in.
///
/// Everything here is `nonisolated` and runs off the main actor; blurs and scales go through vImage because the app
/// ships Debug builds to the lab and a hand-written blur over 300 k pixels at -Onone would cost more than the Vision
/// request it follows.
enum LivingCoverLayers {
    /// An 8-bit mask at the cover's resolution (255 = subject).
    struct Mask: Sendable {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        /// Where it came from: `live` (Vision on this device) or the bundled file's name.
        var source: String
    }

    /// A decoded cover: premultiplied RGBA8, row-major, no padding.
    struct Pixels: @unchecked Sendable {
        var rgba: [UInt8]
        var width: Int
        var height: Int
    }

    struct Layers: @unchecked Sendable {
        /// The subject, premultiplied, alpha = mask × border fade.
        var foreground: CGImage
        /// Opaque, full resolution: barely defocused, the subject's hole filled with its surroundings.
        var background: CGImage
        /// Quarter resolution, black with the blurred mask as alpha.
        var shadow: CGImage
    }

    enum Failure: Error, CustomStringConvertible {
        case decode
        case noForeground
        case bitmap

        var description: String {
            switch self {
            case .decode: return "cannot decode the cover"
            case .noForeground: return "Vision found no foreground instance"
            case .bitmap: return "cannot build a bitmap"
            }
        }
    }

    // MARK: - Decode

    nonisolated static func decode(_ image: CGImage) throws -> Pixels {
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw Failure.decode }
        return Pixels(rgba: rgba, width: width, height: height)
    }

    // MARK: - Masks

    /// Vision's foreground instance mask for all instances, scaled to the image. Throws Vision's own error — on the
    /// visionOS simulator that is `Error Domain=com.apple.Vision Code=9 "Could not create inference context"`.
    nonisolated static func liveMask(for image: CGImage) throws -> Mask {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else { throw Failure.noForeground }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        return try mask(from: buffer, source: "live")
    }

    /// A mask precomputed on the Mac with the same request (`v4-covermask-<name>.png`, 8-bit gray, the cover's
    /// resolution) — the simulator's stand-in for the live request, and what a Mac hub could serve with every cover.
    nonisolated static func bundledMask(named name: String, width: Int, height: Int, bundle: Bundle = .main) -> Mask? {
        let file = "v4-covermask-\(name)"
        guard let url = bundle.url(forResource: file, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? Mask(pixels: pixels, width: width, height: height, source: "\(file).png") : nil
    }

    nonisolated private static func mask(from buffer: CVPixelBuffer, source: String) throws -> Mask {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.bitmap }
        var pixels = [UInt8](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width { pixels[y * width + x] = UInt8(max(0, min(1, row[x])) * 255 + 0.5) }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { pixels[y * width + x] = row[x] }
            }
        default:
            throw Failure.bitmap
        }
        return Mask(pixels: pixels, width: width, height: height, source: source)
    }

    // MARK: - Layers

    nonisolated static func makeLayers(_ image: Pixels, mask: Mask, parallax: V4.CoverParallax) throws -> Layers {
        let w = image.width, h = image.height
        guard mask.width == w, mask.height == h else { throw Failure.bitmap }

        // Every step is a vImage / vDSP primitive: the first version did the per-pixel arithmetic in Swift loops and
        // cost 300–430 ms a cover in the lab's Debug build (the bench's numbers); this one does not loop over pixels.

        // Foreground: the subject, dissolving into the frame near the border so a subject the frame cuts never shows
        // its cut when it slides at an angle. alpha = soft mask × (row fade ⊗ column fade).
        let fadeWidth = max(1, Int(Float(min(w, h)) * parallax.borderFade))
        func ramp(_ i: Int, _ n: Int) -> Float {
            let d = Float(min(i, n - 1 - i)) / Float(fadeWidth)
            let t = max(0, min(1, d))
            return t * t * (3 - 2 * t)
        }
        let rowFade = (0..<h).map { ramp($0, h) }
        let columnFade = (0..<w).map { ramp($0, w) * 255 }
        var fade = [Float](repeating: 0, count: w * h)
        vDSP_mmul(rowFade, 1, columnFade, 1, &fade, 1, vDSP_Length(h), vDSP_Length(w), 1)
        var fade8 = [UInt8](repeating: 0, count: w * h)
        vDSP.convertElements(of: fade, to: &fade8, rounding: .towardNearestInteger)
        let softMask = try tent(mask.pixels, width: w, height: h, kernel: 3)
        let alpha = try multiplyPlanar(softMask, fade8, width: w, height: h)
        var foreground = image.rgba
        try overwriteAlpha(&foreground, with: alpha, width: w, height: h)
        try premultiply(&foreground, width: w, height: h)

        // Shadow: the mask, quarter size, blurred wide — a soft contact shadow, not a silhouette. Black, alpha = blur.
        let (qw, qh) = (max(8, w / 4), max(8, h / 4))
        let quarter = try scalePlanar(mask.pixels, width: w, height: h, to: qw, qh)
        let shadowAlpha = try tent(quarter, width: qw, height: qh, kernel: oddKernel(Float(qw) * 0.06))
        var shadow = [UInt8](repeating: 0, count: qw * qh * 4)
        try overwriteAlpha(&shadow, with: shadowAlpha, width: qw, height: qh)

        // Background: the cover itself, barely defocused (a cover's own lettering must stay legible — an earlier build
        // defocused it at half resolution and "笔记 8" went soft), and where the subject was, filled with its own
        // surroundings: normalised convolution — blur the premultiplied (image, weight = 1 − dilated mask) pair and
        // unpremultiply — at two radii, the near fill composited over the far one by its own coverage. What shows
        // through the gap when the subject slides is then the backdrop, not a ghost of the subject. The fill is made
        // at half size (it is a blur anyway) and composited over the full-size cover by the softened mask.
        let (hw, hh) = (max(8, w / 2), max(8, h / 2))
        let half = try scaleRGBA(image.rgba, width: w, height: h, to: hw, hh)
        let halfMask = try scalePlanar(mask.pixels, width: w, height: h, to: hw, hh)
        let dilated = try maxFilter(halfMask, width: hw, height: hh, kernel: oddKernel(Float(hw) * 0.03))
        let blendHalf = try tent(dilated, width: hw, height: hh, kernel: oddKernel(Float(hw) * 0.04))
        var weighted = half
        try overwriteAlpha(&weighted, with: try invert(dilated, width: hw, height: hh), width: hw, height: hh)
        try premultiply(&weighted, width: hw, height: hh)
        let near = try tentRGBA(weighted, width: hw, height: hh, kernel: oddKernel(Float(hw) * 0.17))
        var far = try tentRGBA(weighted, width: hw, height: hh, kernel: oddKernel(Float(hw) * 0.5))
        try unpremultiply(&far, width: hw, height: hh)
        try fillAlpha(&far, value: 255, width: hw, height: hh)
        let fillHalf = try blendOver(top: near, bottom: far, width: hw, height: hh)
        var fill = try scaleRGBA(fillHalf, width: hw, height: hh, to: w, h)
        try overwriteAlpha(&fill, with: try scalePlanar(blendHalf, width: hw, height: hh, to: w, h), width: w, height: h)
        try premultiply(&fill, width: w, height: h)
        let defocus = try tentRGBA(image.rgba, width: w, height: h, kernel: 3)
        let background = try blendOver(top: fill, bottom: defocus, width: w, height: h)

        return Layers(foreground: try cgImage(foreground, width: w, height: h),
                      background: try cgImage(background, width: w, height: h),
                      shadow: try cgImage(shadow, width: qw, height: qh))
    }

    // MARK: - vImage helpers

    nonisolated private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    nonisolated private static func oddKernel(_ size: Float) -> UInt32 {
        let n = max(3, Int(size.rounded()))
        return UInt32(n % 2 == 0 ? n + 1 : n)
    }

    nonisolated private static func planar(_ raw: UnsafeMutableRawBufferPointer, _ w: Int, _ h: Int, _ bytesPerPixel: Int) -> vImage_Buffer {
        vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * bytesPerPixel)
    }

    /// a × b / 255, planar.
    nonisolated private static func multiplyPlanar(_ a: [UInt8], _ b: [UInt8], width w: Int, height h: Int) throws -> [UInt8] {
        var a = a, b = b
        var dst = [UInt8](repeating: 0, count: w * h)
        let error = a.withUnsafeMutableBytes { ra in
            b.withUnsafeMutableBytes { rb in
                dst.withUnsafeMutableBytes { rd -> vImage_Error in
                    var src = planar(ra, w, h, 1), alpha = planar(rb, w, h, 1), out = planar(rd, w, h, 1)
                    return vImagePremultiplyData_Planar8(&src, &alpha, &out, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
        return dst
    }

    /// 255 − a, planar.
    nonisolated private static func invert(_ a: [UInt8], width w: Int, height h: Int) throws -> [UInt8] {
        var a = a
        var dst = [UInt8](repeating: 0, count: w * h)
        let table = (0..<256).map { Pixel_8(255 - $0) }
        let error = a.withUnsafeMutableBytes { ra in
            dst.withUnsafeMutableBytes { rd -> vImage_Error in
                var src = planar(ra, w, h, 1), out = planar(rd, w, h, 1)
                return vImageTableLookUp_Planar8(&src, &out, table, vImage_Flags(kvImageNoFlags))
            }
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
        return dst
    }

    /// Replaces the fourth channel (alpha in RGBA) with `plane`. vImage's mask bits name ARGB channels: 0x1 is the
    /// fourth byte.
    nonisolated private static func overwriteAlpha(_ rgba: inout [UInt8], with plane: [UInt8], width w: Int, height h: Int) throws {
        var plane = plane
        let error = plane.withUnsafeMutableBytes { rp in
            rgba.withUnsafeMutableBytes { rr -> vImage_Error in
                var source = planar(rp, w, h, 1), image = planar(rr, w, h, 4)
                return vImageOverwriteChannels_ARGB8888(&source, &image, &image, 0x1, vImage_Flags(kvImageNoFlags))
            }
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
    }

    nonisolated private static func fillAlpha(_ rgba: inout [UInt8], value: UInt8, width w: Int, height h: Int) throws {
        let error = rgba.withUnsafeMutableBytes { rr -> vImage_Error in
            var image = planar(rr, w, h, 4)
            return vImageOverwriteChannelsWithScalar_ARGB8888(value, &image, &image, 0x1, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
    }

    nonisolated private static func premultiply(_ rgba: inout [UInt8], width w: Int, height h: Int) throws {
        let error = rgba.withUnsafeMutableBytes { rr -> vImage_Error in
            var image = planar(rr, w, h, 4)
            return vImagePremultiplyData_RGBA8888(&image, &image, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
    }

    nonisolated private static func unpremultiply(_ rgba: inout [UInt8], width w: Int, height h: Int) throws {
        let error = rgba.withUnsafeMutableBytes { rr -> vImage_Error in
            var image = planar(rr, w, h, 4)
            return vImageUnpremultiplyData_RGBA8888(&image, &image, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
    }

    /// Premultiplied `top` over `bottom` (alpha last). `vImagePremultipliedAlphaBlend_RGBA8888` is a C macro Swift
    /// cannot see; it expands to the BGRA function, which is order-agnostic for the three colour channels.
    nonisolated private static func blendOver(top: [UInt8], bottom: [UInt8], width w: Int, height h: Int) throws -> [UInt8] {
        var top = top, bottom = bottom
        var dst = [UInt8](repeating: 0, count: w * h * 4)
        let error = top.withUnsafeMutableBytes { rt in
            bottom.withUnsafeMutableBytes { rb in
                dst.withUnsafeMutableBytes { rd -> vImage_Error in
                    var a = planar(rt, w, h, 4), b = planar(rb, w, h, 4), out = planar(rd, w, h, 4)
                    return vImagePremultipliedAlphaBlend_BGRA8888(&a, &b, &out, vImage_Flags(kvImageNoFlags))
                }
            }
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
        return dst
    }

    nonisolated private static func tent(_ src: [UInt8], width: Int, height: Int, kernel: UInt32) throws -> [UInt8] {
        var src = src
        var dst = [UInt8](repeating: 0, count: width * height)
        let error = src.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d -> vImage_Error in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                return vImageTentConvolve_Planar8(&a, &b, nil, 0, 0, kernel, kernel, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
        return dst
    }

    nonisolated private static func maxFilter(_ src: [UInt8], width: Int, height: Int, kernel: UInt32) throws -> [UInt8] {
        var src = src
        var dst = [UInt8](repeating: 0, count: width * height)
        let error = src.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d -> vImage_Error in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                return vImageMax_Planar8(&a, &b, nil, 0, 0, vImagePixelCount(kernel), vImagePixelCount(kernel), vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
        return dst
    }

    nonisolated private static func tentRGBA(_ src: [UInt8], width: Int, height: Int, kernel: UInt32) throws -> [UInt8] {
        var src = src
        var dst = [UInt8](repeating: 0, count: width * height * 4)
        let error = src.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d -> vImage_Error in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                return vImageTentConvolve_ARGB8888(&a, &b, nil, 0, 0, kernel, kernel, nil, vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
        return dst
    }

    nonisolated private static func scalePlanar(_ src: [UInt8], width: Int, height: Int, to w: Int, _ h: Int) throws -> [UInt8] {
        var src = src
        var dst = [UInt8](repeating: 0, count: w * h)
        let error = src.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d -> vImage_Error in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                return vImageScale_Planar8(&a, &b, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
        return dst
    }

    nonisolated private static func scaleRGBA(_ src: [UInt8], width: Int, height: Int, to w: Int, _ h: Int) throws -> [UInt8] {
        var src = src
        var dst = [UInt8](repeating: 0, count: w * h * 4)
        let error = src.withUnsafeMutableBytes { s in
            dst.withUnsafeMutableBytes { d -> vImage_Error in
                var a = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var b = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                return vImageScale_ARGB8888(&a, &b, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else { throw Failure.bitmap }
        return dst
    }

    nonisolated static func cgImage(_ rgba: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw Failure.bitmap
        }
        return image
    }
}
