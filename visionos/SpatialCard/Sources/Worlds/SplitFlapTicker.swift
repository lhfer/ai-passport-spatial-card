import Foundation
import RealityKit
import UIKit

/// Split-flap follower counter for 霓虹雨城: one dark cell per digit with a glyph quad that flips about its
/// horizontal axis (0 → π over 0.18 s: the old digit folds down to edge-on, the new one folds in from the top),
/// cells staggered 40 ms right → left like a station board. Intermediate digits clatter through (up to one full
/// cycle per cell); the first flap of each cell sounds an ascending `chip0/1/2`, the rest a `tick`.
///
/// Local frame: cells along +X (units digit at the right end), quads face +Z, `root.position` = board centre.
@MainActor
final class SplitFlapTicker {
    let root = Entity()
    let digits: Int
    let cellWidth: Float
    let cellHeight: Float
    let gap: Float = 0.12
    /// Board width including the gaps (for mounting).
    var width: Float { Float(digits) * cellWidth + Float(digits - 1) * gap }
    private(set) var value = 0

    private struct Cell {
        let flap: ModelEntity
        var shown: Int                  // digit on the quad right now
        var queue: [Int] = []           // digits still to flip through (last = final)
        var flipT: Float?               // seconds into the current flip
        var delay: Float = 0            // stagger before the next flip may start
        var flapsPlayed = 0             // cues: chip on the first flap, tick after
        var swapped = false             // the digit was exchanged at the edge-on point of this flip
        var dim = false                 // leading zero
    }
    private var cells: [Cell] = []
    private var glyphs: [TextureResource] = []
    private let flipDuration: Float = 0.18
    private let stagger: Float = 0.04

    init(digits: Int, color: UIColor, frame: UIColor, cellWidth: Float = 1.05, cellHeight: Float = 1.5) {
        self.digits = max(1, digits)
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        glyphs = (0...9).map { WorldKit.glyphTexture(String($0), color: color, size: 256) }
        let plate = WorldKit.unlit(UIColor(hex: "#07091A"))
        let split = WorldKit.emissive(frame, intensity: 1.2)
        let quad = MeshResource.generatePlane(width: cellWidth * 0.9, height: cellHeight * 0.9)
        let x0 = -width / 2 + cellWidth / 2
        // v4 B5 §5: a plain box. The 4 cm fillet tessellated into ~13 k triangles that the neon city's
        // `flattenRoundedBoxes` then swapped for a plain box of the same extents, cell by cell — inside the build step that
        // held the desk's frame longest (`follower board`, 18 ms). The board looks the same; it is just built once.
        let backMesh = MeshResource.generateBox(width: cellWidth, height: cellHeight, depth: 0.16)
        let lineMesh = MeshResource.generateBox(width: cellWidth * 0.94, height: 0.025, depth: 0.03)
        for i in 0..<self.digits {
            let cellRoot = Entity()
            cellRoot.position = [x0 + Float(i) * (cellWidth + gap), 0, 0]
            let back = ModelEntity(mesh: backMesh, materials: [plate])
            back.position = [0, 0, -0.1]
            cellRoot.addChild(back)
            let flap = ModelEntity(mesh: quad, materials: [WorldKit.unlit(.white, texture: glyphs[0], toneMap: false)])
            flap.position = [0, 0, 0.01]
            flap.components.set(BloomComponent(scope: .hierarchical))
            cellRoot.addChild(flap)
            // The split line across the middle of the flap: the board's tell.
            let line = ModelEntity(mesh: lineMesh, materials: [split])
            line.position = [0, 0, 0.03]
            cellRoot.addChild(line)
            root.addChild(cellRoot)
            cells.append(Cell(flap: flap, shown: 0))
        }
    }

    /// Show `value`: `animated` flips every changed cell through the intermediate digits (right → left stagger);
    /// otherwise the digits are just set (build time). Idempotent: the same value again is a no-op.
    func set(value newValue: Int, animated: Bool) {
        let clamped = max(0, min(newValue, Int(pow(10, Double(digits))) - 1))
        guard clamped != value || !animated else { return }
        value = clamped
        let text = String(format: "%0\(digits)d", clamped)
        let chars = Array(text)
        var firstNonZero = chars.firstIndex { $0 != "0" } ?? chars.count - 1
        if firstNonZero >= chars.count { firstNonZero = chars.count - 1 }
        for i in 0..<digits {
            let target = Int(String(chars[i])) ?? 0
            let dim = i < firstNonZero
            cells[i].dim = dim
            if !animated {
                cells[i].queue.removeAll()
                cells[i].flipT = nil
                show(i, digit: target)
                continue
            }
            let last = cells[i].queue.last ?? cells[i].shown
            guard last != target || cells[i].dim != dim else { continue }
            // Clatter through the intermediate digits (upwards, wrapping), at most one full cycle.
            var d = last
            var path: [Int] = []
            while d != target && path.count < 10 {
                d = (d + 1) % 10
                path.append(d)
            }
            if path.isEmpty { path = [target] }
            cells[i].queue.append(contentsOf: path)
            // Right → left stagger from the units cell.
            cells[i].delay = max(cells[i].delay, Float(digits - 1 - i) * stagger)
            cells[i].flapsPlayed = 0
        }
    }

    private func show(_ i: Int, digit: Int) {
        cells[i].shown = digit
        let tint = cells[i].dim ? UIColor(white: 0.32, alpha: 1) : UIColor.white
        cells[i].flap.model?.materials = [WorldKit.unlit(tint, texture: glyphs[max(0, min(9, digit))], toneMap: false)]
    }

    /// Advance the flips.
    func update(dt: Float) {
        for i in cells.indices {
            if cells[i].flipT == nil {
                guard !cells[i].queue.isEmpty else { continue }
                cells[i].delay -= dt
                guard cells[i].delay <= 0 else { continue }
                cells[i].flipT = 0
                cells[i].swapped = false
                FXAudio.shared.play(cells[i].flapsPlayed == 0 ? [FXAudio.Cue.chip0, .chip1, .chip2][(digits - 1 - i) % 3] : .tick, on: root)
                cells[i].flapsPlayed += 1
            }
            guard var t = cells[i].flipT else { continue }
            t += dt
            let k = min(1, t / flipDuration)
            // Ease in (gravity) for the fold-down, ease out for the fold-in: one continuous swing.
            let e = k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2
            let angle = e * .pi
            if angle >= .pi / 2, !cells[i].swapped {
                // Edge-on: swap to the next digit; the second half folds it in from the top.
                cells[i].swapped = true
                if !cells[i].queue.isEmpty { show(i, digit: cells[i].queue.removeFirst()) }
            }
            let display = angle < .pi / 2 ? angle : angle - .pi
            cells[i].flap.orientation = simd_quatf(angle: display, axis: [1, 0, 0])
            if k >= 1 {
                cells[i].flap.orientation = simd_quatf(angle: 0, axis: [1, 0, 0])
                cells[i].flipT = nil
                cells[i].delay = 0.02
            } else {
                cells[i].flipT = t
            }
        }
    }

    /// True while any cell is still flipping (the billboard bloom peak follows the clatter).
    var isFlipping: Bool { cells.contains { $0.flipT != nil || !$0.queue.isEmpty } }
}
