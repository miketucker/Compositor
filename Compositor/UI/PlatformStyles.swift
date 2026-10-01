import SwiftUI

/// Controls the Mac has and iPad doesn't, each with the nearest iPad equivalent.
extension View {
    /// A checkbox on the Mac; a switch on iPad, which has no checkboxes.
    @ViewBuilder func checkboxToggle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }

    /// Radio buttons on the Mac; a pop-up menu on iPad.
    @ViewBuilder func radioGroupPicker() -> some View {
        #if os(macOS)
        pickerStyle(.radioGroup)
        #else
        pickerStyle(.menu)
        #endif
    }

    /// A menu drawn as just its label, as a borderless button is.
    @ViewBuilder func borderlessMenu() -> some View {
        #if os(macOS)
        menuStyle(.borderlessButton)
        #else
        menuStyle(.button).buttonStyle(.borderless)
        #endif
    }

    /// The highlight iPad's pointer gives a control it's over, for a custom-drawn button that has none of its own.
    @ViewBuilder func pointerHighlight() -> some View {
        #if os(macOS)
        self
        #else
        hoverEffect()
        #endif
    }

    /// Escape in a field, on the Mac's keyboard.
    @ViewBuilder func onEscape(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        onKeyPress(.escape) { action(); return .handled }
        #endif
    }
}

/// How big a control has to be to press. The Mac's pointer is precise; a fingertip needs Apple's 44 points, though
/// what's drawn there can stay smaller.
enum TouchTarget {
    #if os(macOS)
    static let size: CGFloat = 0
    #else
    static let size: CGFloat = 44
    #endif
}
