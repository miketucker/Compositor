import Foundation

extension EditorSession {
    /// The status bar's hint on iPad without a keyboard: the tool's gestures, and the touch shortcut and the tool bar's
    /// Option button in place of the keys the Mac's hint names (see `TouchShortcut` and `ToolOptionButton`).
    var touchHint: String {
        if HeldModifiers.shared.latched.contains(.option), let option = ToolOption(self) { return option.hint }
        let addOrSubtract = "Hold the shortcut circle to add, slide to its edge to subtract"
        switch tool {
        case .marquee:
            return (marqueeKind == .ellipse ? "Drag an ellipse" : "Drag a rectangle") + " · \(addOrSubtract) · Drag inside to move"
        case .wand:
            return (wandMode == .object ? "Tap an object to select its outline" : "Tap to select similar colors")
                + " · \(addOrSubtract) · Drag inside to move"
        case .lasso:
            return lassoKind == .freehand ? "Drag to select · \(addOrSubtract) · Drag inside to move"
                : "Tap corners · Tap the start or double-tap to close"
        case .brush:
            return (brushMode == .erase ? "Drag to erase" : "Drag to paint")
                + " · Hold the shortcut circle and tap for a straight line from the last stroke"
                + (pluginBrush == nil ? " · Sample Color to pick a color" : "")
        case .blur:
            return blurMode == .blur ? "Drag to soften" : blurMode == .smudge ? "Drag to smudge" : "Drag to push pixels"
        case .cloneStamp:
            return "Set Source, then tap where to copy from · Drag to clone"
        case .spotHealing:
            return "Drag over blemishes to heal"
        case .type:
            return "Drag a text box · Tap text to edit · Drag box handles to resize"
        case .shape:
            let constrained = shapeKind == .line ? "a 45° line" : shapeKind == .rectangle ? "a square" : "a circle"
            return "Drag to draw a shape on a new layer · Hold the shortcut circle for \(constrained) · From Center to draw out from the middle"
        case .gradient:
            return "Drag to draw · Drag ends to adjust · Hold the shortcut circle for 45° · Sample Color to pick a color"
        case .crop:
            return "Drag to crop · Apply Crop in the bar above"
        case .move:
            return "Drag to move · Handles to resize · Circle to rotate"
        case .eyedropper:
            return "Tap to pick the foreground color"
        case .hand:
            return "Drag to pan · Pinch to zoom"
        case .zoom:
            return "Tap to zoom in · Zoom Out to zoom out · Drag right or left to zoom smoothly"
        case .idle:
            return "No tool selected · Pick one from the tools on the left"
        }
    }
}
