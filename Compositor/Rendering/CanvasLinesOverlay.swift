import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The lines drawn over the canvas's pixels — the pixel grid when zoomed far in, and the box a new text frame is being
/// dragged out as — in a layer of their own above them, so they look the same whether the GPU or Core Graphics draws
/// the pixels underneath (see `drawOnGPU`).
final class CanvasLinesOverlay: CanvasOverlayView {
    var drawLines: ((CGRect) -> Void)?
    override func draw(_ dirtyRect: CGRect) { drawLines?(dirtyRect) }
}
