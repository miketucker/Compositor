#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A transparent view over the canvas that draws with Core Graphics, top-down, and never takes a click or a touch:
/// the canvas under it handles those.
class CanvasOverlayView: PlatformView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        #if !os(macOS)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        #endif
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    #if os(macOS)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
}
