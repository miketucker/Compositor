import AppKit
import Testing
@testable import Compositor

/// A stroke that follows the Pencil's pressure holds each sample for the force UIKit measures (see
/// `HeldBrushSamples`), corrects the first dab in place, and at the lift fades what's still held along the way the
/// Pencil went — rather than jumping back to the estimate or running on at it.
@MainActor
struct HeldBrushPressureTests {
    private func session() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 400, height: 400)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 60, hardness: 1, red: 1, green: 1, blue: 1, opacity: 1)
        session.brushPressure = .size
        return session
    }

    /// A stroke begun the way `beginBrush` leaves a pressure-following one: its first dab drawn at the estimate's
    /// shown pressure, and the samples about to come held for their measured forces. (`beginBrush` itself never
    /// follows pressure on the Mac — it reserves that for a tablet's plugin brushes — so the stroke's made directly.)
    private func beginStroke(_ session: EditorSession, at start: CGPoint = CGPoint(x: 40, y: 200),
                             display: CGFloat = 0.02, estimate: Int = 100,
                             pressure: BrushPressure = .size, smoothing: CGFloat = 0) throws -> BrushStroke {
        var settings = session.brushSettings
        settings.pressure = pressure
        let stroke = try session.makeRasterEdit(for: try #require(session.activeLayer), settings: settings)
        try stroke.append(start, pressure: display)
        session.brushStroke = stroke
        session.brushStabilizer = smoothing > 0
            ? BrushStabilizer(start: BrushSample(point: start, pressure: display), smoothing: smoothing,
                              zoom: session.viewport.zoom) : nil
        session.heldBrush = stroke.followsPressure
            ? HeldBrushSamples(start: BrushSample(point: start, pressure: display, estimate: estimate)) : nil
        session.lastBrushPoint = (start, stroke.layer.id, false)
        return stroke
    }

    /// Along y = 200, from `x0` to `x1` in steps of 10, shown at `display` and awaiting estimates running on from
    /// `first`.
    private func drag(_ session: EditorSession, from x0: Int = 50, to x1: Int = 360,
                      display: CGFloat = 0.02, firstEstimate: Int = 101) {
        let samples = stride(from: x0, through: x1, by: 10).map {
            BrushSample(point: CGPoint(x: $0, y: 200), pressure: display, estimate: firstEstimate + ($0 - x0) / 10)
        }
        session.continueBrush(at: samples)
    }

    /// A measured force of `pressure` for every estimate in `range` (100 is the start's; the drag's run on from 101).
    private func correct(_ session: EditorSession, _ range: ClosedRange<Int>, to pressure: CGFloat = 1) {
        session.correctBrush(range.map { (estimate: $0, pressure: pressure) })
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

    @Test func correctedForcesAreWhatTheStrokeKeeps() throws {
        let session = try session()
        let stroke = try beginStroke(session)
        drag(session)
        correct(session, 100...132)
        #expect(session.finishBrushImmediately())
        let painted = try raster(stroke)
        #expect(abs(thickness(painted, at: 200) - 60) <= 2)
        #expect(abs(thickness(painted, at: 340) - 60) <= 2)
    }

    @Test func whatIsStillHeldAtTheLiftFadesAlongTheWayItWent() throws {
        let session = try session()
        let stroke = try beginStroke(session)
        drag(session)
        // Certain as far as x = 250; the run from 260 on is still showing its estimates when the Pencil lifts.
        correct(session, 100...121)
        #expect(session.finishBrushImmediately())
        let painted = try raster(stroke)
        #expect(abs(thickness(painted, at: 200) - 60) <= 2)
        let at280 = thickness(painted, at: 280), at320 = thickness(painted, at: 320), at350 = thickness(painted, at: 350)
        #expect(at280 < 60 && at280 > at320 && at320 > at350, "\(at280) \(at320) \(at350)")
        #expect(at350 < 15, "faded to a sliver by the end: \(at350)")
    }

    @Test func theFadeIsTheLiftNotTheEstimateShown() throws {
        let session = try session()
        let stroke = try beginStroke(session)
        // The held run's estimates were shown at full pressure; the fade writes over them all the same.
        drag(session, display: 1)
        correct(session, 100...121)
        #expect(session.finishBrushImmediately())
        let painted = try raster(stroke)
        #expect(abs(thickness(painted, at: 200) - 60) <= 2)
        let at350 = thickness(painted, at: 350)
        #expect(at350 < 15, "the full-size estimates didn't stand: \(at350)")
    }

    @Test func aStrokeNotFollowingPressureDrawsAsItEverDid() throws {
        let session = try session()
        session.brushPressure = []
        session.beginBrush(at: CGPoint(x: 40, y: 200), pressure: 1, estimate: 100)
        let stroke = try #require(session.brushStroke)
        #expect(session.heldBrush == nil)
        session.continueBrush(at: stride(from: 50, through: 360, by: 10).map {
            BrushSample(point: CGPoint(x: $0, y: 200), pressure: 1, estimate: 100 + $0 / 10)
        })
        #expect(session.finishBrushImmediately())
        let painted = try raster(stroke)
        #expect(abs(thickness(painted, at: 340) - 60) <= 2)
    }

    @Test func theFirstDabsCorrectionSetsItsPressure() throws {
        let session = try session()
        // A tap that only ever estimated: the dot takes the measured force, not a raise from what was shown.
        let light = try beginStroke(session, at: CGPoint(x: 150, y: 200), display: 0.02, estimate: 100)
        session.correctBrush([(estimate: 100, pressure: 1)])
        #expect(session.finishBrushImmediately())
        #expect(abs(thickness(try raster(light), at: 150) - 60) <= 2)

        let firm = try beginStroke(session, at: CGPoint(x: 300, y: 200), display: 1, estimate: 100)
        session.correctBrush([(estimate: 100, pressure: 0.2)])
        #expect(session.finishBrushImmediately())
        #expect(abs(thickness(try raster(firm), at: 300) - 12) <= 2, "set, not raised")
    }

    @Test func smoothingStillSettlesTheLine() throws {
        let session = try session()
        session.brushSettings.smoothing = 40
        let stroke = try beginStroke(session, smoothing: 40)
        drag(session)
        correct(session, 100...132)
        #expect(session.finishBrushImmediately())
        #expect(abs(thickness(try raster(stroke), at: 200) - 60) <= 2)
    }
}
