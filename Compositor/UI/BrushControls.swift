import SwiftUI

struct BrushControls: View {
    @Bindable var session: EditorSession
    var body: some View {
        HStack(spacing: 12) {
            Text(session.tool == .spotHealing ? "Spot Healing" : session.tool == .cloneStamp ? "Clone Stamp" : session.tool == .blur ? "Smear" : session.brushMode == .erase ? "Eraser" : "Brush").font(ToolHeaderStyle.titleFont)
            if session.tool == .brush {
                Picker("Mode", selection: $session.brushMode) {
                    ForEach(BrushToolMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Paint with the foreground color (B), or erase pixels away (E)")
            }
            if session.tool == .blur {
                Picker("Mode", selection: $session.blurMode) {
                    ForEach(BlurToolMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Liquify pushes pixels · Blur softens · Smudge drags color along")
            }
            if session.tool == .spotHealing {
                Picker("Type", selection: $session.spotHealingMode) {
                    ForEach(SpotHealingMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("spotHealingType")
            }
            if session.tool == .cloneStamp {
                Toggle("Aligned", isOn: $session.cloneSettings.aligned)
                    .help("Keep the source moving with the brush between strokes; off starts every stroke at the source point")
                Picker("Sample", selection: $session.cloneSettings.sampleAllLayers) {
                    Text("This Layer").tag(false)
                    Text("All Layers").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Copy from the active layer only, or from every visible layer as shown")
            }
            #if !os(macOS)
            ToolOptionButton(session: session)
            #endif
            #if os(macOS)
            Text("Size").scrubbable(sensitivity: 1.0, value: $session.brushSettings.diameter, range: 1...2000)
            TextField("Size", value: Binding<Double>(get: { Double(session.brushSettings.diameter) },
                set: { session.brushSettings.diameter = $0.isFinite ? CGFloat(min(2000, max(1, $0))) : 40 }),
                format: .number.precision(.fractionLength(0)))
                .frame(width: 48).textFieldStyle(.roundedBorder)
                .arrowSteps(value: { Double(session.brushSettings.diameter) },
                            change: { session.brushSettings.diameter = CGFloat(min(2000, max(1, $0))) })
                .onChange(of: session.brushSettings.diameter) { _, value in
                    session.brushSettings.diameter = value.isFinite ? min(2000, max(1, value)) : 40
                }
                .unitSuffix("px")
            Text("Hardness").scrubbable(sensitivity: 0.01, value: $session.brushSettings.hardness, range: 0...1)
            Slider(value: $session.brushSettings.hardness, in: 0...1).frame(width: 100)
            TextField("Hardness", value: Binding<Double>(get: { Double(session.brushSettings.hardness * 100) },
                set: { session.brushSettings.hardness = $0.isFinite ? CGFloat(min(1, max(0, $0 / 100))) : 1 }),
                format: .number.precision(.fractionLength(0)))
                .frame(width: 42).textFieldStyle(.roundedBorder)
                .arrowSteps(value: { Double(session.brushSettings.hardness * 100) },
                            change: { session.brushSettings.hardness = CGFloat(min(1, max(0, $0 / 100))) })
                .unitSuffix("%")
            Text(session.tool == .blur ? "Strength" : "Opacity")
                .scrubbable(sensitivity: 0.01, value: $session.brushSettings.opacity, range: 0.01...1)
            Slider(value: $session.brushSettings.opacity, in: 0.01...1).frame(width: 100)
            TextField("Opacity", value: Binding<Double>(get: { Double(session.brushSettings.opacity * 100) },
                set: { session.brushSettings.opacity = $0.isFinite ? CGFloat(min(100, max(1, $0)) / 100) : 1 }),
                format: .number.precision(.fractionLength(0)))
                .frame(width: 42).textFieldStyle(.roundedBorder)
                .arrowSteps(value: { Double(session.brushSettings.opacity * 100) },
                            change: { session.brushSettings.opacity = CGFloat(min(100, max(1, $0)) / 100) })
                .help("Press 1–9 for 10–90%, 0 for 100%")
                .unitSuffix("%")
            // Blur softens by a radius of its own, apart from how strongly it lays the softening down.
            if session.tool == .blur, session.blurMode == .blur {
                Text("Radius").scrubbable(sensitivity: 0.1, value: $session.brushSettings.blurRadius, range: 0.5...50)
                // The slider covers everyday radii; typing or scrubbing reaches up to 50.
                Slider(value: Binding(get: { min(20, session.brushSettings.blurRadius) },
                                      set: { session.brushSettings.blurRadius = $0 }), in: 0.5...20).frame(width: 100)
                TextField("Radius", value: Binding<Double>(get: { Double(session.brushSettings.blurRadius) },
                    set: { session.brushSettings.blurRadius = $0.isFinite ? CGFloat(min(50, max(0.5, $0))) : 5 }),
                    format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 42).textFieldStyle(.roundedBorder)
                    .arrowSteps(value: { Double(session.brushSettings.blurRadius) },
                                change: { session.brushSettings.blurRadius = CGFloat(min(50, max(0.5, $0))) })
                    .help("How far the blur softens, in pixels")
                    .unitSuffix("px")
            }
            #else
            HeaderValue(title: "Size", value: setting(\.diameter), range: 1...2000, unit: "px", slider: 1...2000, logarithmic: true)
            HeaderValue(title: "Hardness", value: setting(\.hardness, scale: 100), range: 0...100, unit: "%", slider: 0...100)
            HeaderValue(title: session.tool == .blur ? "Strength" : "Opacity", value: setting(\.opacity, scale: 100),
                        range: 1...100, unit: "%", slider: 1...100)
            if session.tool == .blur, session.blurMode == .blur {
                HeaderValue(title: "Radius", value: setting(\.blurRadius), range: 0.5...50, unit: "px", step: 0.5,
                            slider: 0.5...50, logarithmic: true, fractionDigits: 1)
            }
            #endif
            // Paint and Erase only: healing, cloning and smearing have their own feel.
            if session.tool == .brush {
                #if os(macOS)
                Text("Smoothing")
                    .scrubbable(sensitivity: 1, value: $session.brushSettings.smoothing, range: 0...100)
                Slider(value: $session.brushSettings.smoothing, in: 0...100).frame(width: 100)
                TextField("Smoothing", value: Binding<Double>(get: { Double(session.brushSettings.smoothing) },
                    set: { session.brushSettings.smoothing = $0.isFinite ? CGFloat(min(100, max(0, $0))) : 0 }),
                    format: .number.precision(.fractionLength(0)))
                    .frame(width: 42).textFieldStyle(.roundedBorder)
                    .arrowSteps(value: { Double(session.brushSettings.smoothing) },
                                change: { session.brushSettings.smoothing = CGFloat(min(100, max(0, $0))) })
                    .help("The brush trails the pointer on a string this long, so a shaky hand still draws a smooth line")
                #else
                HeaderValue(title: "Smoothing", value: setting(\.smoothing), range: 0...100, slider: 0...100)
                // The Pencil's pressure; the Mac's mouse and trackpad have none to give.
                PressureMenu(pressure: $session.brushPressure)
                #endif
            }
            if session.isMaskSelected {
                Picker("Paint", selection: $session.maskPaintWhite) {
                    Text("Black · Hide").tag(false)
                    Text("White · Reveal").tag(true)
                }.frame(width: 180)
            } else if session.tool != .cloneStamp, session.tool != .blur {
                // Same foreground color and Color Picker as the tool-rail swatch.
                HStack(spacing: 6) {
                    Text("Color")
                    Button { session.openColorPicker(background: false) } label: {
                        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                        shape.fill(session.foregroundColor.swiftUI)
                            .overlay { shape.inset(by: 1).strokeBorder(.white, lineWidth: 1) }
                            .overlay { shape.strokeBorder(.black, lineWidth: 1) }
                            .frame(width: 34, height: 18)
                            .contentShape(shape)
                    }
                    .buttonStyle(.plain)
                    .disabled(!session.canEditPalette)
                    .help("Foreground color")
                    .accessibilityLabel("Foreground color")
                }
            }
            Spacer(minLength: 0)
            if session.tool == .cloneStamp, session.cloneSource == nil {
                #if os(macOS)
                Text("Option-click to set the source").foregroundStyle(.secondary)
                #else
                Text("Set a source to copy from").foregroundStyle(.secondary)
                #endif
            }
            if session.isMaskSelected { Text("Mask").foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 18).toolHeaderBar().releasesFocusOnCommit(session)
        .disabled(session.showsBusy)
    }

    #if !os(macOS)
    /// A brush setting as the bar shows it: a percentage for those held as 0–1.
    private func setting(_ key: WritableKeyPath<BrushSettings, CGFloat>, scale: Double = 1) -> Binding<Double> {
        Binding(get: { Double(session.brushSettings[keyPath: key]) * scale },
                set: { session.brushSettings[keyPath: key] = CGFloat($0 / scale) })
    }
    #endif

}

/// A rubber stamp for the tool rail (SF Symbols has none): round handle, neck, body, and pad.
struct CloneStampToolIcon: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var stamp = Path()
            stamp.addEllipse(in: CGRect(x: w * 0.33, y: h * 0.02, width: w * 0.34, height: h * 0.30))
            stamp.addRect(CGRect(x: w * 0.43, y: h * 0.28, width: w * 0.14, height: h * 0.28))
            stamp.addRoundedRect(in: CGRect(x: w * 0.12, y: h * 0.54, width: w * 0.76, height: h * 0.22),
                                 cornerSize: CGSize(width: w * 0.08, height: w * 0.08))
            stamp.addRect(CGRect(x: w * 0.06, y: h * 0.82, width: w * 0.88, height: h * 0.12))
            context.fill(stamp, with: .foreground)
        }
        .accessibilityHidden(true)
    }
}
