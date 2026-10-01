import SwiftUI

/// Shared metrics keep tool switching from changing typography or canvas layout.
enum ToolHeaderStyle {
    #if os(macOS)
    static let height: CGFloat = 42
    #else
    /// Room for a control a fingertip can press.
    static let height: CGFloat = 44
    #endif
    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let controlFont = Font.system(size: 12)
}

extension View {
    /// Keeps a unit ("%", "px") tight against its field so the two read as one value,
    /// regardless of the wider spacing between controls in a bar.
    func unitSuffix(_ unit: String) -> some View {
        HStack(spacing: 2) {
            self
            Text(unit)
        }
    }

    /// Lets a field without a separate label use its unit as the drag target.
    func unitSuffix<Value: BinaryFloatingPoint>(_ unit: String, scrubValue: Binding<Value>,
                                                sensitivity: Value, range: ClosedRange<Value>, step: Value? = nil) -> some View {
        HStack(spacing: 2) {
            self
            Text(unit).scrubbable(sensitivity: sensitivity, value: scrubValue, range: range, step: step)
        }
    }

    func unitSuffix(_ unit: String, scrubValue: Binding<Int>, sensitivity: Double,
                    range: ClosedRange<Int>) -> some View {
        HStack(spacing: 2) {
            self
            Text(unit).scrubbable(sensitivity: sensitivity, value: scrubValue, range: range)
        }
    }

    func toolHeaderBar() -> some View {
        #if os(macOS)
        font(ToolHeaderStyle.controlFont)
            .controlSize(.regular)
            .frame(height: ToolHeaderStyle.height)
            .fixedSize(horizontal: false, vertical: true)
        #else
        modifier(ScrollingToolHeader())
        #endif
    }
}

#if !os(macOS)
/// A tool's options on iPad, where they can be wider than the window: they scroll sideways rather than squeezing their
/// labels onto two lines, and fill the bar (so its spacers still push controls apart) when they fit. iPad's switches
/// are too big for a bar of options, so a toggle here is a button that stays lit when on.
private struct ScrollingToolHeader: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                content
                    .font(ToolHeaderStyle.controlFont)
                    .controlSize(.regular)
                    .toggleStyle(.button)
                    .lineLimit(1)
                    .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(height: ToolHeaderStyle.height)
    }
}
#endif

/// Options that scroll sideways within a tool's bar when they don't fit. On iPad the whole bar scrolls (see
/// `toolHeaderBar`), so they're laid out in it as they are.
struct HeaderOverflow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        #if os(macOS)
        ScrollView(.horizontal) { content }.scrollIndicators(.hidden)
        #else
        content
        #endif
    }
}
