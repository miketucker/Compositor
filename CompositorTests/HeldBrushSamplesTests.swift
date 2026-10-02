import Foundation
import Testing
@testable import Compositor

/// Samples a stroke shows at the Pencil's estimated pressure while it holds them for the measured force (see
/// `HeldBrushSamples`): released in order once certain, and faded along the way the Pencil lifted at the end.
@MainActor
struct HeldBrushSamplesTests {
    private func sample(_ x: CGFloat, _ pressure: CGFloat = 0.02, estimate: Int? = nil) -> BrushSample {
        BrushSample(point: CGPoint(x: x, y: 100), pressure: pressure, estimate: estimate)
    }

    @Test func releaseLetsGoOnlyTheMeasuredFrontRunInOrder() {
        var held = HeldBrushSamples(start: sample(0, estimate: 10))
        held.hold([sample(10, estimate: 11), sample(20, estimate: 12), sample(30, estimate: 13)])
        #expect(held.release().isEmpty, "Everything still awaits its correction")
        // Out of order: 13's force is in before 12's, but the run lets go in the order the line was drawn.
        _ = held.correct(13, pressure: 0.9)
        _ = held.correct(11, pressure: 0.5)
        let first = held.release()
        #expect(first.map(\.point.x) == [10])
        #expect(first.map(\.pressure) == [0.5])
        #expect(first.allSatisfy { $0.estimate == nil })
        #expect(held.settled.point.x == 10 && held.settled.pressure == 0.5)
        _ = held.correct(12, pressure: 0.7)
        let rest = held.release()
        #expect(rest.map(\.point.x) == [20, 30])
        #expect(rest.map(\.pressure) == [0.7, 0.9])
        #expect(held.samples.isEmpty)
    }

    @Test func anEstimateItNeverHeldIsIgnored() {
        var held = HeldBrushSamples(start: sample(0, estimate: 10))
        held.hold([sample(10, estimate: 11)])
        let took = held.correct(99, pressure: 0.9)
        #expect(!took)
        #expect(held.startEstimate == 10)
        #expect(held.samples.first?.estimate == 11)
        #expect(held.release().isEmpty)
    }

    @Test func correctingTheStartAnswersTrueAndSetsTheFirstDab() {
        var held = HeldBrushSamples(start: sample(0, estimate: 10))
        let took = held.correct(10, pressure: 0.8)
        #expect(took)
        #expect(held.startEstimate == nil)
        #expect(held.settled.pressure == 0.8, "Nothing released yet, so `settled` is still the first dab")
    }

    @Test func aLateStartCorrectionLeavesAnOlderSettledAlone() {
        var held = HeldBrushSamples(start: sample(0, estimate: 10))
        held.hold([sample(10, estimate: 11)])
        _ = held.correct(11, pressure: 0.5)
        _ = held.release()
        let wasStart = held.correct(10, pressure: 0.9)
        #expect(wasStart, "The dab itself still takes it — the stroke's start is corrected by the caller")
        #expect(held.settled.pressure == 0.5, "but `settled` has moved on past the start")
    }

    @Test func releaseAllFadesAlongTheWayItLifted() {
        var held = HeldBrushSamples(start: sample(0, estimate: nil))
        held.hold((1...8).map { sample(CGFloat($0) * 10, estimate: $0) })
        _ = held.correct(1, pressure: 0.6)
        _ = held.correct(2, pressure: 0.9)
        let out = held.releaseAll()
        #expect(out.count == 8)
        #expect(held.samples.isEmpty)
        #expect(out.allSatisfy { $0.estimate == nil })
        // What was measured comes out unchanged.
        #expect(out[0].pressure == 0.6 && out[1].pressure == 0.9)
        // From the last measured (0.9 at x = 20) the held run fades along the 60 points left, smoothstepped.
        #expect(out[2].pressure <= 0.9 && out[2].pressure > 0.75, "the first faded sample is close to where it was")
        for index in 3..<out.count {
            #expect(out[index].pressure < out[index - 1].pressure, "\(index): \(out[index].pressure)")
        }
        #expect(out.last?.pressure == 0, "ends at the stroke's lightest")
    }

    @Test func aHeldRunThatNeverMovedKeepsThePressureItHad() {
        var held = HeldBrushSamples(start: sample(0, 0.8))
        held.hold([sample(0, estimate: 1), sample(0, estimate: 2)])
        let out = held.releaseAll()
        // No line to fade along, so the lift stands at the pressure last measured.
        #expect(out.allSatisfy { $0.pressure == 0.8 })
    }
}
