// A3 · offline subject masks for the living covers' "lift" mode.
//
// The visionOS simulator cannot run Vision's foreground instance mask ("Could not create inference context",
// com.apple.Vision code 9), so the lab's lift mode falls back to masks made here, on the Mac, with the very same
// request (VNGenerateForegroundInstanceMaskRequest, all instances, scaled to the image). On the headset the live
// request is tried first and these files are never read.
//
// Run from the repo root:
//   xcrun swift docs/v4/reports/media/a3-grounding/make-cover-masks.swift
// Writes visionos/SpatialCard/Resources/v4/v4-covermask-<name>.png (8-bit gray, the cover's own resolution;
// all-black when Vision finds no foreground, exactly what the live request would report as "no subject").
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

let root = FileManager.default.currentDirectoryPath
let app = "\(root)/visionos/SpatialCard"
var inputs: [(name: String, path: String)] = (1...10).map { ("fake-cover-\($0)", "\(app)/Tools/fake-cover-\($0).jpg") }
inputs.append(("avatar", "\(app)/Resources/Assets.xcassets/Avatar.imageset/avatar.png"))
let outputDirectory = "\(app)/Resources/v4"
try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

func writeGray(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
    let data = Data(pixels) as CFData
    guard let provider = CGDataProvider(data: data),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

for input in inputs {
    let url = URL(fileURLWithPath: input.path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        print("\(input.name): cannot read \(input.path)"); continue
    }
    let (width, height) = (image.width, image.height)
    var pixels = [UInt8](repeating: 0, count: width * height)
    let started = CFAbsoluteTimeGetCurrent()
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    var summary = "no foreground"
    do {
        try handler.perform([request])
        if let observation = request.results?.first, !observation.allInstances.isEmpty {
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let base = CVPixelBufferGetBaseAddress(buffer)!
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width { pixels[y * width + x] = UInt8(max(0, min(1, row[x])) * 255 + 0.5) }
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            summary = "\(observation.allInstances.count) instance(s)"
        }
    } catch {
        summary = "error \(error)"
    }
    let elapsed = (CFAbsoluteTimeGetCurrent() - started) * 1000
    let out = URL(fileURLWithPath: "\(outputDirectory)/v4-covermask-\(input.name).png")
    try writeGray(pixels, width: width, height: height, to: out)
    let coverage = Double(pixels.filter { $0 >= 128 }.count) / Double(pixels.count)
    print(String(format: "%@: %dx%d, %@, coverage %.3f, %.1f ms → %@", input.name, width, height, summary, coverage,
                 elapsed, out.lastPathComponent))
}
