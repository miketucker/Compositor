import AppKit
import Testing
@testable import Compositor

/// A Pencil's lift isn't part of the stroke: where it left the glass — off the line, its force already gone — nothing
/// is painted (see `CanvasPointer.isLiftOff`). Any other release still reaches its own point, as it ever did.
@MainActor
struct LiftOffTests {
    private func canvas() throws -> (session: EditorSession, view: CanvasView) {
        let session = EditorSession()
        session.createDocument(width: 400, height: 400)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings = BrushSettings(diameter: 20, hardness: 1, red: 1, green: 1, blue: 1, opacity: 1)
        session.brushPressure = []
        let view = CanvasView(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = view
        session.viewport.resize(to: view.bounds.size, backingScale: 1, documentSize: try #require(session.document?.size))
        session.zoom(to: 1)
        view.synchronizeDisplay()
        return (session, view)
    }

    /// `point` in document pixels, as the canvas event that lands there.
    private func press(_ session: EditorSession, at point: CGPoint, liftOff: Bool = false) throws -> CanvasPointer {
        let spot = session.viewport.viewPoint(from: point, documentSize: try #require(session.document?.size))
        return CanvasPointer(location: spot, pressure: 1, isLiftOff: liftOff)
    }

    private func alpha(_ context: CGContext, _ x: Int, _ y: Int) -> Int {
        Int(context.data!.assumingMemoryBound(to: UInt8.self)[y * context.bytesPerRow + x * 4 + 3])
    }

    private func painted(_ stroke: BrushStroke) throws -> CGContext {
        let context = try BrushRaster.context(width: 400, height: 400, mask: false)
        LayerRenderer.drawBrushPreview(nil, transform: stroke.paintTransform, center: stroke.paintTransform.center,
            scale: 1, opacity: 1, blendMode: .normal, mask: nil, patches: stroke.patches,
            pixelWidth: stroke.width, pixelHeight: stroke.height, paintingMask: false, in: context)
        return context
    }

    @Test func aPencilsLiftDoesNotPaintWhereItLeftTheGlass() throws {
        let (session, view) = try canvas()
        view.pointerDown(try press(session, at: CGPoint(x: 100, y: 200)))
        view.pointerDragged(try press(session, at: CGPoint(x: 200, y: 200)))
        let stroke = try #require(session.brushStroke)
        // Lifted off away from the line: the stroke ends where the Pencil stopped moving.
        view.pointerUp(try press(session, at: CGPoint(x: 200, y: 260), liftOff: true))
        #expect(session.brushStroke == nil)
        let image = try painted(stroke)
        #expect(alpha(image, 150, 200) > 0)
        #expect(alpha(image, 200, 250) == 0, "nothing is drawn toward where it lifted")
    }

    @Test func anyOtherReleaseStillReachesItsPoint() throws {
        let (session, view) = try canvas()
        view.pointerDown(try press(session, at: CGPoint(x: 100, y: 200)))
        view.pointerDragged(try press(session, at: CGPoint(x: 200, y: 200)))
        let stroke = try #require(session.brushStroke)
        view.pointerUp(try press(session, at: CGPoint(x: 200, y: 260)))
        let image = try painted(stroke)
        #expect(alpha(image, 200, 250) > 0, "a mouse or finger's release is where the stroke ends")
    }
}
