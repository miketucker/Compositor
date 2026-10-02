import SwiftUI

/// What Option does with the tool on the canvas, for the tool bar's Option button: setting the Clone Stamp's source,
/// sampling a color, drawing from the center. Selections have their own Add and Subtract in the bar already.
struct ToolOption: Equatable {
    let title: String
    /// What a press on the canvas does while it's on, for the status bar.
    let hint: String
    /// A one-off, done with a single press: the button lets go once a press has used it.
    let once: Bool
    /// What it does, drawn, for a bar with room for an icon alone: sampling a color is the eyedropper.
    var symbol: String? { title == "Sample Color" ? "eyedropper" : nil }

    init?(_ session: EditorSession) {
        switch session.tool {
        case .cloneStamp: (title, hint, once) = ("Set Source", "Tap where to copy from", true)
        // A plugin's brush, the Dither brush, keeps its bar for its own options.
        case .brush where session.pluginBrush == nil, .gradient: (title, hint, once) = ("Sample Color", "Tap or drag to pick the foreground color", true)
        case .move: (title, hint, once) = ("Move a Copy", "Drag to move a copy of the layer", true)
        case .shape: (title, hint, once) = ("From Center", "Drag out from the shape's center", false)
        case .crop: (title, hint, once) = ("From Center", "Drag to crop evenly around the center", false)
        case .zoom: (title, hint, once) = ("Zoom Out", "Tap to zoom out", false)
        default: return nil
        }
    }
}

/// The tool bar's Option button, for working without a keyboard: the canvas takes its presses as if Option were held,
/// as it does from the edge of the touch shortcut, but without a thumb held down. A one-off (setting the source,
/// sampling a color, moving a copy) lets go after the next press on the canvas; the others stay on until tapped again.
struct ToolOptionButton: View {
    let session: EditorSession
    /// Its icon alone where it has one (see `ToolOption.symbol`), for Full Screen Canvas's compact bar.
    var iconOnly = false
    private var option: ToolOption? { ToolOption(session) }

    var body: some View {
        if let option {
            let on = HeldModifiers.shared.latched.contains(.option)
            // A pill like the bar's values, filled while it's on.
            Button { HeldModifiers.shared.latch(on ? [] : .option, once: option.once) } label: {
                Group {
                    if iconOnly, let symbol = option.symbol {
                        Image(systemName: symbol).font(.system(size: 15)).frame(width: 20)
                    } else {
                        Label(option.title, systemImage: "option")
                    }
                }
                .font(ToolHeaderStyle.controlFont.weight(on ? .semibold : .regular))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 10).frame(height: 30)
                .background(on ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                .frame(minHeight: TouchTarget.size).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerHighlight()
            .accessibilityLabel(option.title)
            .accessibilityAddTraits(on ? .isSelected : [])
            .accessibilityIdentifier("toolOption")
            // Another tool, or this one put away: the latch was for what this button said.
            .onChange(of: option) { _, _ in HeldModifiers.shared.latch([]) }
            .onDisappear { HeldModifiers.shared.latch([]) }
        }
    }
}
