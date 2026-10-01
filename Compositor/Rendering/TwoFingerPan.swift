import CoreGraphics

/// A two-finger pan as the canvas follows it, from the point between the fingers that UIKit reports. When a finger
/// lifts or joins, that point jumps to between the fingers down now, though none of them has moved; following it would
/// jump the canvas (by half the gap between the fingers, as the first of two lifts), so the pan picks up again from
/// there. Down to one finger, what's left is the fingers leaving, and the canvas stays where the two put it.
struct TwoFingerPan {
    private var point: CGPoint?
    private var touches: Int

    /// `touches` fingers came down, between them at `point`. A trackpad's scroll has none on the screen.
    init(at point: CGPoint, touches: Int) {
        self.point = point
        self.touches = touches
    }

    /// The fingers, `touches` of them now, are at `point`: how far the canvas moves.
    mutating func move(to point: CGPoint, touches: Int) -> CGSize {
        guard touches == self.touches else {
            self.touches = touches
            self.point = touches == 1 ? nil : point
            return .zero
        }
        guard let last = self.point else { return .zero }
        self.point = point
        return CGSize(width: point.x - last.x, height: point.y - last.y)
    }
}
