import AppKit
import Testing
@testable import Compositor

/// The Pencil's pressure along a stroke: narrower or fainter where it presses lightly, as the Brush is set to follow,
/// and no different from before where it isn't.
@MainActor
struct BrushPressureTests {
    private func stroke(_ pressure: BrushPressure, hardness: CGFloat = 1) throws -> BrushStroke {
        let session = EditorSession()
        session.createDocument(width: 400, height: 400)
        session.addBlankLayer()
        var settings = BrushSettings(diameter: 60, hardness: hardness, red: 1, green: 1, blue: 1, opacity: 1)
        settings.pressure = pressure
        return try BrushStroke(layer: #require(session.activeLayer), mask: false, settings: settings,
                               canvas: CGSize(width: 400, height: 400))
    }

    /// Across the canvas at y = 200, pressing from `light` at the left to `firm` at the right, in one batch as the
    /// Pencil's samples arrive.
    private func paint(_ stroke: BrushStroke, from light: CGFloat, to firm: CGFloat) throws {
        let samples = (0...32).map { index in
            let t = CGFloat(index) / 32
            return BrushSample(point: CGPoint(x: 40 + 320 * t, y: 200), pressure: light + (firm - light) * t)
        }
        try stroke.append(samples)
        try stroke.flush()
    }

    private func raster(_ stroke: BrushStroke) throws -> CGContext {
        let context = try BrushRaster.context(width: 400, height: 400, mask: false)
        LayerRenderer.drawBrushPreview(nil, transform: stroke.paintTransform, center: stroke.paintTransform.center,
            scale: 1, opacity: 1, blendMode: .normal, mask: nil, patches: stroke.patches,
            pixelWidth: stroke.width, pixelHeight: stroke.height, paintingMask: false, in: context)
        return context
    }

    private func alpha(_ context: CGContext, _ x: Int, _ y: Int) -> Int {
        Int(context.data!.assumingMemoryBound(to: UInt8.self)[y * context.bytesPerRow + x * 4 + 3])
    }

    /// How tall the paint is in column `x`: the rows at least half covered.
    private func thickness(_ context: CGContext, at x: Int) -> Int {
        (0..<400).filter { alpha(context, x, $0) >= 128 }.count
    }

    @Test func aLightTouchPaintsNarrower() throws {
        for hardness: CGFloat in [1, 0.5] {
            let brush = try stroke(.size, hardness: hardness)
            try paint(brush, from: 0.2, to: 1)
            let painted = try raster(brush)
            // At x = 80 the Pencil pressed at 0.3, at x = 340 at 0.95.
            let light = thickness(painted, at: 80), firm = thickness(painted, at: 340)
            #expect(firm > light * 2, "hardness \(hardness): \(light) then \(firm)")
            if hardness == 1 {
                #expect(abs(light - 18) <= 2)
                #expect(abs(firm - 57) <= 2)
            }
        }
    }

    @Test func withoutPressureTheBrushKeepsItsSize() throws {
        let brush = try stroke([])
        try paint(brush, from: 0.2, to: 1)
        let painted = try raster(brush)
        #expect(abs(thickness(painted, at: 80) - 60) <= 1)
        #expect(abs(thickness(painted, at: 340) - 60) <= 1)
    }

    @Test func opacityFollowsPressureAndSizeDoesNot() throws {
        let brush = try stroke(.opacity)
        try paint(brush, from: 0.2, to: 1)
        let painted = try raster(brush)
        #expect(alpha(painted, 80, 200) < alpha(painted, 340, 200) / 2)
        #expect(alpha(painted, 340, 200) >= 230)
        // Fainter, not narrower: paint still reaches the brush's full width where it's light.
        #expect(alpha(painted, 80, 200 + 27) > 0)
    }

    @Test func aTapTakesTheFirmestPressureBeforeItLifts() throws {
        let brush = try stroke(.size)
        try brush.append(CGPoint(x: 200, y: 200), pressure: 0.1)
        try brush.append(CGPoint(x: 200, y: 200), pressure: 0.6)
        try brush.append(CGPoint(x: 200, y: 200), pressure: 1)
        try brush.flush()
        #expect(abs(thickness(try raster(brush), at: 200) - 60) <= 2)
    }
}
