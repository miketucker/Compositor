import SwiftUI

/// The Mac editor's toolbar: New, the project tabs, and the zoom controls, in the window's title bar.
struct EditorToolbar: ViewModifier {
    let session: EditorSession
    let workspace: ProjectWorkspace?
    let windowWidth: CGFloat
    let newCanvas: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationTitle(session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled")
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button { newCanvas() } label: { Label("New canvas", systemImage: "plus") }
                        .help("New canvas (⌘N)").accessibilityIdentifier("newCanvasToolbar")
                        .disabled(session.isImporting || session.showsBusy || session.levels != nil)
                        .modifier(NewProjectDropTarget(workspace: workspace))
                }
                ToolbarSpacer(.fixed, placement: .navigation)
                if let workspace = workspace {
                    ToolbarItem(placement: .navigation) {
                        ProjectTabStrip(workspace: workspace)
                            // As wide as the toolbar allows: the window less the traffic lights and New button before it
                            // and the zoom controls after it. Bounded, so adding tabs never pushes those aside; the
                            // strip scrolls instead.
                            .frame(width: max(200, windowWidth - 352), height: 34, alignment: .center)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                // Absorb all remaining navigation-toolbar width before the zoom controls.
                // Without this spacer, the growing tab strip pushes the primary actions left.
                ToolbarSpacer(.flexible, placement: .navigation)
                ToolbarItem(placement: .primaryAction) {
                    Button("Fit") { session.fit() }.help("Fit canvas in window (⌘0)")
                        .accessibilityIdentifier("fitCanvas").disabled(session.document == nil)
                        .padding(.horizontal, 4)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("100%") { session.zoom(to: 1) }.help("Actual pixels (⌘1)")
                        .accessibilityIdentifier("actualPixels").disabled(session.document == nil)
                        .padding(.horizontal, 4)
                }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 0) {
                        Button { session.zoomKeyboard(by: 1) } label: {
                            Image(systemName: "plus.magnifyingglass")
                        }.help("Zoom in (⌘+)").disabled(session.document == nil)
                        Button { session.zoomKeyboard(by: -1) } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }.help("Zoom out (⌘−)").disabled(session.document == nil)
                    }
                    .padding(.horizontal, 4)
                }
            }
    }
}
