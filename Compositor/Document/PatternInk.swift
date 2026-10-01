import CoreGraphics

/// A dither pattern a brush can paint in: a grid of thresholds repeated across the document's pixels, each the density
/// at which its pixel turns on. Ordered, as Aseprite's dithering matrices are: a pixel that's on at one density is on
/// at every denser one, so pressing harder fills the pattern in rather than reshuffling it.
nonisolated struct DitherPattern: Sendable, Hashable {
    static let maxSide = 64
    let width: Int
    let height: Int
    /// Row by row, from the top left.
    let thresholds: [Float]

    /// From a dithering matrix as Aseprite reads one: rows of whole numbers, the lower turning on first. A pixel is on
    /// once the density reaches (its number + 1) / (the largest + 2), so none are on at no density and all at full.
    init?(matrix: [[Int]]) {
        guard let first = matrix.first, (1...Self.maxSide).contains(matrix.count), (1...Self.maxSide).contains(first.count),
              matrix.allSatisfy({ $0.count == first.count }), matrix.joined().allSatisfy({ $0 >= 0 }) else { return nil }
        let largest = max(1, matrix.joined().max() ?? 1)
        width = first.count
        height = matrix.count
        thresholds = matrix.joined().map { Float($0 + 1) / Float(largest + 2) }
    }

    /// From a grayscale picture of the pattern: the brighter a pixel, the lighter the touch that turns it on, as with
    /// Aseprite's custom matrices.
    init?(image: CGImage) {
        let width = image.width, height = image.height
        guard (1...Self.maxSide).contains(width), (1...Self.maxSide).contains(height),
              let context = try? BrushRaster.context(width: width, height: height, mask: true) else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let rows = (0..<height).map { y in (0..<width).map { x in 255 - Int(data[y * context.bytesPerRow + x]) } }
        self.init(matrix: rows)
    }

    /// Whether the pattern paints document pixel (`x`, `y`) at `density`, 0–1.
    func isOn(x: Int, y: Int, density: Float) -> Bool {
        let column = (x % width + width) % width, row = (y % height + height) % height
        return density >= thresholds[row * width + column]
    }
}

/// What a brush does at each pressure, from the lightest touch to the firmest: how much of its pattern it paints, and
/// its size, as a fraction of the size set. Looked up rather than worked out as the Pencil moves, so whatever shaped it
/// (a plugin's script, say) never runs under the stroke.
nonisolated struct BrushDynamicsTable: Sendable, Equatable {
    static let steps = 256
    /// `steps` entries each, at pressures 0, 1/255, … 1.
    let density: [Float]
    let size: [Float]

    init(density: [Float], size: [Float]) {
        precondition(density.count == Self.steps && size.count == Self.steps)
        self.density = density.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        // A tip shrinks to a sliver at the lightest, never to nothing.
        self.size = size.map { $0.isFinite ? min(1, max(0.02, $0)) : 1 }
    }

    /// The same at every pressure: for a mouse, or a brush that ignores it.
    init(density: Float) {
        self.init(density: Array(repeating: density, count: Self.steps), size: Array(repeating: 1, count: Self.steps))
    }

    func at(_ pressure: CGFloat) -> (density: Float, size: Float) {
        let index = Int((min(1, max(0, pressure.isFinite ? pressure : 1)) * CGFloat(Self.steps - 1)).rounded())
        return (density[index], size[index])
    }
}

/// A brush that paints in a dither pattern instead of soft or antialiased dabs: crisp pixels, each either painted or
/// left, as a pixel-art brush's are. How much of the pattern it paints is its density, from `dynamics`.
nonisolated struct PatternInk: Sendable {
    enum Colors: String, Sendable, CaseIterable {
        /// The pattern's gaps keep what was there.
        case foreground
        /// The gaps are painted the background color, as Aseprite's dithered pressure paints them.
        case foregroundToBackground
    }
    var pattern: DitherPattern
    var colors: Colors = .foreground
    var background: (red: CGFloat, green: CGFloat, blue: CGFloat) = (1, 1, 1)
    var dynamics: BrushDynamicsTable
}

/// How a brush lays its color down.
nonisolated enum BrushInk: Sendable {
    /// The round tip's soft or antialiased dabs.
    case round
    case pattern(PatternInk)
}
