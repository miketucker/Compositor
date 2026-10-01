import AppKit
import Testing
@testable import Compositor

/// A brush painting in a dither pattern, as Aseprite's dithered pressure does: crisp pixels, each painted or left,
/// as many of the pattern's as the density reaches, and the pattern lined up on the document's pixels.
@MainActor
struct DitherBrushTests {
    /// Aseprite's Bayer matrix, built as it builds one.
    static func bayer(_ n: Int) -> [[Int]] {
        func d(_ i: Int, _ j: Int, _ n: Int) -> Int {
            n == 2 ? [0, 2, 3, 1][i * 2 + j] : 4 * d(i % (n / 2), j % (n / 2), n / 2) + d(i / (n / 2), j / (n / 2), 2)
        }
        return (0..<n).map { i in (0..<n).map { j in d(i, j, n) } }
    }

    private let bayer4 = DitherPattern(matrix: bayer(4))!

    private func ink(density: Float, colors: PatternInk.Colors = .foreground) -> PatternInk {
        PatternInk(pattern: bayer4, colors: colors, background: (0, 0, 1), dynamics: BrushDynamicsTable(density: density))
    }

    private func stroke(_ ink: PatternInk, size: CGSize = CGSize(width: 200, height: 200), origin: CGPoint = .zero,
                        erasing: Bool = false, useGPU: Bool = true) throws -> BrushStroke {
        let session = EditorSession()
        session.createDocument(width: Int(size.width), height: Int(size.height))
        session.addBlankLayer()
        var layer = try #require(session.activeLayer)
        layer.transform.origin = origin
        if erasing {
            let context = try BrushRaster.context(width: Int(size.width), height: Int(size.height), mask: false)
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(origin: .zero, size: size))
            let image = try #require(context.makeImage())
            layer.asset = ImportedImage(image: image, thumbnail: image, name: "White")
        }
        var settings = BrushSettings(diameter: 80, hardness: 0.3, red: 1, green: 0, blue: 0, opacity: 1)
        settings.erasing = erasing
        settings.ink = .pattern(ink)
        return try BrushStroke(layer: layer, mask: false, settings: settings, canvas: size, useGPU: useGPU)
    }

    private func dab(_ stroke: BrushStroke, at point: CGPoint = CGPoint(x: 100, y: 100)) throws {
        try stroke.append([BrushSample(point: point)])
        try stroke.flush()
    }

    private func raster(_ stroke: BrushStroke, size: CGSize = CGSize(width: 200, height: 200)) throws -> CGContext {
        let context = try BrushRaster.context(width: Int(size.width), height: Int(size.height), mask: false)
        LayerRenderer.drawBrushPreview(nil, transform: stroke.paintTransform, center: stroke.paintTransform.center,
            scale: 1, opacity: 1, blendMode: .normal, mask: nil, patches: stroke.patches,
            pixelWidth: stroke.width, pixelHeight: stroke.height, paintingMask: false, in: context)
        return context
    }

    private func rgba(_ context: CGContext, _ x: Int, _ y: Int) -> [Int] {
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x * 4
        return (0..<4).map { Int(bytes[$0]) }
    }

    /// Well inside an 80 px dab at the middle of the canvas.
    private let interior = (80..<120).flatMap { y in (80..<120).map { x in (x, y) } }

    @Test func halfThePatternAtHalfDensity() throws {
        for useGPU in [true, false] {
            let brush = try stroke(ink(density: 0.5), useGPU: useGPU)
            try dab(brush)
            let painted = try raster(brush)
            var count = 0
            for (x, y) in interior {
                let on = rgba(painted, x, y)[3] == 255
                #expect(on == bayer4.isOn(x: x, y: y, density: 0.5), "\(x), \(y), GPU \(useGPU)")
                if on { count += 1 }
            }
            #expect(count == interior.count / 2)
        }
    }

    /// Painted or not, right to the stroke's edge: nothing in between, however soft the brush was set.
    @Test func itsEdgesAreCrisp() throws {
        let brush = try stroke(ink(density: 1))
        try dab(brush)
        let painted = try raster(brush)
        var inside = 0
        for y in 0..<200 {
            for x in 0..<200 {
                let alpha = rgba(painted, x, y)[3]
                #expect(alpha == 0 || alpha == 255, "\(x), \(y): \(alpha)")
                if alpha == 255 { inside += 1 }
            }
        }
        // About the 80 px circle's area.
        #expect(abs(Double(inside) - .pi * 40 * 40) < 200)
    }

    /// Denser fills the same pattern in: every pixel painted at a lighter density is painted at a firmer one.
    @Test func aDenserStrokeFillsThePatternIn() throws {
        let light = try raster({ let s = try stroke(ink(density: 0.3)); try dab(s); return s }())
        let firm = try raster({ let s = try stroke(ink(density: 0.7)); try dab(s); return s }())
        var lightCount = 0, firmCount = 0
        for (x, y) in interior {
            let a = rgba(light, x, y)[3] == 255, b = rgba(firm, x, y)[3] == 255
            if a { lightCount += 1; #expect(b, "\(x), \(y)") }
            if b { firmCount += 1 }
        }
        #expect(lightCount > 0 && firmCount > lightCount * 2)
    }

    /// Pressing harder along a stroke paints more of the pattern, through the brush's table.
    @Test func pressureSetsTheDensity() throws {
        let ramp = (0..<BrushDynamicsTable.steps).map { Float($0) / Float(BrushDynamicsTable.steps - 1) }
        let dynamics = BrushDynamicsTable(density: ramp, size: Array(repeating: 1, count: BrushDynamicsTable.steps))
        let size = CGSize(width: 400, height: 200)
        let brush = try stroke(PatternInk(pattern: bayer4, dynamics: dynamics), size: size)
        let samples = (0...32).map { index in
            let t = CGFloat(index) / 32
            return BrushSample(point: CGPoint(x: 40 + 320 * t, y: 100), pressure: 0.05 + 0.95 * t)
        }
        try brush.append(samples)
        try brush.flush()
        let painted = try raster(brush, size: size)
        func share(_ columns: Range<Int>) -> Double {
            let pixels = columns.flatMap { x in (90..<110).map { y in (x, y) } }
            return Double(pixels.filter { rgba(painted, $0.0, $0.1)[3] == 255 }.count) / Double(pixels.count)
        }
        let light = share(60..<100), middle = share(180..<220), firm = share(320..<360)
        #expect(light < middle && middle < firm, "\(light) \(middle) \(firm)")
        #expect(light < 0.3 && firm > 0.8)
    }

    @Test func foregroundToBackgroundPaintsTheGaps() throws {
        let brush = try stroke(ink(density: 0.5, colors: .foregroundToBackground))
        try dab(brush)
        let painted = try raster(brush)
        for (x, y) in interior {
            let pixel = rgba(painted, x, y)
            #expect(pixel == (bayer4.isOn(x: x, y: y, density: 0.5) ? [255, 0, 0, 255] : [0, 0, 255, 255]), "\(x), \(y)")
        }
    }

    @Test func erasingClearsThePattern() throws {
        let brush = try stroke(ink(density: 0.25), erasing: true)
        try dab(brush)
        let painted = try raster(brush)
        var cleared = 0
        for (x, y) in interior {
            let alpha = rgba(painted, x, y)[3]
            #expect(alpha == (bayer4.isOn(x: x, y: y, density: 0.25) ? 0 : 255), "\(x), \(y)")
            if alpha == 0 { cleared += 1 }
        }
        #expect(cleared == interior.count / 4)
    }

    /// The pattern belongs to the document's pixels, so strokes on layers placed differently interlock.
    @Test func thePatternIsLinedUpOnTheDocument() throws {
        let brush = try stroke(ink(density: 0.5), origin: CGPoint(x: 3, y: 5))
        try dab(brush)
        let painted = try raster(brush)
        for (x, y) in interior {
            #expect((rgba(painted, x, y)[3] == 255) == bayer4.isOn(x: x, y: y, density: 0.5), "\(x), \(y)")
        }
    }

    /// The Brush, set to the built-in plugin's Dither brush, paints its pattern: Bayer 4 × 4 at half density to begin
    /// with, a mouse pressing at full.
    @Test func theBrushPaintsWithThePluginsDitherBrush() async throws {
        await PluginRegistry.shared.reload()
        let session = EditorSession()
        session.createDocument(width: 200, height: 200)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushKind = "com.compositor.dither-brush/dither"
        #expect(session.symbol(for: .brush) == "circle.grid.3x3.fill")
        session.brushSettings.diameter = 80
        session.brushSettings.hardness = 0
        session.beginBrush(at: CGPoint(x: 100, y: 100))
        let stroke = try #require(session.brushStroke)
        try stroke.flush()
        let painted = try raster(stroke)
        for (x, y) in interior {
            #expect((rgba(painted, x, y)[3] == 255) == bayer4.isOn(x: x, y: y, density: 0.5), "\(x), \(y)")
        }
        await session.finishBrush()
        // Its plugin gone, the Brush goes back to its own round brush.
        session.brushKind = "com.example.gone/brush"
        #expect(session.pluginBrush == nil)
        #expect(session.symbol(for: .brush) == NavigationTool.brush.symbol)
    }

    /// Aseprite's rule: a pixel is on once the density reaches (its number + 1) / (the largest + 2).
    @Test func matricesFollowAseprite() throws {
        let pattern = try #require(DitherPattern(matrix: [[0, 2], [3, 1]]))
        let fifths: [Float] = [1, 3, 4, 2].map { $0 / 5 }
        #expect(pattern.thresholds == fifths)
        #expect(!pattern.isOn(x: 0, y: 0, density: 0))
        for (x, y) in [(0, 0), (1, 0), (0, 1), (1, 1)] { #expect(pattern.isOn(x: x, y: y, density: 1)) }
        #expect(pattern.isOn(x: -2, y: -2, density: 0.2))
        #expect(!pattern.isOn(x: -1, y: -2, density: 0.5))
        #expect(DitherPattern(matrix: []) == nil)
        #expect(DitherPattern(matrix: [[0, 1], [2]]) == nil)
        #expect(DitherPattern(matrix: Array(repeating: Array(repeating: 0, count: 65), count: 2)) == nil)
    }
}
