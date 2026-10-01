import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    /// The Layers panel's width, remembered across launches.
    @AppStorage("layersPanelWidth") private var layersPanelWidth = 252.0
    @Bindable var session: EditorSession
    /// The window's tabs, which this editor shows the current one of.
    var workspace: ProjectWorkspace? = nil
    private var projects: ProjectController? { workspace?.current.controller }
    @State private var canvasFrame: CGRect = .zero
    @State private var levelsPanel = FloatingPanelController(name: "levelsPanel")
    @State private var adjustmentPanel = FloatingPanelController(name: "adjustmentPanel")
    @State private var selectionAmountPanel = FloatingPanelController(name: "selectionAmountPanel")
    @State private var colorRangePanel = FloatingPanelController(name: "colorRangePanel")
    @State private var filterPanel = FloatingPanelController(name: "filterPanel")
    @State private var effectsPanel = FloatingPanelController(name: "effectsPanel")
    @State private var isDropTargeted = false
    /// The window's width, so the tab strip can use the toolbar's free space.
    @State private var windowWidth: CGFloat = 1180
    /// The editor is wider than it is tall: on iPad, the tool rail has room for two columns.
    @State private var landscape = false
    @Environment(\.scenePhase) private var scenePhase
    /// A layer dragged from this canvas's own tab has nowhere to go, so the canvas doesn't light up for it.
    private var acceptsDrop: Bool {
        guard let workspace else { return true }
        return workspace.canReceiveDrag(into: workspace.current.id)
    }
    // Extracted from `body`: as one expression the type checker times out (Xcode 26.1). Every tool has one, so the
    // editor draws the line under it; on iPad, Full Screen Canvas shows it in its own bar (see `FullScreenToolbar`).
    @ViewBuilder private var toolHeaders: some View {
        Group {
            if session.tool == .move {
                TransformInspector(session: session).id(session.activeLayerID)
            }
            if session.tool.isBrushTool {
                BrushControls(session: session)
            }
            if session.tool.isSelectionTool {
                LassoControls(session: session)
            }
            if session.tool == .gradient {
                GradientControls(session: session)
            }
            if session.tool == .type {
                TypeControls(session: session)
            }
            if session.tool == .shape {
                ShapeControls(session: session)
            }
            if session.tool == .eyedropper {
                HStack(spacing: 16) {
                    Text("Eyedropper").font(ToolHeaderStyle.titleFont)
                    Toggle("Sample Ring", isOn: $session.showsSampleRing).checkboxToggle()
                    Spacer()
                }.padding(.horizontal, 18).toolHeaderBar()
            }
            if session.tool == .hand || session.tool == .zoom {
                NavigationToolHeader(session: session)
            }
            if session.tool == .crop {
                CropControls(session: session)
            }
            // No tool (A) keeps the header, so the canvas doesn't jump.
            if session.tool == .idle {
                HStack(spacing: 16) {
                    Text("Select a tool").font(ToolHeaderStyle.titleFont)
                    Spacer()
                }.padding(.horizontal, 18).toolHeaderBar()
            }
        }
    }

    @ViewBuilder private var editorStack: some View {
        VStack(spacing: 0) {
            if showsChrome {
                toolHeaders
                Divider()
            }
            HStack(spacing: 0) {
                if showsChrome {
                    toolRail
                    Divider()
                }
                VStack(spacing: 0) {
                    if showsRulers {
                        HStack(spacing: 0) {
                            CanvasRulerCorner()
                            CanvasRulerView(session: session, axis: .horizontal)
                                .frame(height: CanvasRuler.thickness)
                        }
                    }
                    HStack(spacing: 0) {
                        if showsRulers {
                            CanvasRulerView(session: session, axis: .vertical)
                                .frame(width: CanvasRuler.thickness)
                        }
                        ZStack {
                            EditorCanvas(session: session)
                            if session.document == nil { welcome }
                            if let layer = session.maskAloneLayer {
                                // At the foot of the canvas, clear of the transform box's rotation handle.
                                MaskAloneBadge(session: session, layer: layer).fixedSize()
                                    .padding(.bottom, 14)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            }
                            #if !os(macOS)
                            if FullScreenCanvas.shared.isOn { fullScreenControls }
                            if session.document != nil, !HardwareKeyboard.shared.isConnected {
                                // Where the thumb of the hand not holding the Pencil rests.
                                TouchShortcut()
                                    .frame(width: TouchShortcut.size, height: TouchShortcut.size)
                                    .padding(20)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                            }
                            #endif
                        }
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("editor")) } action: { canvasFrame = $0 }
                    }
                }
                if showsChrome {
                    PanelResizeEdge(width: $layersPanelWidth, range: LayersPanel.widths)
                    LayersPanel(session: session, width: layersPanelWidth)
                }
            }
            if showsChrome {
                Divider()
                // Keeps its own height however short the window gets; the tools scroll instead.
                statusBar.fixedSize(horizontal: false, vertical: true)
                    .modifier(WidthReader(width: $windowWidth))
            }
        }
        #if !os(macOS)
        .onGeometryChange(for: Bool.self) { $0.size.width > $0.size.height } action: { landscape = $0 }
        #endif
    }

    #if !os(macOS)
    /// Across the top of the canvas in Full Screen Canvas: the tool's options, in a bar that opens out from the tool,
    /// and the way back.
    @ViewBuilder private var fullScreenControls: some View {
        // Clear of the way back on the right, and centered between that and the matching space on the left.
        FullScreenToolbar(session: session) { toolHeaders }
            .padding(.horizontal, 76).padding(.top, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        ExitFullScreenButton()
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
    #endif

    /// The bars, panels and tool rail around the canvas, which Full Screen Canvas puts away on iPad.
    private var showsChrome: Bool {
        #if os(macOS)
        true
        #else
        !FullScreenCanvas.shared.isOn
        #endif
    }
    private var showsRulers: Bool { session.showsRulers && session.document != nil && showsChrome }

    // Split again for 1.1: the chain outgrew the type checker once more.
    @ViewBuilder private var editorChrome: some View {
        editorStack
        .background(Color(white: 0.14))
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 520)
        #endif
        .coordinateSpace(name: "editor")
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, ProjectWorkspace.layerType], isTargeted: $isDropTargeted) { providers, location in
            guard session.levels == nil, !session.isProjectBusy, !session.showsNewDocument, !session.showsImporter, session.renamingLayerID == nil else { return false }
            let point: CGPoint?
            if let document = session.document, canvasFrame.contains(location) {
                point = session.viewport.documentPoint(
                    from: CGPoint(x: location.x - canvasFrame.minX, y: location.y - canvasFrame.minY),
                    documentSize: document.size)
            } else { point = nil }
            if let workspace {
                let destination = workspace.current.id
                guard workspace.canSwitch, workspace.canReceiveDrag(into: destination) else { return false }
                Task { await workspace.receiveProviders(providers, into: destination, at: point) }
            } else {
                Task { await ImageFileDrop.importProviders(providers, into: session, at: point) }
            }
            return true
        }
        .overlay {
            if isDropTargeted, acceptsDrop {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 3)
                    .frame(width: max(0, canvasFrame.width - 6), height: max(0, canvasFrame.height - 6))
                    .position(x: canvasFrame.midX, y: canvasFrame.midY)
                    .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .modifier(EditorToolbar(session: session, workspace: workspace, windowWidth: windowWidth, newCanvas: requestNewCanvas))
    }

    var body: some View {
        editorChrome
        .modifier(ColorPickerPresenter(session: session))
        // Plugins load as the editor opens, and again as the app comes back with something changed in the Plugins
        // folder: one dropped in from the Finder or Files.
        .task { await PluginRegistry.shared.reloadIfChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await PluginRegistry.shared.reloadIfChanged() } }
        }
        .onChange(of: session.levels == nil) { _, closed in
            if closed { levelsPanel.close() }
            else {
                levelsPanel.onClose = { session.cancelLevels() }
                levelsPanel.show(title: "Levels", content: LevelsSheet(session: session))
            }
        }
        .onChange(of: session.colorRange == nil) { _, closed in
            if closed { colorRangePanel.close() }
            else {
                colorRangePanel.onClose = { session.cancelColorRange() }
                colorRangePanel.show(title: "Color Range", content: ColorRangeSheet(session: session))
            }
        }
        .onChange(of: session.hueSaturation == nil) { _, closed in
            if closed { adjustmentPanel.close() }
            else {
                adjustmentPanel.onClose = { session.cancelHueSaturation() }
                adjustmentPanel.show(title: "Hue/Saturation", content: HueSaturationSheet(session: session))
            }
        }
        .onChange(of: session.effectsEditing) { _, selection in
            if let selection {
                effectsPanel.onClose = { session.finishEffectsEditing(commit: false) }
                effectsPanel.show(title: selection.kind.rawValue, content: EffectsSheet(session: session, kind: selection.kind))
            } else { effectsPanel.close() }
        }
        .onChange(of: session.document?.layers) { _, layers in
            if let editing = session.effectsEditing,
               layers?.first(where: { $0.id == editing.layerID })?.effects?.contains(editing.kind) != true {
                if let picker = session.colorPicker, case .effect = picker.target { session.closeColorPicker(commit: false) }
                session.effectsEditing = nil
                session.effectsEditingOriginal = nil
            }
        }
        .onChange(of: session.selectionAmountOperation) { _, operation in
            if let operation {
                selectionAmountPanel.onClose = { session.selectionAmountOperation = nil }
                selectionAmountPanel.show(title: operation.rawValue + " Selection",
                    content: SelectionAmountSheet(session: session, operation: operation))
            } else { selectionAmountPanel.close() }
        }
        .onChange(of: session.filterEdit == nil) { _, closed in
            if closed { filterPanel.close() }
            else {
                filterPanel.onClose = { session.cancelFilter() }
                let placement: FloatingPanelPlacement = session.filterEdit?.kind == .cameraRaw ? .dockedToMainWindowRight : .automatic
                filterPanel.show(title: session.filterEdit?.kind.rawValue ?? "Filter", content: FilterSheet(session: session),
                                 placement: placement)
            }
        }
        .onChange(of: session.document == nil) { _, empty in
            if !empty { session.canvasFocusRequest += 1 }
        }
        .fileImporter(isPresented: $session.showsImporter,
                      allowedContentTypes: UTType.importableImages, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await session.importImages(urls) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { session.importError = error.localizedDescription }
            }
        }
        .alert("Import couldn’t finish", isPresented: Binding(
            get: { session.importError != nil }, set: { if !$0 { session.importError = nil } })) {
                // No cancel role: an alert with only a cancel button gets a second OK of its own.
                Button("OK") { session.importError = nil }
            } message: { Text(session.importError ?? "") }
        .alert("Couldn’t paint", isPresented: Binding(get: { session.brushError != nil },
            set: { if !$0 { session.brushError = nil } })) {
                Button("OK") { session.brushError = nil }
            } message: { Text(session.brushError ?? "") }
        .alert("Couldn’t crop", isPresented: Binding(get: { session.cropError != nil },
            set: { if !$0 { session.cropError = nil } })) {
                Button("OK") { session.cropError = nil }
            } message: { Text(session.cropError ?? "") }
    }
    private func requestNewCanvas() {
        if let projects { Task { await projects.newCanvas() } }
        else { session.clearProject() }
    }
    private var toolRail: some View {
        // Scrolls when the window is too short for every tool, rather than pushing the bars above and below away.
        IndicatorlessScrollView {
        VStack(spacing: railSpacing) {
            let tools = NavigationTool.allCases.filter { $0 != .idle }
            if railColumns == 2 {
                // Read across, then down, as Photoshop's two-column toolbar is.
                Grid(horizontalSpacing: railSpacing, verticalSpacing: railSpacing) {
                    ForEach(Array(stride(from: 0, to: tools.count, by: 2)), id: \.self) { row in
                        GridRow {
                            ForEach(tools[row..<min(row + 2, tools.count)], id: \.self) { toolButton($0) }
                        }
                    }
                }
            } else {
                ForEach(tools, id: \.self) { toolButton($0) }
            }
            ColorPaletteControls(session: session).padding(.top, 8)
        }
        .padding(.top, 16).padding(.bottom, 12)
        .frame(width: railWidth)
        }
        .frame(width: railWidth)
    }
    private func toolButton(_ tool: NavigationTool) -> some View {
        Button { session.selectTool(tool) } label: {
            ToolIcon(tool: tool, session: session)
            .frame(width: 36, height: 36)
                .background(session.tool == tool ? Color.white.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(session.tool == tool ? Color.white.opacity(0.14) : .clear)
                }
                .frame(minWidth: TouchTarget.size, minHeight: TouchTarget.size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointerHighlight().help(tool.label).accessibilityLabel(tool.label)
        .foregroundStyle(.primary)
        .accessibilityAddTraits(session.tool == tool ? .isSelected : [])
    }
    /// The rail keeps the Mac's spacing between its buttons however large they have to be to press.
    private var railSpacing: CGFloat { 10 - max(0, TouchTarget.size - 36) }
    /// Two columns in a landscape iPad window, where one would run past the foot of the screen and have to scroll.
    private var railColumns: Int {
        #if os(macOS)
        1
        #else
        landscape ? 2 : 1
        #endif
    }
    private var railWidth: CGFloat { railColumns == 2 ? 56 + TouchTarget.size + railSpacing : 56 }
    private var welcome: some View {
        NewCanvasSheet(session: session,
            onCreate: { session.createNewProject(width: $0, height: $1) },
            onOpen: { Task { await projects?.open() } })
    }
    /// What the tool does, and how: with the keyboard's keys on the Mac, and on iPad while a keyboard is attached;
    /// otherwise by touch.
    private var statusHint: String {
        #if os(macOS)
        keyHint
        #else
        HardwareKeyboard.shared.isConnected ? keyHint : session.touchHint
        #endif
    }
    private var keyHint: String {
        session.tool == .marquee ? (session.marqueeKind == .ellipse ? "Drag an ellipse · Shift add · Option subtract · Shift again mid-drag circle · Drag inside to move · Delete clears · ⌘D deselect" : "Drag a rectangle · Shift add · Option subtract · Shift again mid-drag square · Drag inside to move · ⌘-drag moves pixels · Delete clears · ⌘D deselect") : session.tool == .wand ? (session.wandMode == .object ? "Click an object to select its outline · Tab for Wand · Shift add · Option subtract · Drag inside to move · ⌘-drag moves pixels · Delete clears · ⌘D deselect" : "Click to select similar colors · Tab for Object · Shift add · Option subtract · Drag inside to move · ⌘-drag moves pixels · Delete clears · ⌘D deselect") : session.tool == .lasso ? (session.lassoKind == .freehand ? "Drag to select · Drag inside to move · Shift add · Option subtract · Delete clears · ⌥⌫/⌘⌫ fill · ⌘D deselect" : "Click corners · Click start, double-click or Enter to close · Delete removes corner · Escape cancel") : session.tool == .brush ? (session.brushMode == .erase ? "Drag to erase" : "Drag to paint") + " · [ ] size · Shift-[ ] hardness · 1–0 opacity · Escape cancel · Space to pan" : session.tool == .blur ? (session.blurMode == .blur ? "Drag to soften" : session.blurMode == .smudge ? "Drag to smudge" : "Drag to push pixels") + " · [ ] size · Shift-[ ] hardness · 1–0 strength · Space to pan" : session.tool == .cloneStamp ? "Option-click to set the source · Drag to clone · [ ] size · Shift-[ ] hardness · 1–0 opacity · Space to pan" : session.tool == .spotHealing ? "Drag over blemishes to heal · [ ] size · Shift-[ ] hardness · Escape cancel · Space to pan" : session.tool == .type ? "Drag a text box · Click text to edit · Drag box handles to resize · ⌘Return finish · Escape cancel" : session.tool == .shape ? "Drag to draw a shape on a new layer · Shift \(session.shapeKind == .line ? "45°" : session.shapeKind == .rectangle ? "square" : "circle") · Option from center · Shift-U or Tab for the next shape · Escape cancel · Space to pan" : session.tool == .gradient ? "Drag to draw · Drag ends to adjust · Shift 45° · 1–0 opacity · Enter apply · Escape cancel" : session.tool == .crop ? "Drag to crop · Enter apply · Escape cancel · Space to pan" : session.tool == .move ? "Drag to move · Handles to resize · Circle to rotate · 1–0 layer opacity · Space to pan" : session.tool == .hand ? "Drag to pan · Pinch to zoom" : session.tool == .idle ? "No tool selected · Press a tool's key to pick one · Space to pan" : "Click to zoom in · Option-click to zoom out · Drag right or left to zoom smoothly · Space to pan"
    }
    private var statusBar: some View {
        HStack(spacing: 16) {
            if let document = session.document {
                Text(session.viewport.zoom, format: .percent.precision(.fractionLength(0...1)))
                    .frame(width: 62, alignment: .leading).accessibilityIdentifier("zoomStatus")
                Text("\(document.width) × \(document.height) px").accessibilityIdentifier("canvasDimensions")
                Text("sRGB · Transparent")
            } else { Text("Ready when you are") }
            Spacer()
            if session.showsBusy {
                ProgressView().controlSize(.mini)
                Text("Working…")
            } else if session.isImporting {
                ProgressView().controlSize(.mini)
                Text("Importing images…")
            } else {
                Text(statusHint)
            }
        }
        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        .padding(.horizontal, 18).frame(height: 30)
        .accessibilityElement(children: .contain)
    }
}

/// A panel's divider that resizes the panel to its right: drag left to widen, right to narrow, within `range`.
private struct PanelResizeEdge: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Divider().overlay {
            Color.clear.frame(width: 8).contentShape(Rectangle())
                #if os(macOS)
                .pointerStyle(.columnResize)
                #endif
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(range.upperBound, max(range.lowerBound, (start - value.translation.width).rounded()))
                    }
                    .onEnded { _ in startWidth = nil })
                .help("Drag to resize the panel")
        }
    }
}

