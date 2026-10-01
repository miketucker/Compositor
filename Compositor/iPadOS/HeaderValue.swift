import SwiftUI

/// A number in a tool's bar on iPad, where a field to type in means the keyboard coming up over the canvas: the value
/// as a button, which opens a popover to set it by touch. A slider covers its everyday span, − and + step it (held,
/// they keep stepping), and Type brings up a field for an exact figure. The field waits to be asked for: one there
/// from the start takes the keyboard's focus as the popover opens, and the Pencil, near a field, writes into it
/// (Scribble) rather than dragging the slider. The Mac's bars keep their fields, which its keyboard and pointer suit.
struct HeaderValue: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var unit = ""
    var step: Double = 1
    /// What the slider covers, when that's less than `range` (everyday shape widths, say, short of the 5000 typing
    /// reaches); nil for a value with no natural span, such as a position, which only steps and takes typing.
    var slider: ClosedRange<Double>?
    /// Along a log scale, for sizes, where a small brush needs as much of the slider as a large one.
    var logarithmic = false
    var fractionDigits = 0
    /// The button shows only the value, where something beside it already names it (Expand's amount).
    var showsTitle = true
    /// Shown for 0 where it means something of its own: Leading's Auto.
    var zeroText: String?
    /// The value is done with: the slider let go, or the popover closed.
    var onEnd: () -> Void = {}
    @State private var open = false
    @State private var typing = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 5) {
                if showsTitle { Text(title).foregroundStyle(.secondary) }
                // As wide as the widest the value can read, so the button keeps its width as the number changes
                // (9 px to 10 px) rather than nudging everything after it along the bar.
                ZStack(alignment: .trailing) {
                    Text(text(for: widest)).hidden()
                    if let zeroText { Text(zeroText).hidden() }
                    Text(label).foregroundStyle(.primary)
                }
                .monospacedDigit()
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.white.opacity(0.08), in: Capsule())
            .frame(minHeight: TouchTarget.size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerHighlight()
        .accessibilityLabel(title)
        .accessibilityValue(label)
        .accessibilityIdentifier(title)
        .accessibilityAdjustableAction { direction in nudge(direction == .increment ? step : -step) }
        .popover(isPresented: $open) {
            editor
                .presentationCompactAdaptation(.popover)
                .onDisappear {
                    typing = false
                    onEnd()
                }
        }
    }

    private var label: String {
        if let zeroText, value.wrappedValue == 0 { return zeroText }
        return text(for: formatted(value.wrappedValue))
    }

    /// A number with its unit: "40 px", but "100%" and "45°".
    private func text(for number: String) -> String {
        number + (unit.isEmpty ? "" : (unit == "%" || unit == "°" ? unit : " " + unit))
    }

    /// The widest number in range, as digits all the same width: the sign, as many digits as the largest value has,
    /// and the decimals.
    private var widest: String {
        let digits = String(Int(max(abs(range.lowerBound), abs(range.upperBound)))).count
        let whole = (range.lowerBound < 0 ? "-" : "") + String(repeating: "8", count: digits)
        return fractionDigits > 0 ? whole + "." + String(repeating: "8", count: fractionDigits) : whole
    }

    private func formatted(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...fractionDigits)).grouping(.never))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                Text(label).font(.title3.monospacedDigit())
            }
            if let slider {
                Slider(value: sliderValue(slider), in: sliderBounds(slider)) { Text(title) } onEditingChanged: { editing in
                    if !editing { onEnd() }
                }
            }
            HStack(spacing: 10) {
                stepButton("minus", by: -step).accessibilityLabel("Less")
                if typing {
                    TextField(title, value: Binding(get: { value.wrappedValue }, set: { set($0) }),
                              format: .number.precision(.fractionLength(0...fractionDigits)).grouping(.never))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.center)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($fieldFocused)
                        .onAppear { fieldFocused = true }
                        .onSubmit {
                            typing = false
                            onEnd()
                        }
                        .onChange(of: fieldFocused) { _, focused in if !focused { typing = false } }
                } else {
                    Button { typing = true } label: {
                        Label("Type", systemImage: "keyboard").frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Type a value")
                }
                stepButton("plus", by: step).accessibilityLabel("More")
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func stepButton(_ symbol: String, by amount: Double) -> some View {
        Button { nudge(amount) } label: {
            Image(systemName: symbol).frame(width: 30, height: 30)
        }
        .buttonStyle(.bordered).buttonRepeatBehavior(.enabled)
    }

    private func nudge(_ amount: Double) {
        // From a value between steps, the first step lands on one.
        let stepped = ((value.wrappedValue + amount) / step).rounded() * step
        set(stepped)
    }

    private func set(_ number: Double) {
        guard number.isFinite else { return }
        value.wrappedValue = min(range.upperBound, max(range.lowerBound, number))
    }

    private func sliderBounds(_ span: ClosedRange<Double>) -> ClosedRange<Double> {
        logarithmic ? log(max(1e-6, span.lowerBound))...log(span.upperBound) : span
    }

    private func sliderValue(_ span: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: {
            let clamped = min(span.upperBound, max(span.lowerBound, value.wrappedValue))
            return logarithmic ? log(max(1e-6, clamped)) : clamped
        }, set: { position in
            let number = logarithmic ? exp(position) : position
            // To the field's own precision, so the slider never leaves a value the field can't show.
            let scale = pow(10, Double(fractionDigits))
            set((number * scale).rounded() / scale)
        })
    }
}

/// What the Pencil's pressure changes as the Brush paints, as a pill in the bar like the values beside it: Size,
/// Opacity, both, or Off.
struct PressureMenu: View {
    @Binding var pressure: BrushPressure

    var body: some View {
        Menu {
            Toggle("Size", isOn: option(.size))
            Toggle("Opacity", isOn: option(.opacity))
        } label: {
            HStack(spacing: 5) {
                Text("Pressure").foregroundStyle(.secondary)
                // As wide as the longest choice, so the pill keeps its width as they change.
                ZStack(alignment: .leading) {
                    Text("Size & Opacity").hidden()
                    Text(summary).foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.white.opacity(0.08), in: Capsule())
            .frame(minHeight: TouchTarget.size).contentShape(Rectangle())
        }
        .menuActionDismissBehavior(.disabled)
        .buttonStyle(.plain).pointerHighlight()
        .accessibilityLabel("Pencil pressure")
        .accessibilityValue(summary)
    }

    private var summary: String {
        switch (pressure.contains(.size), pressure.contains(.opacity)) {
        case (true, true): "Size & Opacity"
        case (true, false): "Size"
        case (false, true): "Opacity"
        case (false, false): "Off"
        }
    }

    private func option(_ option: BrushPressure) -> Binding<Bool> {
        Binding(get: { pressure.contains(option) },
                set: { on in if on { pressure.insert(option) } else { pressure.remove(option) } })
    }
}
