import SwiftUI

/// The Brush's brush menu: its own round brush, and the brushes plugins add. Shown once there's a plugin brush to
/// choose. On iPad it's the tool bar's title, `title`, which names the brush, so it takes no room of its own in a bar
/// that's short of it in portrait.
struct BrushKindPicker: View {
    @Bindable var session: EditorSession
    var title = ""
    private var registry: PluginRegistry { .shared }
    private var selection: Binding<String?> {
        Binding(get: { session.pluginBrush?.id }, set: { session.brushKind = $0 })
    }

    var body: some View {
        if !registry.brushes.isEmpty {
            #if os(macOS)
            Picker("Brush", selection: selection) { choices }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                .help("The round brush, or a brush a plugin adds")
            #else
            Menu {
                Picker("Brush", selection: selection) { choices }
            } label: {
                HStack(spacing: 5) {
                    Text(title).font(ToolHeaderStyle.titleFont)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
                .frame(minHeight: TouchTarget.size).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerHighlight()
            .accessibilityLabel("Brush")
            .accessibilityValue(session.pluginBrush?.name ?? "Round")
            .accessibilityIdentifier("brushKind")
            #endif
        }
    }

    @ViewBuilder private var choices: some View {
        Label("Round", systemImage: "circle.fill").tag(String?.none)
        ForEach(registry.brushes) { brush in
            Label(brush.name, systemImage: brush.symbol).tag(Optional(brush.id))
        }
    }
}

/// A plugin brush's options in the tool bar, laid out from what its plugin.json says they are: sliders, switches,
/// choices and pattern menus, as the bar's own controls are drawn on each platform. Those about pressure share a
/// Pressure button, which opens them in a popover.
struct PluginBrushOptions: View {
    let brush: PluginBrush
    private var registry: PluginRegistry { .shared }

    var body: some View {
        ForEach(brush.options.filter { !$0.pressure }, id: \.id) { option in
            PluginOptionControl(brush: brush, option: option)
        }
        let pressure = brush.options.filter(\.pressure)
        if !pressure.isEmpty { PluginPressureButton(brush: brush, options: pressure) }
        if let problem = registry.brushProblems[brush.id] {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .help(problem).accessibilityLabel(problem)
        }
    }
}

/// One option of a plugin brush, as a control in the bar.
struct PluginOptionControl: View {
    let brush: PluginBrush
    let option: PluginOption
    private var registry: PluginRegistry { .shared }

    var body: some View {
        switch option.kind {
        case .slider: slider
        case .toggle: toggle
        case .choice: choice
        case .pattern: PatternMenu(brush: brush, option: option)
        }
    }

    private var value: PluginValue { registry.value(option, of: brush) }
    private func set(_ value: PluginValue) { registry.setValue(value, for: option, of: brush) }
    private var number: Binding<Double> { Binding(get: { value.number ?? option.range.lowerBound }, set: { set(.number($0)) }) }
    private var flag: Binding<Bool> { Binding(get: { value.bool ?? false }, set: { set(.bool($0)) }) }
    private var choiceID: Binding<String> { Binding(get: { value.string ?? "" }, set: { set(.string($0)) }) }
    private var unit: String { option.unit ?? "" }

    @ViewBuilder private var slider: some View {
        #if os(macOS)
        HStack(spacing: 8) {
            Text(option.title).scrubbable(sensitivity: max(0.01, (option.range.upperBound - option.range.lowerBound) / 200),
                                          value: number, range: option.range)
            Slider(value: number, in: option.range).frame(width: 100)
            TextField(option.title, value: Binding(get: { number.wrappedValue }, set: { number.wrappedValue = $0.isFinite ? $0 : option.range.lowerBound }),
                      format: .number.precision(.fractionLength(0)))
                .frame(width: 42).textFieldStyle(.roundedBorder)
                .arrowSteps(value: { number.wrappedValue }, change: { number.wrappedValue = $0 })
                .unitSuffix(unit)
        }
        .help(option.help ?? "")
        #else
        HeaderValue(title: option.title, value: number, range: option.range, unit: unit, slider: option.range)
        #endif
    }

    @ViewBuilder private var toggle: some View {
        #if os(macOS)
        Toggle(option.title, isOn: flag).help(option.help ?? "")
        #else
        PillToggle(title: option.title, isOn: flag)
        #endif
    }

    @ViewBuilder private var choice: some View {
        #if os(macOS)
        Picker(option.title, selection: choiceID) {
            ForEach(option.choices, id: \.id) { Text($0.title).tag($0.id) }
        }
        .pickerStyle(.menu).fixedSize()
        .help(option.help ?? "")
        #else
        Menu {
            Picker(option.title, selection: choiceID) {
                ForEach(option.choices, id: \.id) { Text($0.title).tag($0.id) }
            }
        } label: {
            MenuPill(title: option.title, value: option.choices.first { $0.id == choiceID.wrappedValue }?.title ?? "",
                     widest: option.choices.map(\.title).max { $0.count < $1.count } ?? "")
        }
        .buttonStyle(.plain).pointerHighlight()
        .accessibilityLabel(option.title)
        #endif
    }
}

/// The brush's pressure settings, in a popover: what pressing harder does, and the range of pressure that counts.
private struct PluginPressureButton: View {
    let brush: PluginBrush
    let options: [PluginOption]
    @State private var open = false
    private var registry: PluginRegistry { .shared }

    var body: some View {
        Button { open = true } label: {
            #if os(macOS)
            Label("Pressure", systemImage: "hand.point.up.left").labelStyle(.titleAndIcon)
            #else
            MenuPill(title: "Pressure", value: nil, widest: "")
            #endif
        }
        #if os(macOS)
        .help("What pressing harder does, with a pen or Apple Pencil")
        #else
        .buttonStyle(.plain).pointerHighlight()
        #endif
        .accessibilityIdentifier("pluginPressure")
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(options, id: \.id) { option in
                    switch option.kind {
                    case .slider: PressureSlider(brush: brush, option: option)
                    case .toggle:
                        Toggle(option.title, isOn: Binding(get: { registry.value(option, of: brush).bool ?? false },
                                                           set: { registry.setValue(.bool($0), for: option, of: brush) }))
                            .accessibilityIdentifier("plugin." + option.id)
                    default: PluginOptionControl(brush: brush, option: option)
                    }
                }
            }
            .padding(16)
            .frame(minWidth: 280)
            #if !os(macOS)
            .presentationCompactAdaptation(.popover)
            #endif
        }
    }
}

