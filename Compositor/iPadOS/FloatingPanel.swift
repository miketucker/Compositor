import SwiftUI

/// A movable, non-modal panel for tool dialogs, as on the Mac: it never dims the editor, opens centered over it the
/// first time, and reopens wherever it was last left (for the app session). Its close button reports through
/// `onClose` so callers can treat it as Cancel. On iPad the panels are cards drawn over the editor by
/// `FloatingPanelsOverlay`, in the window's root view.
@MainActor
final class FloatingPanelController {
    let name: String
    var onClose: (() -> Void)?
    /// The width a docked panel (Camera Raw) is given, as on the Mac.
    static let dockedWidth: CGFloat = 440

    init(name: String) { self.name = name }

    func show(title: String, content: some View, placement: FloatingPanelPlacement = .automatic) {
        FloatingPanelHost.shared.show(FloatingPanelHost.Panel(name: name, title: title, content: AnyView(content),
                                                              placement: placement, close: { [weak self] in self?.userClosed() }))
    }

    /// Puts the panel away without reporting it: the caller is the one closing it.
    func close() { FloatingPanelHost.shared.remove(name) }

    var isVisible: Bool { FloatingPanelHost.shared.panels.contains { $0.name == name } }

    private func userClosed() {
        FloatingPanelHost.shared.remove(name)
        onClose?()
    }

    /// Nothing to do on iPad, where a panel doesn't take the keyboard away from the canvas.
    static func refocus(named name: String) {}
}

/// The panels open now, front to back in the order they were opened.
@MainActor @Observable
final class FloatingPanelHost {
    static let shared = FloatingPanelHost()

    struct Panel: Identifiable {
        let name: String
        var title: String
        var content: AnyView
        var placement: FloatingPanelPlacement
        let close: () -> Void
        var id: String { name }
    }
    private(set) var panels: [Panel] = []
    /// Where each panel's top-left corner was left, so it reopens there.
    var positions: [String: CGPoint] = [:]

    func show(_ panel: Panel) {
        if let index = panels.firstIndex(where: { $0.name == panel.name }) { panels[index] = panel }
        else { panels.append(panel) }
    }

    func remove(_ name: String) { panels.removeAll { $0.name == name } }

    func bringToFront(_ name: String) {
        guard let index = panels.firstIndex(where: { $0.name == name }), index != panels.count - 1 else { return }
        panels.append(panels.remove(at: index))
    }
}

/// Draws the open panels over the editor: each a card with a title bar to drag it by and a close button, or for a
/// docked panel, a column down the right side.
struct FloatingPanelsOverlay: View {
    let host = FloatingPanelHost.shared

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                ForEach(host.panels) { panel in
                    if panel.placement == .dockedToMainWindowRight {
                        PanelCard(panel: panel, docked: true)
                            .frame(width: FloatingPanelController.dockedWidth, height: proxy.size.height)
                            .offset(x: proxy.size.width - FloatingPanelController.dockedWidth)
                    } else {
                        PanelCard(panel: panel, docked: false, bounds: proxy.size)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }
}

private struct PanelCard: View {
    let panel: FloatingPanelHost.Panel
    let docked: Bool
    var bounds: CGSize = .zero
    @State private var size: CGSize = .zero
    @State private var dragStart: CGPoint?
    private var host: FloatingPanelHost { FloatingPanelHost.shared }

    /// Where the card sits: where it was left, else centered, kept on screen either way.
    private var origin: CGPoint {
        let saved = host.positions[panel.name]
            ?? CGPoint(x: (bounds.width - size.width) / 2, y: max(16, (bounds.height - size.height) / 3))
        return CGPoint(x: min(max(0, saved.x), max(0, bounds.width - size.width)),
                       y: min(max(0, saved.y), max(0, bounds.height - 44)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { panel.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerHighlight().foregroundStyle(.secondary)
                .accessibilityLabel("Close \(panel.title)")
                Spacer()
                Text(panel.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Color.clear.frame(width: 44, height: 44)
            }
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .gesture(docked ? nil : DragGesture(coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? origin
                    dragStart = start
                    host.positions[panel.name] = CGPoint(x: start.x + drag.translation.width, y: start.y + drag.translation.height)
                }
                .onEnded { _ in dragStart = nil })
            Divider()
            ScrollView {
                panel.content
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxHeight: docked ? .infinity : max(200, bounds.height - 32))
        .fixedSize(horizontal: !docked, vertical: !docked)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: docked ? 0 : 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: docked ? 0 : 14, style: .continuous).strokeBorder(Color.white.opacity(0.12))
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .offset(x: docked ? 0 : origin.x, y: docked ? 0 : origin.y)
        .simultaneousGesture(TapGesture().onEnded { host.bringToFront(panel.name) })
        .environment(\.colorScheme, .dark)
    }
}
