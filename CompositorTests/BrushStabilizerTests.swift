import AppKit
import Testing
@testable import Compositor

/// Smoothing that redraws the line behind the Pencil rather than trailing it: the line always reaches the Pencil,
/// what's behind it is averaged out as the line runs on, and nothing moves while the Pencil rests or once it lifts.
@MainActor
struct BrushStabilizerTests {
    private func stabilizer(reach: CGFloat = 20, spacing: CGFloat = 1) -> BrushStabilizer {
        BrushStabilizer(start: BrushSample(point: CGPoint(x: 0, y: 100)), reach: reach, spacing: spacing)
    }

    /// Along y = 100 to `length`, zigzagging `wobble` either side every 2 pixels.
    private func draw(_ stabilizer: BrushStabilizer, to length: Int, wobble: CGFloat = 0) {
        for x in stride(from: 2, through: length, by: 2) {
            stabilizer.add(BrushSample(point: CGPoint(x: CGFloat(x), y: 100 + (x % 4 == 0 ? wobble : -wobble))))
        }
    }

    @Test func theLineAlwaysReachesThePencil() {
        let line = stabilizer()
        draw(line, to: 50)
        line.add(BrushSample(point: CGPoint(x: 50.5, y: 103)))
        let drawn = line.take()
        #expect(drawn.provisional.last?.point == CGPoint(x: 50.5, y: 103))
    }

    @Test func aWobbleIsAveragedOutOnceTheLineRunsPastIt() throws {
        let line = stabilizer()
        draw(line, to: 200, wobble: 3)
        let settled = line.take().settled
        // Everything a full reach (along the zigzag) behind the end has settled, from right beside where it began.
        #expect((180...200).contains(settled.last?.point.x ?? 0))
        let first = try #require(settled.first)
        #expect(hypot(first.point.x, first.point.y - 100) < 2)
        let middle = settled.filter { $0.point.x >= 30 && $0.point.x <= 170 }
        #expect(!middle.isEmpty)
        #expect(middle.allSatisfy { abs($0.point.y - 100) < 0.3 }, "Smoothed to well within the ±3 it wobbled")
    }

    @Test func aStraightLineStaysStraight() {
        let line = stabilizer()
        for step in 1...100 { line.add(BrushSample(point: CGPoint(x: CGFloat(step) * 3, y: 100 + CGFloat(step) * 1.5))) }
        let drawn = line.take()
        for sample in drawn.settled + drawn.provisional {
            #expect(abs(sample.point.y - (100 + sample.point.x / 2)) < 0.01)
        }
    }

    @Test func restingChangesNothingAndLiftingKeepsWhatsShown() throws {
        let line = stabilizer()
        draw(line, to: 100, wobble: 2)
        let shown = line.take()
        // Held still: the same sample over and over.
        for _ in 0..<30 { line.add(BrushSample(point: CGPoint(x: 100, y: 102))) }
        let held = line.take()
        #expect(held.settled.isEmpty)
        #expect(held.provisional.map(\.point) == shown.provisional.map(\.point))
        // Lifted: what was provisional settles where it was drawn, out to where the Pencil lifted.
        let lifted = line.take(finishing: true)
        #expect(lifted.settled.map(\.point) == shown.provisional.map(\.point))
        #expect(line.take(finishing: true).settled.isEmpty, "Nothing left once it's all settled")
    }

    @Test func pressureIsSmoothedAlongWithThePosition() {
        let line = stabilizer()
        for x in stride(from: 2, through: 200, by: 2) {
            line.add(BrushSample(point: CGPoint(x: CGFloat(x), y: 100), pressure: x % 4 == 0 ? 0.8 : 0.4))
        }
        let middle = line.take().settled.filter { $0.point.x >= 30 && $0.point.x <= 170 }
        #expect(middle.allSatisfy { abs($0.pressure - 0.6) < 0.05 })
    }

    @Test func aSmoothedStrokePaintsUpToThePointer() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 400)
        session.addBlankLayer()
        session.selectTool(.brush)
        session.brushSettings.smoothing = 40
        session.beginBrush(at: CGPoint(x: 100, y: 200))
        session.continueBrush(at: CGPoint(x: 300, y: 200))
        #expect(session.brushStabilizer != nil)
        #expect(session.lastBrushPoint?.point == CGPoint(x: 300, y: 200))
        #expect(session.finishBrushImmediately())
        #expect(session.brushStabilizer == nil)
        let layer = try #require(session.activeLayer)
        #expect(layer.asset != nil, "The stroke was committed")
    }
}