/// A slider in the pressure popover: its title and value above it, the full width below.
private struct PressureSlider: View {
    let brush: PluginBrush
    let option: PluginOption
    private var registry: PluginRegistry { .shared }

    var body: some View {
        let value = Binding(get: { registry.value(option, of: brush).number ?? option.range.lowerBound },
                            set: { registry.setValue(.number($0.rounded()), for: option, of: brush) })
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(option.title)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))\(option.unit ?? "")").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: option.range) { Text(option.title) }
                .accessibilityIdentifier("plugin." + option.id)
            if let help = option.help { Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A menu of the dither patterns every plugin has added, each drawn half filled in.
struct PatternMenu: View {
    let brush: PluginBrush
    let option: PluginOption
    private var registry: PluginRegistry { .shared }
    private var current: PluginPattern? { registry.pattern(registry.value(option, of: brush).string, for: brush) }

    var body: some View {
        Menu {
            Picker(option.title, selection: Binding(get: { current?.id ?? "" },
                                                    set: { registry.setValue(.string($0), for: option, of: brush) })) {
                ForEach(registry.patterns) { pattern in
                    Label { Text(pattern.name) } icon: { PatternSwatch(pattern: pattern.pattern) }.tag(pattern.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                #if !os(macOS)
                Text(option.title).foregroundStyle(.secondary)
                #endif
                if let current { PatternSwatch(pattern: current.pattern) }
                Text(current?.name ?? "None").lineLimit(1)
                #if !os(macOS)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                #endif
            }
            #if !os(macOS)
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.white.opacity(0.08), in: Capsule())
            .frame(minHeight: TouchTarget.size).contentShape(Rectangle())
            #endif
        }
        #if os(macOS)
        .fixedSize()
        .help(option.help ?? "The dither pattern the brush paints in")
        #else
        .buttonStyle(.plain).pointerHighlight()
        #endif
        .accessibilityLabel(option.title)
        .accessibilityValue(current?.name ?? "None")
        .accessibilityIdentifier("plugin." + option.id)
    }
}

/// A dither pattern half filled in, its pixels drawn large enough to see.
struct PatternSwatch: View {
    let pattern: DitherPattern
    var body: some View {
        Image(decorative: PatternSwatch.image(pattern), scale: 1)
            .interpolation(.none)
            .resizable()
            .frame(width: 16, height: 16)
            .overlay { Rectangle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5) }
    }

    private static var cache: [DitherPattern: CGImage] = [:]
    /// 8 × 8 pixels of the pattern at half density, white on black.
    static func image(_ pattern: DitherPattern) -> CGImage {
        if let image = cache[pattern] { return image }
        let context = try! BrushRaster.context(width: 8, height: 8, mask: true)
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<8 {
            for x in 0..<8 { pixels[y * context.bytesPerRow + x] = pattern.isOn(x: x, y: y, density: 0.5) ? 255 : 40 }
        }
        let image = context.makeImage()!
        cache[pattern] = image
        return image
    }
}

#if !os(macOS)
/// A capsule naming a menu's setting and what it's set to, as the iPad tool bar draws its menus.
struct MenuPill: View {
    let title: String
    let value: String?
    /// The longest the value can read, so the pill keeps its width as it changes.
    let widest: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title).foregroundStyle(value == nil ? .primary : .secondary)
            if let value {
                ZStack(alignment: .leading) {
                    Text(widest).hidden()
                    Text(value).foregroundStyle(.primary)
                }
            }
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 10).frame(height: 30)
        .background(Color.white.opacity(0.08), in: Capsule())
        .frame(minHeight: TouchTarget.size).contentShape(Rectangle())
    }
}

/// A switch as a capsule in the bar, filled while it's on, as the Option button is.
struct PillToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .font(ToolHeaderStyle.controlFont.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .padding(.horizontal, 10).frame(height: 30)
                .background(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.white.opacity(0.08)), in: Capsule())
                .frame(minHeight: TouchTarget.size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerHighlight()
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
#endif
