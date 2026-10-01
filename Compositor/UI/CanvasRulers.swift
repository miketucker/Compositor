import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum CanvasRuler {
    static let thickness: CGFloat = 18
}

struct CanvasRulerCorner: View {
    var body: some View {
        Rectangle()
            .fill(Color(white: 0.2))
            .overlay(alignment: .bottomTrailing) {
                Path { path in
                    path.move(to: CGPoint(x: 5, y: CanvasRuler.thickness - 4))
                    path.addLine(to: CGPoint(x: CanvasRuler.thickness - 4, y: 5))
                }
                .stroke(Color.white.opacity(0.28), lineWidth: 1)
            }
            .frame(width: CanvasRuler.thickness, height: CanvasRuler.thickness)
    }
}

#if os(macOS)
struct CanvasRulerView: NSViewRepresentable {
    let session: EditorSession
    let axis: CanvasGuide.Axis

    func makeNSView(context: Context) -> CanvasRulerStrip {
        CanvasRulerStrip(session: session, axis: axis)
    }

    func updateNSView(_ view: CanvasRulerStrip, context: Context) {
        view.session = session
        view.axis = axis
        _ = session.viewport
        _ = session.document?.id
        _ = session.document?.size
        view.needsDisplay = true
    }
}
#else
struct CanvasRulerView: UIViewRepresentable {
    let session: EditorSession
    let axis: CanvasGuide.Axis

    func makeUIView(context: Context) -> CanvasRulerStrip {
        CanvasRulerStrip(session: session, axis: axis)
    }

    func updateUIView(_ view: CanvasRulerStrip, context: Context) {
        view.session = session
        view.axis = axis
        _ = session.viewport
        _ = session.document?.id
        _ = session.document?.size
        view.needsDisplay = true
    }
}
#endif

/// A ruler along the canvas's top or left edge, in document pixels. Dragging out of it makes a guide.
final class CanvasRulerStrip: PlatformView {
    var session: EditorSession
    var axis: CanvasGuide.Axis

    init(session: EditorSession, axis: CanvasGuide.Axis) {
        self.session = session
        self.axis = axis
        super.init(frame: .zero)
        let label = axis == .horizontal ? "Horizontal ruler" : "Vertical ruler"
        #if os(macOS)
        setAccessibilityElement(true)
        setAccessibilityRole(.unknown)
        setAccessibilityLabel(label)
        #else
        isAccessibilityElement = true
        accessibilityLabel = label
        contentMode = .redraw
        isOpaque = true
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    #if os(macOS)
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    private var screenScale: CGFloat { window?.backingScaleFactor ?? 1 }
    #else
    private var screenScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }
    #endif

