import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The colored tracks used by Camera Raw's color sliders. Plain sliders keep the system track.
enum CameraRawSliderTrack {
    case plain
    case temperature
    case tint
    case chroma
    /// Neighboring hues around a color-family center, in degrees.
    case hue(Double)
    /// Gray to that family's own color.
    case saturation(Double)
    /// Dark to light in that family's hue.
    case luminance(Double)
    /// One color to its opposite, as Color Balance's Cyan / Red.
    case opposing(PlatformColor, PlatformColor)
    /// The whole hue circle, with that hue in the middle.
    case spectrum(Double)

    /// Left-to-right track colors. Nil keeps the system track.
    var colors: [PlatformColor]? {
        switch self {
        case .plain:
            return nil
        case .temperature:
            return [PlatformColor.sRGB(0.22, 0.46, 0.95),
                    PlatformColor.sRGB(0.98, 0.82, 0.18)]
        case .tint:
            return [PlatformColor.sRGB(0.28, 0.70, 0.34),
                    PlatformColor.sRGB(0.70, 0.40, 0.64)]
        case .chroma:
            return [PlatformColor.sRGB(0.62, 0.62, 0.64),
                    PlatformColor.sRGB(0.86, 0.18, 0.20)]
        case .hue(let degrees):
            return [Self.color(degrees: degrees - 50, saturation: 0.85, brightness: 0.9),
                    Self.color(degrees: degrees + 50, saturation: 0.85, brightness: 0.9)]
        case .saturation(let degrees):
            return [PlatformColor.sRGB(0.55, 0.55, 0.56),
                    Self.color(degrees: degrees, saturation: 0.9, brightness: 0.9)]
        case .luminance(let degrees):
            return [Self.color(degrees: degrees, saturation: 0.55, brightness: 0.18),
                    Self.color(degrees: degrees, saturation: 0.35, brightness: 0.95)]
        case .opposing(let from, let to):
            return [from, to]
        case .spectrum(let degrees):
            return stride(from: -180.0, through: 180, by: 30).map { Self.color(degrees: degrees + $0, saturation: 0.85, brightness: 0.9) }
        }
    }

    private static func color(degrees: Double, saturation: CGFloat, brightness: CGFloat) -> PlatformColor {
        var turns = degrees / 360
        turns -= floor(turns)
        return PlatformColor(hue: turns, saturation: saturation, brightness: brightness, alpha: 1)
    }
}
