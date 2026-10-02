import CoreGraphics
import Foundation

/// Stroke samples shown but not yet the stroke's for good. On iPad a Pencil's force arrives as an estimate UIKit
/// corrects a moment later (see `PencilPressure`), so a stroke that follows pressure draws each sample at its
/// estimate — along its provisional tail, where it's replaced as the line runs on — holds it for the measured force,
/// and hands it over once that lands. At the lift, whatever is still held fades out along the line the Pencil really
/// took, so a stroke ends the way it was lifted rather than snapping off or running on past it.
struct HeldBrushSamples {
    /// Held in the order taken; a sample's `estimate` clears once its correction is in.
    private(set) var samples: [BrushSample] = []
    /// What the stroke's first dab — already the stroke's — still awaits, if anything.
    private(set) var startEstimate: Int?
    /// The last sample the stroke has for good: its first dab to begin with.
    private(set) var settled: BrushSample
    /// Whether anything has come out yet, so `settled` still is the first dab.
    private var releasedAny = false

    init(start: BrushSample) {
        var first = start
        startEstimate = first.estimate
        first.estimate = nil
        settled = first
    }

    /// Held behind everything already held.
    mutating func hold(_ new: [BrushSample]) {
        samples += new
    }

    /// A measured force UIKit sent back for an estimate, as the pressure it eases to. True where it's the first dab's
    /// — the caller then corrects the stroke's and the stabilizer's start too; an estimate this press never held (an
    /// earlier press's, say) is ignored.
    mutating func correct(_ estimate: Int, pressure: CGFloat) -> Bool {
        if estimate == startEstimate {
            startEstimate = nil
            if !releasedAny { settled.pressure = pressure }
            return true
        }
        guard let index = samples.firstIndex(where: { $0.estimate == estimate }) else { return false }
        samples[index].estimate = nil
        samples[index].pressure = pressure
        return false
    }

    /// The front run whose forces are measured, in order, now the stroke's for good. Everything behind a sample still
    /// estimated stays held.
    mutating func release() -> [BrushSample] {
        let count = samples.prefix(while: { $0.estimate == nil }).count
        guard count > 0 else { return [] }
        let out = Array(samples.prefix(count))
        samples.removeFirst(count)
        settled = out[count - 1]
        releasedAny = true
        return out
    }

    /// Everything still held, now the press is over. What was already measured stands; the run still estimated fades
    /// out along the line the Pencil took, from the last pressure measured (its own samples', or the stroke's start
    /// where the run begins at once) down to nothing at the end — the stroke's sliver. Whatever the estimates showed
    /// is gone with them.
    mutating func releaseAll() -> [BrushSample] {
        var out = samples
        samples = []
        // The run still awaiting a measured force.
        let i0 = out.firstIndex(where: { $0.estimate != nil }) ?? out.count
        let origin = i0 > 0 ? out[i0 - 1] : settled
        let p0 = origin.pressure
        // How far along the line each held sample is, from the last certain point on.
        var distances = [CGFloat](repeating: 0, count: out.count)
        var total: CGFloat = 0
        var previous = origin.point
        for index in i0..<out.count {
            total += hypot(out[index].point.x - previous.x, out[index].point.y - previous.y)
            distances[index] = total
            previous = out[index].point
        }
        for index in i0..<out.count {
            // Smoothstepped, so the fade eases in from the pressure held and eases out to the lightest.
            let t = total > 0 ? 1 - distances[index] / total : 1
            out[index].pressure = p0 * t * t * (3 - 2 * t)
        }
        for index in out.indices { out[index].estimate = nil }
        if let last = out.last { settled = last }
        return out
    }
}
