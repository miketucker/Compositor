import Foundation
import Testing
@testable import Compositor

/// The Pencil's pressure through a press, as UIKit first estimates then corrects it (see `PencilPressure`): a force
/// still awaiting its correction is never drawn, so a stroke starts as a sliver and grows to the pressure measured.
@MainActor
struct PencilPressureTests {
    private func eased(_ force: CGFloat) -> CGFloat { PencilPressure.eased(force: force, maximum: 4) }

    @Test func easingMatchesTheBrushsCurve() {
        // Written as the old `pressure(of:)` computed it.
        #expect(abs(PencilPressure.eased(force: 1.2, maximum: 4) - sqrt(1.2 / (4 * 0.6))) < 0.0001)
        #expect(PencilPressure.eased(force: 0, maximum: 4) == 0)
        // 2.4 is the nominal top, but 4 * 0.6 lands a hair above it in floating point: just short of 1 there, at 1 past it.
        #expect(abs(PencilPressure.eased(force: 2.4, maximum: 4) - 1) < 0.0001)
        #expect(PencilPressure.eased(force: 2.5, maximum: 4) == 1)
        #expect(PencilPressure.eased(force: 4, maximum: 4) == 1)
    }

    @Test func aPressStartsAtItsLightestUntilAForceIsMeasured() {
        var press = PencilPressure()
        let first = press.sample(force: 4, maximum: 4, estimate: 10)
        let second = press.sample(force: 4, maximum: 4, estimate: 11)
        let measured = press.sample(force: 1.2, maximum: 4, estimate: nil)
        let after = press.sample(force: 4, maximum: 4, estimate: 12)
        #expect(first == BrushStroke.minimumPressure)
        #expect(second == BrushStroke.minimumPressure)
        #expect(measured == eased(1.2))
        // An estimate after that doesn't move it: the pressure measured stands.
        #expect(after == eased(1.2))
    }

    @Test func aCorrectionCarriesThePressOn() {
        var press = PencilPressure()
        _ = press.sample(force: 4, maximum: 4, estimate: 10)
        _ = press.sample(force: 4, maximum: 4, estimate: 11)
        let corrected = press.update(force: 0.6, maximum: 4, estimate: 10)
        let next = press.sample(force: 4, maximum: 4, estimate: 12)
        #expect(corrected)
        #expect(next == eased(0.6))
        #expect(press.predicted == eased(0.6))
    }

    @Test func aCorrectionFromAnEarlierPressIsIgnored() {
        var press = PencilPressure()
        _ = press.sample(force: 4, maximum: 4, estimate: 20)
        let stale = press.update(force: 0.6, maximum: 4, estimate: 19)
        #expect(!stale)
        #expect(press.predicted == BrushStroke.minimumPressure)
        // And a press whose samples were all measured corrects nothing at all.
        var measured = PencilPressure()
        let none = measured.update(force: 0.6, maximum: 4, estimate: 21)
        #expect(!none)
        #expect(measured.predicted == BrushStroke.minimumPressure)
    }

    @Test func aLateCorrectionDoesNotReplaceNewerMeasurements() {
        var press = PencilPressure()
        _ = press.sample(force: 4, maximum: 4, estimate: 10)
        _ = press.sample(force: 4, maximum: 4, estimate: 11)
        _ = press.sample(force: 4, maximum: 4, estimate: 12)
        let newest = press.update(force: 2, maximum: 4, estimate: 12)
        let late = press.update(force: 0.3, maximum: 4, estimate: 11)
        #expect(newest)
        #expect(!late)
        #expect(press.measured == eased(2))

        var measured = PencilPressure()
        _ = measured.sample(force: 4, maximum: 4, estimate: 10)
        _ = measured.sample(force: 2, maximum: 4, estimate: nil)
        let stale = measured.update(force: 0.3, maximum: 4, estimate: 10)
        #expect(!stale)
        #expect(measured.measured == eased(2))
    }

    @Test func aForceExpectingNoCorrectionIsTakenAsItIs() {
        var press = PencilPressure()
        let first = press.sample(force: 2, maximum: 4, estimate: nil)
        #expect(first == eased(2))
        #expect(press.predicted == eased(2))
    }

    @Test func predictedIsTheLatestPressureMeasured() {
        var press = PencilPressure()
        #expect(press.predicted == BrushStroke.minimumPressure)
        _ = press.sample(force: 4, maximum: 4, estimate: 10)
        #expect(press.predicted == BrushStroke.minimumPressure)
        _ = press.sample(force: 1.2, maximum: 4, estimate: nil)
        #expect(press.predicted == eased(1.2))
    }
}