extension View {
    /// Bordered buttons and pop-up menus drawn as capsules throughout the app. Borderless and plain buttons (the tool
    /// rail, the Layers panel footer) have no border to shape, so they're unaffected.
    func roundedControls() -> some View { buttonBorderShape(.capsule) }
}

extension View {
    /// Return or Escape in a property field gives up its focus and hands it back to the canvas, so a tool's key
    /// works straight away instead of typing into the field.
    func releasesFocusOnCommit(_ session: EditorSession) -> some View {
        onSubmit { session.canvasFocusRequest += 1 }
            .onEscape { session.canvasFocusRequest += 1 }
    }
}

/// What a field's key monitor reads. The monitor outlives the view value that installed it, so reading the value
/// and applying the step go through here, refreshed on every redraw.
@MainActor final class ArrowStepper {
    var editing = false
    var value: () -> Double = { 0 }
    var change: (Double) -> Void = { _ in }
    private var monitor: Any?

    /// Takes Up and Down while the field holds focus: one step, or ten with Shift.
    func listen(step: Double) {
        #if os(macOS)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only while a field really is being edited: a field left behind (its tool bar swapped out, say) must not
            // keep taking Up and Down from the canvas, where they nudge the layer.
            guard let self, self.editing, event.keyCode == 126 || event.keyCode == 125,
                  NSApp.keyWindow?.firstResponder is NSTextView else { return event }
            let amount = step * (event.modifierFlags.contains(.shift) ? 10 : 1)
            self.change(self.value() + (event.keyCode == 126 ? amount : -amount))
            return nil
        }
        #endif
    }
    func stopListening() {
        #if os(macOS)
        if let monitor { NSEvent.removeMonitor(monitor) }
        #endif
        monitor = nil
        editing = false
    }
    deinit {
        #if os(macOS)
        if let monitor { NSEvent.removeMonitor(monitor) }
        #endif
    }
}

