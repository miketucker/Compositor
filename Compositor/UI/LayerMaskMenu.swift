import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Adds a mask in one click, as Photoshop's button does: all white, or with a selection, revealing just the
/// selection. Option-click adds the opposite: all black, or hiding the selection.
/// Enable/Disable and Delete live in the layer's context menu.
struct LayerMaskMenu: View {
    let session: EditorSession
    var body: some View {
        Button {
            #if os(macOS)
            session.addMask(revealing: NSApp.currentEvent?.modifierFlags.contains(.option) != true)
            #else
            session.addMask(revealing: !KeyModifiers.current.contains(.option))
            #endif
        } label: { Image(systemName: "rectangle.inset.filled").footerHitArea() }
            .buttonStyle(.borderless)
            .help(session.selection == nil ? "Add layer mask (Option-click for a black mask)"
                  : "Add layer mask revealing the selection (Option-click to hide it)")
            .accessibilityLabel("Add layer mask")
            .disabled(!session.canEditMask || session.activeLayer?.mask != nil)
    }
}
