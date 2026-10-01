import SwiftUI

/// The iPad editor's toolbar: New and the project tabs on the left; undo, redo, Share, the menus and zoom on the right.
/// The menu bar has everything too, but a touch-first iPad may never open it, so what's used most is here as well.
/// The title is the project's file, as in Files: its menu renames, moves and duplicates it, and its header shares or
/// drags the project itself. Full Screen Canvas puts the toolbar away with the rest (see `FullScreenCanvas`).
struct EditorToolbar: ViewModifier {
    let session: EditorSession
    let workspace: ProjectWorkspace?
    let windowWidth: CGFloat
    let newCanvas: () -> Void
    private var projects: ProjectController? { workspace?.current.controller }
    private var title: String { workspace?.current.title ?? "Untitled" }
    @State private var renaming = false
    @State private var draftName = ""

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(FullScreenCanvas.shared.isOn ? .hidden : .automatic, for: .navigationBar)
            .statusBarHidden(FullScreenCanvas.shared.isOn)
            // Hung on a view of its own, so the editor isn't rebuilt when a new project is first saved.
            .background {
                if let url = session.projectURL { Color.clear.navigationDocument(url) }
            }
            .toolbarTitleMenu {
                Button("Rename…", systemImage: "pencil") {
                    draftName = title
                    renaming = true
                }
                .disabled(session.document == nil)
                Button("Move…", systemImage: "folder") { Task { await projects?.moveProject() } }
                    .disabled(session.document == nil)
                Button("Duplicate", systemImage: "plus.square.on.square") { Task { await projects?.duplicate() } }
                    .disabled(session.document == nil)
            }
            .alert("Rename Project", isPresented: $renaming) {
                TextField("Name", text: $draftName)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { Task { await projects?.rename(to: draftName) } }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { newCanvas() } label: { Label("New canvas", systemImage: "plus") }
                        .accessibilityIdentifier("newCanvasToolbar")
                        .disabled(session.isImporting || session.showsBusy || session.levels != nil)
                }
                if let workspace {
                    ToolbarItem(placement: .topBarLeading) {
                        PadTabStrip(workspace: workspace).frame(width: min(640, max(160, windowWidth - 700)))
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { session.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .disabled(!session.canUndo)
                    Button { session.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .disabled(!session.canRedo)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: SharedImage(session: session, name: title), preview: SharePreview(title)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(session.document == nil)
                    .accessibilityIdentifier("shareImage")
                    fileMenu
                    editMenu
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    zoomMenu
                    Button { FullScreenCanvas.shared.toggle() } label: {
                        Label("Full Screen Canvas", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(session.document == nil)
                    .accessibilityIdentifier("fullScreenCanvas")
                }
            }
    }

    private var fileMenu: some View {
        Menu {
            Button("Open Project…", systemImage: "folder") { Task { await projects?.open() } }
            if !RecentProjects.shared.urls.isEmpty {
                Menu("Open Recent", systemImage: "clock") {
                    ForEach(RecentProjects.shared.urls, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { Task { await projects?.open(url) } }
                    }
                }
            }
            Button("Import from Photos…", systemImage: "photo.on.rectangle") { Task { await projects?.importPhotos() } }
                .disabled(!canImport)
            Button("Import from Files…", systemImage: "folder.badge.plus") { session.showsImporter = true }
                .disabled(!canImport)
            Divider()
            // PNG, Photos and Files are all in Share; JPEG asks for a quality first.
            Button("Export JPEG…", systemImage: "square.and.arrow.up") { Task { await projects?.exportJPEG() } }
                .disabled(session.document == nil)
            Divider()
            Button("Canvas Size…") { Task { await projects?.canvasSize() } }.disabled(session.document == nil)
            Button("Image Size…") { Task { await projects?.imageSize() } }.disabled(session.document == nil)
            Button("Trim…") { Task { await projects?.trim() } }.disabled(session.document == nil)
            Divider()
            Button("Keyboard Shortcuts…", systemImage: "keyboard") { ShortcutSettings.shared.show() }
        } label: { Label("File", systemImage: "doc") }
    }

    /// The zoom commands under one button; pinching zooms too.
    private var zoomMenu: some View {
        Menu {
            Button("Fit Canvas", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { session.fit() }
            Button("Actual Pixels (100%)", systemImage: "1.magnifyingglass") { session.zoom(to: 1) }
            Divider()
            // Open still, to step again.
            Group {
                Button("Zoom In", systemImage: "plus.magnifyingglass") { session.zoomKeyboard(by: 1) }
                Button("Zoom Out", systemImage: "minus.magnifyingglass") { session.zoomKeyboard(by: -1) }
            }
            .menuActionDismissBehavior(.disabled)
        } label: { Label("Zoom", systemImage: "magnifyingglass") }
        .disabled(session.document == nil)
        .accessibilityIdentifier("zoomMenu")
    }

    private var canImport: Bool {
        session.levels == nil && !session.showsBusy && !session.isImporting && !session.showsNewDocument
    }

    private var editMenu: some View {
        Menu {
            Menu("Select") {
                Button("All") { session.selectAll() }.disabled(session.document == nil)
                Button("Deselect") { session.deselect() }.disabled(session.selection == nil || !session.canEditSelection)
                Button("Inverse") { session.invertSelection() }.disabled(session.selection == nil || !session.canEditSelection)
                Button("Subject") { Task { await session.selectSubject() } }.disabled(!session.canSelectSubject)
                Button("Color Range…") { session.beginColorRange() }.disabled(!session.canSelectColorRange)
                Divider()
                Button("Expand…") { session.promptSelectionAmount(.expand) }.disabled(!session.canModifySelection)
                Button("Contract…") { session.promptSelectionAmount(.contract) }.disabled(!session.canModifySelection)
                Button("Feather…") { session.promptSelectionAmount(.feather) }.disabled(!session.canModifySelection)
            }
            Menu("Adjustments") {
                Button("Curves…") { session.beginFilter(.curves) }.disabled(!session.canAdjustColors || session.hueSaturation != nil)
                Button("Levels…") { session.beginLevels() }.disabled(!session.canAdjustColors || session.hueSaturation != nil)
                Button("Hue/Saturation…") { session.beginHueSaturation() }.disabled(!session.canAdjustColors)
                ForEach([FilterKind.blackWhite, .colorBalance, .exposure, .gradientMap, .grain], id: \.self) { kind in
                    Button("\(kind.rawValue)…") { session.beginFilter(kind) }
                        .disabled(!session.canAdjustColors || session.hueSaturation != nil)
                }
                Button(session.isMaskSelected ? "Invert Mask" : "Invert") { Task { await session.invertPixels() } }
                    .disabled(!session.canInvert)
            }
            Menu("Filter") {
                ForEach(FilterKind.allCases.filter { $0 != .contentAwareFill && !$0.isImageAdjustment }, id: \.self) { kind in
                    Button("\(kind.rawValue)…") { session.beginFilter(kind) }
                        .disabled(!(kind == .vignette ? session.canVignette : session.canAdjustColors) || session.hueSaturation != nil)
                }
                Button("Content-Aware Fill…") { session.beginFilter(.contentAwareFill) }.disabled(!session.canContentAwareFill)
            }
            Divider()
            Button(session.canTransformSelection ? "Transform Selection" : "Transform Layer", systemImage: "skew") {
                session.transformCommand()
            }.disabled(!session.canTransform && !session.canTransformSelection)
            Button(session.selection == nil ? "Duplicate Layer" : "Layer via Copy", systemImage: "plus.square.on.square") {
                session.layerViaCopy()
            }.disabled(!session.canCopyPixels && !(session.selection == nil && session.canEditLayers && session.activeLayer != nil))
            Button("Fill with Foreground Color", systemImage: "paintbrush.pointed") { Task { await session.fillSelection(with: .foreground) } }
                .disabled(!session.canEditPixels)
            Button("Clear Selection Pixels", systemImage: "eraser") { Task { await session.clearSelectedPixels() } }
                .disabled(session.selection == nil || !session.canEditPixels)
            Divider()
            Button("Cut", systemImage: "scissors") {
                if session.selection != nil, session.canCopyPixels { Task { await session.cutSelection() } }
            }
            Button("Copy", systemImage: "doc.on.doc") {
                if session.canCopyPixels || session.canCopyLayer { session.copySelection() }
            }
            Button("Copy Merged") { session.copyMergedSelection() }.disabled(!session.canCopyMerged)
            Button("Paste", systemImage: "doc.on.clipboard") {
                if workspace?.pasteCopiedLayer() == true { } else if session.canPaste { session.paste() }
            }
        } label: { Label("Edit", systemImage: "ellipsis.circle") }
    }
}

/// The open projects, one pill each: tap to switch, the cross to close. A dot marks one with changes not yet saved.
private struct PadTabStrip: View {
    let workspace: ProjectWorkspace
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(workspace.tabs) { tab in
                    let active = workspace.selectedID == tab.id
                    HStack(spacing: 4) {
                        Button { workspace.select(tab.id) } label: {
                            HStack(spacing: 5) {
                                if tab.session.isModified {
                                    Circle().frame(width: 5, height: 5).accessibilityLabel("Unsaved changes")
                                }
                                Text(tab.title).font(.system(size: 13, weight: active ? .semibold : .medium)).lineLimit(1)
                            }
                            .padding(.leading, 12).frame(height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerHighlight().disabled(!workspace.canSwitch && !active)
                        Button { Task { await workspace.close(tab.id) } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                .frame(width: 36, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerHighlight().disabled(!workspace.canSwitch)
                        .accessibilityLabel("Close \(tab.title)")
                    }
                    // The pill is drawn smaller than the 44 points a fingertip needs to press it.
                    .background(Capsule().fill(Color.white.opacity(active ? 0.14 : 0.05)).frame(height: 32))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(active ? 0.22 : 0.08)).frame(height: 32))
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("Project tabs")
    }
}
