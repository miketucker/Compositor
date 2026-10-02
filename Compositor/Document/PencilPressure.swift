import CoreGraphics

/// How firmly the Pencil presses through one press on the canvas, 0–1, as the Brush follows it. The Pencil sends its
/// force over the air, so its samples reach the iPad with only an estimate of it, which UIKit corrects a moment later.
/// What a sample is shown at until the measured force arrives: the latest one measured rather than its estimate —
/// which lags — or, before any has landed, the press's lightest, so the stroke starts as a sliver and grows as the
/// Pencil presses. The stroke itself keeps the measured force once it's in (see `HeldBrushSamples`). A force UIKit
/// won't correct (a Pencil without pressure) is taken as it is.
struct PencilPressure {
    /// The latest pressure measured in this press, which is what everything still estimated is shown at.
    private(set) var measured: CGFloat?
    /// The first estimate of this press: corrections of earlier ones belong to an earlier press.
    private var firstEstimate: Int?
    /// The latest estimate this press has sampled.
    private var latestEstimate: Int?
    /// The estimate `measured` is as recent as: a correction of an earlier one, arriving late, is older news.
    private var measuredThrough: Int?

    /// `force` eased to 0–1, so an everyday touch lands past the middle and a firm one reaches the brush's full size
    /// well short of the Pencil's limit.
    static func eased(force: CGFloat, maximum: CGFloat) -> CGFloat {
        sqrt(min(1, max(0, force) / (maximum * 0.6)))
    }

    /// A sample of the press. `estimate` is its estimation update index where its force is only an estimate UIKit means
    /// to correct, and nil where the force is measured (or final).
    mutating func sample(force: CGFloat, maximum: CGFloat, estimate: Int?) -> CGFloat {
        guard let estimate else {
            let pressure = Self.eased(force: force, maximum: maximum)
            measured = pressure
            measuredThrough = latestEstimate
            return pressure
        }
        if firstEstimate == nil { firstEstimate = estimate }
        latestEstimate = estimate
        return measured ?? BrushStroke.minimumPressure
    }

    /// UIKit's correction of an estimate: the force measured for it, or the estimate itself where none is coming after
    /// all. True where the press now goes on at it.
    @discardableResult
    mutating func update(force: CGFloat, maximum: CGFloat, estimate: Int) -> Bool {
        guard let firstEstimate, estimate >= firstEstimate, estimate > (measuredThrough ?? firstEstimate - 1) else { return false }
        measuredThrough = estimate
        measured = Self.eased(force: force, maximum: maximum)
        return true
    }

    /// Where the Pencil is predicted to be next: at the latest pressure measured, since a prediction's own is a guess.
    var predicted: CGFloat { measured ?? BrushStroke.minimumPressure }
}