    override func draw(_ dirtyRect: CGRect) {
        guard let context = PlatformGraphics.currentContext else { return }
        context.setFillColor(CGColor(genericGrayGamma2_2Gray: 0.2, alpha: 1))
        context.fill(bounds)
        guard let document = session.document else { return }
        let size = document.size
        let scale = session.viewport.pointsPerPixel
        let step = Self.majorStep(pointsPerPixel: scale)
        let minor = step / 10
        let hairline = 1 / max(screenScale, 1)
        let tick = CGColor(genericGrayGamma2_2Gray: 0.62, alpha: 1)
        let labels = PlatformColor(white: 0.78, alpha: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: labels
        ]

        let start: CGFloat
        let end: CGFloat
        if axis == .horizontal {
            start = session.viewport.documentPoint(from: CGPoint(x: 0, y: 0), documentSize: size).x
            end = session.viewport.documentPoint(from: CGPoint(x: bounds.width, y: 0), documentSize: size).x
        } else {
            start = session.viewport.documentPoint(from: CGPoint(x: 0, y: 0), documentSize: size).y
            end = session.viewport.documentPoint(from: CGPoint(x: 0, y: bounds.height), documentSize: size).y
        }
        let first = floor(min(start, end) / minor) * minor
        let last = ceil(max(start, end) / minor) * minor
        guard minor > 0, last.isFinite, first.isFinite else { return }

        var value = first
        while value <= last + 0.001 {
            let view: CGFloat
            if axis == .horizontal {
                view = session.viewport.viewPoint(from: CGPoint(x: value, y: 0), documentSize: size).x
            } else {
                view = session.viewport.viewPoint(from: CGPoint(x: 0, y: value), documentSize: size).y
            }
            let remainder = abs(value.remainder(dividingBy: step))
            let isMajor = remainder < 0.001 || abs(remainder - step) < 0.001
            let isMid = !isMajor && (abs(value.remainder(dividingBy: step / 2)) < 0.001)
            let length: CGFloat = isMajor ? 8 : isMid ? 5 : 3
            context.setFillColor(tick)
            if axis == .horizontal {
                context.fill(CGRect(x: view - hairline / 2, y: bounds.height - length, width: hairline, height: length))
            } else {
                context.fill(CGRect(x: bounds.width - length, y: view - hairline / 2, width: length, height: hairline))
            }
            if isMajor {
                let text = Self.label(value)
                let drawn = text.size(withAttributes: attributes)
                if axis == .horizontal {
                    text.draw(at: CGPoint(x: view + 2, y: 0), withAttributes: attributes)
                } else {
                    // Vertical labels sit along the tick, rotated so they read downward.
                    context.saveGState()
                    context.translateBy(x: 1, y: view + 2)
                    context.rotate(by: -.pi / 2)
                    text.draw(at: CGPoint(x: -drawn.width, y: 0), withAttributes: attributes)
                    context.restoreGState()
                }
            }
            value += minor
        }
        context.setFillColor(CGColor(genericGrayGamma2_2Gray: 0.08, alpha: 1))
        if axis == .horizontal {
            context.fill(CGRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline))
        } else {
            context.fill(CGRect(x: bounds.width - hairline, y: 0, width: hairline, height: bounds.height))
        }
    }

    #if os(macOS)
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(canvasView())
        guard session.canEditGuides, let position = documentPosition(for: event) else { return }
        session.beginGuideCreation(axis: axis, at: position)
        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard session.guideDrag != nil, let position = documentPosition(for: event) else { return }
        session.moveGuideDrag(to: position)
        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }

    override func mouseUp(with event: NSEvent) {
        guard session.guideDrag != nil else { return }
        session.finishGuideDrag(delete: isOverRuler(event))
        NSCursor.arrow.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: axis == .vertical ? .resizeLeftRight : .resizeUpDown)
    }

    private func canvasView() -> CanvasView? {
        func find(_ view: NSView) -> CanvasView? {
            if let canvas = view as? CanvasView { return canvas }
            return view.subviews.compactMap(find).first
        }
        return window?.contentView.flatMap(find)
    }

    private func documentPosition(for event: NSEvent) -> Double? {
        guard let canvas = canvasView() else { return nil }
        let point = canvas.convert(event.locationInWindow, from: nil)
        return canvas.documentPosition(axis: axis, at: point)
    }

    private func isOverRuler(_ event: NSEvent) -> Bool {
        guard let canvas = canvasView() else { return true }
        return canvas.isOverRuler(canvas.convert(event.locationInWindow, from: nil))
    }
    #else
    /// Dragging out of the ruler makes a guide; letting go back over the ruler drops it.
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard let canvas = canvasView() else { return }
        let point = gesture.location(in: canvas)
        switch gesture.state {
        case .began:
            guard session.canEditGuides, let position = canvas.documentPosition(axis: axis, at: point) else { return }
            session.beginGuideCreation(axis: axis, at: position)
        case .changed:
            guard session.guideDrag != nil, let position = canvas.documentPosition(axis: axis, at: point) else { return }
            session.moveGuideDrag(to: position)
        default:
            guard session.guideDrag != nil else { return }
            session.finishGuideDrag(delete: gesture.state == .cancelled || canvas.isOverRuler(point))
        }
    }

    private func canvasView() -> CanvasView? {
        func find(_ view: UIView) -> CanvasView? {
            if let canvas = view as? CanvasView { return canvas }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.flatMap(find)
    }
    #endif

    /// Numbered ticks about 70 points apart, using 1-2-5 steps in document pixels.
    static func majorStep(pointsPerPixel: CGFloat) -> CGFloat {
        let target = 70 / max(pointsPerPixel, 0.0001)
        let nice: [CGFloat] = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1_000, 2_000, 2_500, 5_000, 10_000, 20_000, 25_000]
        return nice.first { $0 >= target } ?? 50_000
    }

    static func label(_ value: CGFloat) -> NSString {
        let rounded = value.rounded()
        return (rounded == 0 ? "0" : String(Int(rounded))) as NSString
    }
}