/// Up and Down nudge the value in a focused property field, Shift by ten times as much — a text field takes the
/// arrow keys for its insertion point, so they are caught while it holds focus.
private struct ArrowStepping: ViewModifier {
    let step: Double
    let value: () -> Double
    let change: (Double) -> Void
    @FocusState private var focused: Bool
    @State private var stepper = ArrowStepper()
    func body(content: Content) -> some View {
        content
            .focused($focused)
            .onChange(of: focused) { _, editing in
                stepper.editing = editing
                editing ? stepper.listen(step: step) : stepper.stopListening()
            }
            .onDisappear { stepper.stopListening() }
            .onAppear { refresh() }
            .onChange(of: value()) { _, _ in refresh() }
    }
    private func refresh() {
        stepper.value = value
        stepper.change = change
    }
}

extension View {
    /// Up and Down step this field's value; each field's own binding keeps it in range.
    func arrowSteps(_ step: Double = 1, value: @escaping () -> Double, change: @escaping (Double) -> Void) -> some View {
        modifier(ArrowStepping(step: step, value: value, change: change))
    }
    /// The same, for a field that already owns its focus: it says when it is being edited.
    func arrowSteps(_ step: Double = 1, editing: Bool, stepper: ArrowStepper,
                    value: @escaping () -> Double, change: @escaping (Double) -> Void) -> some View {
        onAppear { stepper.value = value; stepper.change = change }
            .onChange(of: value()) { _, _ in stepper.value = value; stepper.change = change }
            .onChange(of: editing) { _, active in
                stepper.editing = active
                stepper.value = value
                stepper.change = change
                active ? stepper.listen(step: step) : stepper.stopListening()
            }
            .onDisappear { stepper.stopListening() }
    }
}

/// Reports the width it is laid out at. Kept out of the editor's body, whose type-checking is already near its limit.
private struct WidthReader: ViewModifier {
    @Binding var width: CGFloat
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

/// A tool's icon, as the tool rail shows it: following the tool's mode, where that changes what it does.
struct ToolIcon: View {
    let tool: NavigationTool
    let session: EditorSession
    var body: some View {
        if tool == .gradient { GradientToolIcon().frame(width: 18, height: 18) }
        else if tool == .cloneStamp { CloneStampToolIcon().frame(width: 18, height: 18) }
        else if tool == .lasso, session.lassoKind == .polygonal { PolygonalLassoToolIcon().frame(width: 18, height: 18) }
        else if tool == .wand, session.wandMode == .object { ObjectSelectionToolIcon().frame(width: 18, height: 18) }
        // The Marquee's icon follows its shape: a dashed circle in Ellipse mode.
        else { Image(systemName: tool == .marquee && session.marqueeKind == .ellipse ? "circle.dashed" : session.symbol(for: tool)).font(.system(size: 17)) }
    }
}
