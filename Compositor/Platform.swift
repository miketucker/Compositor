import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import CoreImage
import UIKit
#endif

// The few AppKit and UIKit types the shared code needs, under one name for both. Everything else the shared code uses
// (Core Graphics, Core Image, Metal, ImageIO) is the same on the Mac and on iPad. Code for one platform only lives in
// the macOS and iPadOS folders; each is left out of the other's build.

#if os(macOS)
typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
typealias PlatformView = NSView
typealias PlatformImage = NSImage
#else
typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
typealias PlatformView = UIView
typealias PlatformImage = UIImage
#endif

extension PlatformColor {
    /// A color from sRGB components, as the document stores colors.
    static func sRGB(_ red: Double, _ green: Double, _ blue: Double, alpha: Double = 1) -> PlatformColor {
        #if os(macOS)
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        #else
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
        #endif
    }
}

/// The "that can't be done" signal: the system beep on the Mac. iPad has no beep, and a refused action there simply
/// does nothing.
enum Feedback {
    static func beep() {
        #if os(macOS)
        NSSound.beep()
        #endif
    }
}

/// Draws AppKit/UIKit content (text laid out by TextKit) into a Core Graphics context whose coordinates run top-down.
enum PlatformGraphics {
    static func drawing(in context: CGContext, _ body: () -> Void) {
        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        body()
        #else
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        body()
        #endif
    }

    /// The context `draw(_:)` is drawing into.
    static var currentContext: CGContext? {
        #if os(macOS)
        NSGraphicsContext.current?.cgContext
        #else
        UIGraphicsGetCurrentContext()
        #endif
    }
}

/// The system clipboard, for pixels copied as PNG and for a copied layer's reference.
enum Clipboard {
    static let copiedLayerType = "com.compositor.copied-layer"

    /// Bumped by every change to the clipboard, here or in another app.
    static var changeCount: Int {
        #if os(macOS)
        NSPasteboard.general.changeCount
        #else
        UIPasteboard.general.changeCount
        #endif
    }

    /// Replaces the clipboard with a copied layer's reference, which only this app reads.
    static func setCopiedLayer(_ id: UUID) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(id.uuidString, forType: NSPasteboard.PasteboardType(copiedLayerType))
        #else
        UIPasteboard.general.setItems([[copiedLayerType: id.uuidString]])
        #endif
    }

    /// Replaces the clipboard with an image, as PNG for other apps.
    static func setImage(_ image: CGImage) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = pngData(image) { pasteboard.setData(png, forType: .png) }
        #else
        if let png = pngData(image) { UIPasteboard.general.setItems([[UTType.png.identifier: png]]) }
        else { UIPasteboard.general.items = [] }
        #endif
    }

    /// Whether the clipboard holds an image, without reading it (on iPad, reading another app's copy asks first).
    static var hasImage: Bool {
        #if os(macOS)
        NSPasteboard.general.canReadObject(forClasses: [NSImage.self], options: nil)
        #else
        UIPasteboard.general.hasImages
        #endif
    }

    /// The image on the clipboard, if there is one.
    static func image() -> CGImage? {
        #if os(macOS)
        NSImage(pasteboard: NSPasteboard.general)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        UIPasteboard.general.image.flatMap { image in
            image.cgImage ?? image.ciImage.flatMap { CIContextHolder.shared.createCGImage($0, from: $0.extent) }
        }
        #endif
    }

    /// `image` as PNG, the form other apps take a picture in.
    nonisolated static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

#if !os(macOS)
private enum CIContextHolder { static let shared = CIContext() }
#endif

/// A question with a few answers, asked with the platform's own alert.
struct Prompt {
    var title: String
    var message: String
    /// In the order the Mac's alert lists them; the first is the default.
    var buttons: [String]
    /// Which button cancels, if one does.
    var cancel: Int?
}

/// Questions the shared code asks. The Mac answers at once, from a modal alert; iPad answers once the alert it shows
/// is dismissed. Each platform's folder implements `ask`.
enum Prompts {}

/// The modifier keys that change what a press or a key does, named as on the Mac's keyboard. On iPad they come from a
/// hardware keyboard, or from the canvas's on-screen modifier keys.
struct KeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int
    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)
}

#if os(macOS)
extension KeyModifiers {
    /// The modifier keys held now.
    static var current: KeyModifiers { KeyModifiers(NSEvent.modifierFlags) }
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
    }
}
#else
extension KeyModifiers {
    /// The modifier keys held now, on a hardware keyboard or the canvas's on-screen keys.
    @MainActor static var current: KeyModifiers { HeldModifiers.shared.flags }
    init(_ flags: UIKeyModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.control) { insert(.control) }
        if flags.contains(.alternate) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
    }
}
#endif

extension PlatformColor {
    /// The system accent color, for handles and snapping guides drawn on the canvas.
    static var accent: PlatformColor {
        #if os(macOS)
        .controlAccentColor
        #else
        .tintColor
        #endif
    }
}

#if !os(macOS)
extension UIView {
    /// AppKit's way of asking for a redraw, so drawing code reads the same on both platforms.
    var needsDisplay: Bool {
        get { layer.needsDisplay() }
        set { if newValue { setNeedsDisplay() } }
    }
    /// A UIView isn't clipped by a scroll view the way AppKit's can be, so all of it is visible.
    var visibleRect: CGRect { bounds }
    func displayIfNeeded() { layer.displayIfNeeded() }
}
#endif
