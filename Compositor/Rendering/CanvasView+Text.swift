import CoreGraphics
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The Type tool's gestures on the canvas that don't involve the text editor itself: dragging out a new text box.
extension CanvasView {
    func dragTextGesture(to point: CGPoint) {
        guard let anchor = textBoxAnchor, let document = session.document else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        textBoxRect = DragBox.rect(from: anchor, to: pixel, square: false, fromCenter: false)
        needsDisplay = true
    }

    func finishTextGesture() {
        guard let rect = textBoxRect else { return }
        textBoxAnchor = nil; textBoxRect = nil
        if rect.width < 4 && rect.height < 4 { session.beginText(at: rect.origin, newLayer: true) }
        else { session.beginText(in: rect) }
        synchronizeInlineText()
        needsDisplay = true
    }

    func drawTextBoxDraft() {
        guard let rect = textBoxRect, let document = session.document else { return }
        let origin = session.viewport.viewPoint(from: rect.origin, documentSize: document.size)
        let scale = session.viewport.pointsPerPixel
        guard let context = PlatformGraphics.currentContext else { return }
        context.setStrokeColor(PlatformColor.accent.cgColor)
        context.setLineWidth(1)
        context.stroke(CGRect(origin: origin, size: CGSize(width: rect.width * scale, height: rect.height * scale)))
    }
}
