import CoreGraphics
import Foundation

/// The Brush's Smoothing, as Procreate's StreamLine draws it: the stroke runs right up to the Pencil, and the stretch
/// behind it keeps being redrawn smoother as more of the line comes in, settling once the Pencil has moved on past it.
///
/// Each point of the line is averaged with its neighbors along the line, out to `reach` either side and weighted to
/// the nearest. Near either end of the line there's less of it to reach along, so the reach narrows to what there is:
/// the line starts where the Pencil touched down and ends where it is now, and the newest stretch is only lightly
/// smoothed until the line runs on past it. A point is settled once the line runs a full reach beyond it, since nothing
/// drawn after can change it. Holding still changes nothing, and lifting settles the line as it's shown.
final class BrushStabilizer {
    /// How far along the line the averaging reaches either side, in document pixels.
    let reach: CGFloat
    /// The line resampled at this even spacing: the averaging needs evenly spread points (the Pencil's bunch up where
    /// it slows), and this keeps the work the same however slowly the line is drawn.
    let spacing: CGFloat
    private var points: [BrushSample]
    /// How far along the line each of `points` is.
    private var lengths: [CGFloat] = [0]
    /// The Pencil's latest sample, between the even points, where the line ends for now.
    private var tip: BrushSample
    private var tipLength: CGFloat = 0
    /// How many of `points` the stroke has for good. The first, where the stroke began, it has from the start.
    private var settledCount = 1
    /// The Pencil has lifted and the line has all been handed over.
    private var finished = false

    /// `smoothing` is the Brush's setting, the reach in screen points; `zoom`, how many of those to a document pixel.
    convenience init(start: BrushSample, smoothing: CGFloat, zoom: CGFloat) {
        let reach = smoothing / max(0.01, zoom)
        self.init(start: start, reach: reach, spacing: max(reach / 20, 0.5 / max(0.01, zoom)))
    }

    init(start: BrushSample, reach: CGFloat, spacing: CGFloat) {
        self.reach = reach
        self.spacing = max(0.01, spacing)
        points = [start]
        tip = start
    }

    /// The start's measured pressure, where its force had only been estimated (see `HeldBrushSamples`): the first
    /// point's, and the tip's too while it's still the start — once the line has run on, the tip isn't the start's.
    func correctStart(pressure: CGFloat) {
        points[0].pressure = pressure
        if points.count == 1 && tipLength == 0 { tip.pressure = pressure }
    }

    /// The line goes on to `sample`.
    func add(_ sample: BrushSample) {
        guard sample.point.x.isFinite, sample.point.y.isFinite else { return }
        let dx = sample.point.x - tip.point.x, dy = sample.point.y - tip.point.y
        let length = hypot(dx, dy)
        guard length > 0 else {
            tip.pressure = sample.pressure
            return
        }
        var next = lengths[lengths.count - 1] + spacing
        while next <= tipLength + length {
            let t = (next - tipLength) / length
            points.append(BrushSample(point: CGPoint(x: tip.point.x + dx * t, y: tip.point.y + dy * t),
                                      pressure: tip.pressure + (sample.pressure - tip.pressure) * t))
            lengths.append(next)
            next += spacing
        }
        tip = sample
        tipLength += length
    }

    /// The points newly settled, for the stroke to keep, and the rest of the line as it stands, through to where the
    /// Pencil is, for the stroke to draw until the next call replaces it. `finishing`, the Pencil has lifted: all of it
    /// settles, as it's shown now.
    func take(finishing: Bool = false) -> (settled: [BrushSample], provisional: [BrushSample]) {
        guard !finished else { return ([], []) }
        finished = finishing
        var settled: [BrushSample] = [], provisional: [BrushSample] = []
        for index in settledCount..<points.count {
            let smoothed = smooth(index)
            // Points settle in order: the line has run on a full reach past each, or the stroke is over.
            if provisional.isEmpty, finishing || lengths[lengths.count - 1] - lengths[index] >= reach {
                settled.append(smoothed)
                settledCount = index + 1
            } else {
                provisional.append(smoothed)
            }
        }
        if tipLength > lengths[lengths.count - 1] {
            if finishing { settled.append(tip) } else { provisional.append(tip) }
        }
        return (settled, provisional)
    }

    /// The point at `index` averaged with its neighbors along the line, by a Gaussian over as much reach as both
    /// sides have.
    private func smooth(_ index: Int) -> BrushSample {
        // As far as the even points reach both ways, so the average is never pulled to one side.
        let here = lengths[index]
        let span = min(reach, here, lengths[lengths.count - 1] - here)
        guard span >= spacing else { return points[index] }
        let sigma = span / 2
        let steps = Int(span / spacing)
        var x: CGFloat = 0, y: CGFloat = 0, pressure: CGFloat = 0, total: CGFloat = 0
        for neighbor in max(0, index - steps)...min(points.count - 1, index + steps) {
            let distance = lengths[neighbor] - here
            let weight = exp(-distance * distance / (2 * sigma * sigma))
            x += points[neighbor].point.x * weight
            y += points[neighbor].point.y * weight
            pressure += points[neighbor].pressure * weight
            total += weight
        }
        return BrushSample(point: CGPoint(x: x / total, y: y / total), pressure: pressure / total)
    }
}
