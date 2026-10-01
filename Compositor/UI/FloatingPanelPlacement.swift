/// Where a floating panel opens the first time (or each time, for docked styles).
enum FloatingPanelPlacement: Sendable {
    /// Centered on the canvas, or the last position the user left the panel.
    case automatic
    /// Full height of the main document window, flush against its right edge.
    case dockedToMainWindowRight
}
