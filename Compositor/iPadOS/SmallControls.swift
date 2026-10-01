import SwiftUI
import UIKit

/// A scroll view that never shows its scroll indicator, for the tool rail.
struct IndicatorlessScrollView<Content: View>: View {
    @ViewBuilder var content: () -> Content
    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }
    var body: some View {
        ScrollView(.vertical) { content() }.scrollIndicators(.hidden)
    }
}

/// The active layer's blend mode, grouped as Photoshop groups them: darkening, lightening, contrast, comparative,
/// component. iPad's menus can't preview a mode under the pointer as the Mac's does, so choosing one applies it.
struct BlendModePicker: View {
    let session: EditorSession
    private var current: LayerBlendMode { session.activeLayer?.blendMode ?? .normal }
    var body: some View {
        Menu {
            ForEach(Array(LayerBlendMode.groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group, id: \.self) { mode in
                        Button {
                            session.setLayerBlendMode(mode)
                            session.refreshCanvasPreview?()
                        } label: {
                            if mode == current { Label(mode.rawValue, systemImage: "checkmark") } else { Text(mode.rawValue) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(current.rawValue).lineLimit(1)
                Spacer(minLength: 2)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color.white.opacity(0.08), in: Capsule())
            .frame(minHeight: TouchTarget.size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerHighlight()
        .disabled(!session.canEditAppearance)
        .accessibilityLabel("Blend mode")
    }
}

/// Camera Raw's slider: the track can be colored along its length, and a double tap on the knob restores the default.
struct CameraRawSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var track: CameraRawSliderTrack
    var help: String
    var onChange: (Double) -> Void
    var onReset: () -> Void
    private let knob: CGFloat = 20

    var body: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - knob)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
            ZStack(alignment: .leading) {
                trackView.frame(height: 4).padding(.horizontal, knob / 2)
                Circle().fill(.white).shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .frame(width: knob, height: knob)
                    .offset(x: travel * fraction)
                    .onTapGesture(count: 2) { onReset() }
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let position = min(1, max(0, (drag.location.x - knob / 2) / travel))
                onChange(range.lowerBound + position * span)
            })
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel(help)
        .accessibilityValue(Text(value, format: .number.precision(.fractionLength(0...2))))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 100
            onChange(min(range.upperBound, max(range.lowerBound, value + (direction == .increment ? step : -step))))
        }
    }

    @ViewBuilder private var trackView: some View {
        if let colors = track.colors {
            Capsule().fill(LinearGradient(colors: colors.map { Color(uiColor: $0) }, startPoint: .leading, endPoint: .trailing))
        } else {
            Capsule().fill(Color.white.opacity(0.25))
        }
    }
}

/// The font face for the Type tool, chosen with the system's font picker, which lists every installed face.
struct TypeFontPicker: View {
    @Binding var fontName: String
    /// The Mac's menu tries faces on the text as the pointer moves over them; iPad's picker applies what's chosen.
    enum PreviewStep { case show(String), revert, keep }
    var preview: (PreviewStep) -> Void = { _ in }
    @State private var choosing = false

    var body: some View {
        Button { choosing = true } label: {
            HStack {
                Text(displayName).lineLimit(1)
                    .font(Font(UIFont(name: fontName, size: 14) ?? .systemFont(ofSize: 14)))
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Color.white.opacity(0.08), in: Capsule())
            .frame(minHeight: TouchTarget.size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerHighlight()
        .accessibilityLabel("Font")
        .accessibilityValue(displayName)
        .popover(isPresented: $choosing) {
            FontPickerSheet { name in
                choosing = false
                if let name { fontName = name }
            }
            .frame(minWidth: 320, minHeight: 480)
        }
    }

    private var displayName: String {
        fontName.isEmpty ? "Multiple Fonts" : UIFont(name: fontName, size: 12)?.fontName ?? fontName
    }
}

private struct FontPickerSheet: UIViewControllerRepresentable {
    let finish: (String?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }
    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        // Faces, not only families: bold and italic are faces of their own, as in the Mac's menu.
        configuration.includeFaces = true
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIFontPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let finish: (String?) -> Void
        init(finish: @escaping (String?) -> Void) { self.finish = finish }
        func fontPickerViewControllerDidPickFont(_ picker: UIFontPickerViewController) {
            finish(picker.selectedFontDescriptor.map { UIFont(descriptor: $0, size: 12).fontName })
        }
        func fontPickerViewControllerDidCancel(_ picker: UIFontPickerViewController) { finish(nil) }
    }
}

/// A shortcut's key combination, recorded from the hardware keyboard: tap it, then press the new keys.
struct ShortcutRecorder: View {
    let chord: ShortcutChord
    let recording: Bool
    let start: () -> Void
    let finish: (ShortcutChord?) -> Void
    var body: some View {
        Button(recording ? "Press keys…" : chord.label) { start() }
            .buttonStyle(.bordered)
            .background { if recording { KeyCatcher(finish: finish).frame(width: 0, height: 0) } }
            .accessibilityLabel(recording ? "Press a shortcut" : chord.label)
    }

    private struct KeyCatcher: UIViewRepresentable {
        let finish: (ShortcutChord?) -> Void
        func makeUIView(context: Context) -> CatcherView {
            let view = CatcherView()
            view.finish = finish
            DispatchQueue.main.async { view.becomeFirstResponder() }
            return view
        }
        func updateUIView(_ view: CatcherView, context: Context) { view.finish = finish }
    }

    final class CatcherView: UIView {
        var finish: ((ShortcutChord?) -> Void)?
        override var canBecomeFirstResponder: Bool { true }
        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            guard let key = presses.first?.key, let canvasKey = CanvasKey(key) else { super.pressesBegan(presses, with: event); return }
            // A modifier on its own is part of the chord still being pressed.
            if canvasKey.keyCode == CanvasKey.modifierOnly { return }
            let chord = ShortcutChord(canvasKey)
            guard chord.key.count == 1 else { return }
            finish?(chord)
            resignFirstResponder()
        }
    }
}

/// Over the canvas while it shows a mask by itself: whose mask it is, and a way back to the composite.
struct MaskAloneBadge: View {
    let session: EditorSession
    let layer: ImageLayer
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "rectangle.inset.filled").font(.system(size: 11))
            Text("Layer Mask").font(.system(size: 12, weight: .semibold))
            Text(layer.name).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).frame(maxWidth: 220)
            Button { session.viewsMaskAlone = false } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop viewing the mask")
        }
        .foregroundStyle(.white)
        .padding(.leading, 11).padding(.trailing, 4)
        .frame(height: 30)
        .background(Color.black.opacity(0.75), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14)))
    }
}
