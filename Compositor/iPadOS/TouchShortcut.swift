import GameController
import SwiftUI
import UIKit

/// Whether a hardware keyboard is attached. With one, the Mac's keys work, so the status bar names them and the touch
/// shortcut steps aside.
@MainActor @Observable
final class HardwareKeyboard {
    static let shared = HardwareKeyboard()
    private(set) var isConnected = GCKeyboard.coalesced != nil
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HardwareKeyboard.shared.isConnected = true }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HardwareKeyboard.shared.isConnected = false }
        })
    }
}

/// Photoshop's touch shortcut, for working without a keyboard. Hold the circle and the canvas takes each press as if
/// Shift were held: adding to a selection, keeping a shape square, painting a straight line. Slide out to its edge
/// for Option: taking away from a selection, drawing from the center, setting the Clone Stamp's source. It lets go
/// when the thumb does.
struct TouchShortcut: UIViewRepresentable {
    static let size: CGFloat = 76
    func makeUIView(context: Context) -> TouchShortcutView { TouchShortcutView() }
    func updateUIView(_ view: TouchShortcutView, context: Context) {}
}

/// The circle itself: a UIKit view, so its touch is its own and the other hand's (the Pencil's, or a finger on the
/// canvas) goes on to the canvas at the same time.
final class TouchShortcutView: UIView {
    private var touch: UITouch?
    private var held: KeyModifiers = [] {
        didSet {
            guard held != oldValue else { return }
            HeldModifiers.shared.onScreen = held
            accessibilityValue = held.contains(.option) ? "Option" : held.contains(.shift) ? "Shift" : nil
            setNeedsDisplay()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Touch shortcut"
        accessibilityHint = "Hold for Shift. Slide to the edge for Option."
        accessibilityIdentifier = "touchShortcut"
        addInteraction(UIPointerInteraction())
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var outerRadius: CGFloat { min(bounds.width, bounds.height) / 2 - 1 }
    /// Inside this, Shift; outside, out to the rim and beyond, Option.
    private var innerRadius: CGFloat { outerRadius * 0.55 }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard touch == nil, let first = touches.first else { return }
        touch = first
        follow(first)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch, touches.contains(touch) else { return }
        follow(touch)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Put away mid-hold (a keyboard was attached): the keys it held go with it.
        if window == nil { touch = nil; held = [] }
    }

    private func follow(_ touch: UITouch) {
        let point = touch.location(in: self)
        held = hypot(point.x - bounds.midX, point.y - bounds.midY) > innerRadius ? .option : .shift
    }

    private func release(_ touches: Set<UITouch>) {
        guard let touch, touches.contains(touch) else { return }
        self.touch = nil
        held = []
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        func circle(_ radius: CGFloat) -> CGRect {
            CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        }
        let option = held.contains(.option), shift = held.contains(.shift)
        context.setFillColor(UIColor(white: 0.08, alpha: 0.6).cgColor)
        context.fillEllipse(in: circle(outerRadius))
        let rim: CGFloat = option ? 3 : 1
        context.setStrokeColor((option ? UIColor.tintColor : UIColor(white: 1, alpha: 0.3)).cgColor)
        context.setLineWidth(rim)
        context.strokeEllipse(in: circle(outerRadius - rim / 2))
        context.setFillColor((shift ? UIColor.tintColor : UIColor(white: 1, alpha: 0.2)).cgColor)
        context.fillEllipse(in: circle(innerRadius))
        label("⇧", size: 17, at: center, emphasized: shift)
        label("⌥", size: 11, at: CGPoint(x: center.x, y: center.y - (outerRadius + innerRadius) / 2), emphasized: option)
    }

    private func label(_ text: String, size: CGFloat, at point: CGPoint, emphasized: Bool) {
        let string = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: UIColor(white: 1, alpha: emphasized ? 1 : 0.75),
        ])
        let box = string.size()
        string.draw(at: CGPoint(x: point.x - box.width / 2, y: point.y - box.height / 2))
    }
}

