import SwiftUI

/// The palette the Pencil brings up beside its tip, when Settings › Apple Pencil has its squeeze or double tap show
/// one: Brush or Eraser, the brush's size and opacity, and the foreground color, changed without reaching for the
/// bars. A tap anywhere else puts it away.
@MainActor @Observable
final class PencilPalette {
    static let shared = PencilPalette()
    private(set) var session: EditorSession?
    /// Where it points from, in the window.
    private(set) var anchor: CGPoint?

    func show(for session: EditorSession, at point: CGPoint) {
        self.session = session
        anchor = point
    }

    func close() { anchor = nil }
}

/// Hangs the palette from its point over the editor, in the window's root view.
struct PencilPaletteOverlay: View {
    let palette = PencilPalette.shared

    var body: some View {
        GeometryReader { proxy in
            if let anchor = palette.anchor, let session = palette.session {
                let origin = proxy.frame(in: .global).origin
                Color.clear.frame(width: 1, height: 1)
                    .position(x: anchor.x - origin.x, y: anchor.y - origin.y)
                    .popover(isPresented: Binding(get: { palette.anchor != nil }, set: { if !$0 { palette.close() } })) {
                        PencilPaletteView(session: session)
                    }
            }
        }
    }
}

private struct PencilPaletteView: View {
    @Bindable var session: EditorSession
    private let sizes: ClosedRange<Double> = 1...2000

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Button {
                    PencilPalette.shared.close()
                    session.openColorPicker(background: false)
                } label: {
                    Circle().fill(session.paletteColor(background: false).swiftUI)
                        .overlay(Circle().strokeBorder(.white.opacity(0.35)))
                        .frame(width: 30, height: 30)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).hoverEffect()
                .disabled(!session.canEditPalette || session.isMaskSelected)
                .accessibilityLabel("Foreground color")
                toolButton(.paint, title: "Brush", symbol: "paintbrush.pointed")
                toolButton(.erase, title: "Eraser", symbol: "eraser")
            }
            if session.tool.isBrushTool {
                slider("Size", value: Binding(
                    // Along a log scale, so small brushes get as much of the slider as large ones.
                    get: { log(Double(session.brushSettings.diameter)) },
                    set: { session.brushSettings.diameter = CGFloat(exp($0).rounded()) }),
                    range: log(sizes.lowerBound)...log(sizes.upperBound),
                    label: "\(Int(session.brushSettings.diameter)) px")
                slider("Opacity", value: Binding(
                    get: { Double(session.brushSettings.opacity) },
                    set: { session.brushSettings.opacity = CGFloat($0) }),
                    range: 0.01...1, label: "\(Int((session.brushSettings.opacity * 100).rounded()))%")
            }
        }
        .padding(16)
        .frame(width: 300)
        .presentationCompactAdaptation(.popover)
    }

    private func toolButton(_ mode: BrushToolMode, title: String, symbol: String) -> some View {
        let active = session.tool == .brush && session.brushMode == mode
        return Button {
            session.selectTool(.brush)
            if session.tool == .brush { session.brushMode = mode }
        } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 32)
        }
        .buttonStyle(.bordered)
        .tint(active ? .accentColor : .secondary)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.subheadline)
            Slider(value: value, in: range) { Text(title) }
                .accessibilityValue(label)
        }
    }
}
