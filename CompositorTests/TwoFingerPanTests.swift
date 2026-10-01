import CoreGraphics
import Testing
@testable import Compositor

struct TwoFingerPanTests {
    @Test func followsTheFingers() {
        var pan = TwoFingerPan(at: CGPoint(x: 100, y: 100), touches: 2)
        #expect(pan.move(to: CGPoint(x: 110, y: 95), touches: 2) == CGSize(width: 10, height: -5))
        #expect(pan.move(to: CGPoint(x: 130, y: 95), touches: 2) == CGSize(width: 20, height: 0))
    }

    /// The first of two fingers lifting: the point between them jumps to the one left, and the canvas stays put, as
    /// it does while that finger slides away.
    @Test func aFingerLiftingMovesNothing() {
        var pan = TwoFingerPan(at: CGPoint(x: 200, y: 200), touches: 2)
        _ = pan.move(to: CGPoint(x: 210, y: 200), touches: 2)
        #expect(pan.move(to: CGPoint(x: 360, y: 200), touches: 1) == .zero)
        #expect(pan.move(to: CGPoint(x: 400, y: 260), touches: 1) == .zero)
    }

    /// A finger joining, or coming back: the pan carries on from where the fingers are, without a jump.
    @Test func aFingerJoiningPicksUpFromThere() {
        var pan = TwoFingerPan(at: CGPoint(x: 200, y: 200), touches: 2)
        #expect(pan.move(to: CGPoint(x: 260, y: 240), touches: 3) == .zero)
        #expect(pan.move(to: CGPoint(x: 265, y: 240), touches: 3) == CGSize(width: 5, height: 0))
        _ = pan.move(to: CGPoint(x: 400, y: 240), touches: 1)
        #expect(pan.move(to: CGPoint(x: 300, y: 240), touches: 2) == .zero)
        #expect(pan.move(to: CGPoint(x: 290, y: 250), touches: 2) == CGSize(width: -10, height: 10))
    }

    /// A trackpad's two-finger scroll has no touches on the screen, and pans all the same.
    @Test func aTrackpadScrollPans() {
        var pan = TwoFingerPan(at: CGPoint(x: 50, y: 50), touches: 0)
        #expect(pan.move(to: CGPoint(x: 50, y: 80), touches: 0) == CGSize(width: 0, height: 30))
    }
}
