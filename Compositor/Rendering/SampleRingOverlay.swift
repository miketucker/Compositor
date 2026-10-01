import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Display-only comparison: new sample above, pre-drag color below.
final class SampleRingOverlay: CanvasOverlayView {
    var original = PaletteColor.black
    var sampled = PaletteColor.black
    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: CGRect) {
        guard let context = PlatformGraphics.currentContext else { return }
        let ring = bounds.insetBy(dx: 15, dy: 15)
        context.setLineWidth(24)
        context.setStrokeColor(CGColor(genericGrayGamma2_2Gray: 0.45, alpha: 1))
        context.strokeEllipse(in: ring)
        context.setLineWidth(16)
        for (color, y) in [(sampled, CGFloat(0)), (original, bounds.midY)] {
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: y, width: bounds.width, height: bounds.height / 2))
            context.setStrokeColor(color.cgColor)
            context.strokeEllipse(in: ring)
            context.restoreGState()
        }
    }
}
