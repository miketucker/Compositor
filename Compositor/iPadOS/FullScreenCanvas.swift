import SwiftUI

/// Full Screen Canvas: the editor puts away its bars, panels and tool rail, and the canvas takes the whole window, as
/// Procreate's full screen does. The button in the canvas's corner, the menus or ⌃⌘F bring them back. Undo and redo
/// are still two- and three-finger taps.
@MainActor @Observable final class FullScreenCanvas {
    static let shared = FullScreenCanvas()
    var isOn = false
    private init() {}

    func toggle() { isOn.toggle() }
}

/// Brings the bars back, from the canvas's corner while they're away.
struct ExitFullScreenButton: View {
    var body: some View {
        Button { FullScreenCanvas.shared.isOn = false } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .hoverEffect()
        .accessibilityLabel("Exit Full Screen")
        .accessibilityIdentifier("exitFullScreen")
    }
}

/// The tool's options in Full Screen Canvas: a pill at the top of the canvas showing the tool, which opens out into
/// them. A brush's are what's reached for mid-drawing (its size and opacity, and the Brush's colors, each opening the
/// picker); every other tool's are its whole bar. It stays open or closed as it was last left.
struct FullScreenToolbar<Header: View>: View {
    @Bindable var session: EditorSession
    @ViewBuilder var header: Header
    @AppStorage("fullScreenToolbarOpen") private var open = false
    /// How wide a brush's options are laid out in full, so the bar is only as wide as they are where there's room.
    @State private var optionsWidth: CGFloat?

    var body: some View {
        HStack(spacing: 4) {
            Button { withAnimation(.snappy(duration: 0.25)) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    ToolIcon(tool: session.tool, session: session)
                    Image(systemName: open ? "chevron.left" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: TouchTarget.size).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerHighlight()
            .accessibilityLabel(open ? "Hide tool options" : "Show tool options")
            .accessibilityIdentifier("fullScreenToolOptions")
            if open {
                Group {
                    if session.tool.isBrushTool { brushOptions } else { header }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: Capsule())
    }

    /// On one line, scrolling sideways where the window is too narrow for them, as the tool bars do.
    private var brushOptions: some View {
        ScrollView(.horizontal) {
            brushControls.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { optionsWidth = $0 }
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: optionsWidth)
    }

    private var brushControls: some View {
        HStack(spacing: 16) {
            if session.tool == .brush {
                Picker("Mode", selection: $session.brushMode) {
                    Image(systemName: "paintbrush.pointed").accessibilityLabel("Paint").tag(BrushToolMode.paint)
                    Image(systemName: "eraser").accessibilityLabel("Erase").tag(BrushToolMode.erase)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            CompactSlider(title: "Size", value: setting(\.diameter), range: 1...2000, unit: "px", logarithmic: true)
            CompactSlider(title: session.tool == .blur ? "Strength" : "Opacity", value: setting(\.opacity, scale: 100),
                          range: 1...100, unit: "%")
            // A plugin brush's own, those its plugin marks as reached for mid-drawing: the Dither brush's pattern and
            // density.
            if session.tool == .brush, let brush = session.pluginBrush {
                ForEach(brush.options.filter(\.compact), id: \.id) { option in
                    if option.kind == .slider {
                        CompactSlider(title: option.title, value: pluginNumber(option, of: brush), range: option.range,
                                      unit: option.unit ?? "")
                    } else {
                        PluginOptionControl(brush: brush, option: option)
                    }
                }
            }
            // The colors the Brush paints with; healing, cloning and smearing take theirs from the image.
            if session.tool == .brush { FullScreenPalette(session: session) }
            ToolOptionButton(session: session, iconOnly: true)
        }
        .font(ToolHeaderStyle.controlFont)
        .lineLimit(1)
        .padding(.trailing, 8)
        .disabled(session.showsBusy)
    }

    private func pluginNumber(_ option: PluginOption, of brush: PluginBrush) -> Binding<Double> {
        Binding(get: { PluginRegistry.shared.value(option, of: brush).number ?? option.range.lowerBound },
                set: { PluginRegistry.shared.setValue(.number($0), for: option, of: brush) })
    }

    /// A brush setting as the bar shows it: a percentage for those held as 0–1.
    private func setting(_ key: WritableKeyPath<BrushSettings, CGFloat>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { Double(session.brushSettings[keyPath: key]) * scale },
                set: { session.brushSettings[keyPath: key] = CGFloat($0 / scale) })
    }
}

/// A value in the full-screen bar, set straight on its slider, with its figure beside it.
private struct CompactSlider: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let unit: String
    /// Along a log scale, for sizes, where a small brush needs as much of the slider as a large one.
    var logarithmic = false

    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Slider(value: position, in: logarithmic ? log(range.lowerBound)...log(range.upperBound) : range) { Text(title) }
                .frame(width: 120)
                .accessibilityValue(text(for: value.wrappedValue))
                .accessibilityIdentifier("fullScreen" + title)
            // As wide as the widest figure, so the bar keeps its width as the number changes.
            ZStack(alignment: .trailing) {
                Text(text(for: range.upperBound)).hidden()
                Text(text(for: value.wrappedValue))
            }
            .monospacedDigit()
        }
    }

    private var position: Binding<Double> {
        Binding(get: {
            let clamped = min(range.upperBound, max(range.lowerBound, value.wrappedValue))
            return logarithmic ? log(clamped) : clamped
        }, set: { position in
            value.wrappedValue = min(range.upperBound, max(range.lowerBound, (logarithmic ? exp(position) : position).rounded()))
        })
    }

    private func text(for number: Double) -> String {
        "\(Int(number.rounded()))" + (unit == "%" || unit.isEmpty ? unit : " " + unit)
    }
}

/// The foreground and background colors in the full-screen bar, large enough for a fingertip: each opens the picker,
/// and the arrows swap them. On a mask they're black or white, chosen from a menu, as the tool rail's are.
private struct FullScreenPalette: View {
    let session: EditorSession

    var body: some View {
        HStack(spacing: 0) {
            swatch(background: false, size: 28)
            swatch(background: true, size: 22)
            Button { session.swapPaletteColors() } label: {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 12, weight: .medium))
                    .frame(width: 36, height: TouchTarget.size).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerHighlight().foregroundStyle(.secondary)
            .accessibilityLabel("Swap colors")
        }
        .disabled(!session.canEditPalette)
    }

    @ViewBuilder private func swatch(background: Bool, size: CGFloat) -> some View {
        let label = background ? "Background color" : "Foreground color"
        let chip = Circle()
            .fill(session.paletteColor(background: background).swiftUI)
            .overlay { Circle().inset(by: 1).strokeBorder(.white, lineWidth: 1.5) }
            .overlay { Circle().strokeBorder(.black.opacity(0.6), lineWidth: 1) }
            .frame(width: size, height: size)
            .frame(width: 38, height: TouchTarget.size).contentShape(Rectangle())
        if session.isMaskSelected {
            Menu {
                Button("Black · Hide") { session.setPaletteColor(.black, background: background) }
                Button("White · Reveal") { session.setPaletteColor(.white, background: background) }
            } label: { chip }
            .buttonStyle(.plain).pointerHighlight().accessibilityLabel(label)
        } else {
            Button { session.openColorPicker(background: background) } label: { chip }
                .buttonStyle(.plain).pointerHighlight().accessibilityLabel(label)
        }
    }
}
