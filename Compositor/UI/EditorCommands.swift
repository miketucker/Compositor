import SwiftUI

/// The menus, and their keyboard shortcuts, for the project on screen: the Mac's menu bar, and iPad's (the menu bar
/// iPadOS shows from the top of the screen, and the shortcuts a hardware keyboard lists when Command is held).
struct EditorCommands: Commands {
    let workspace: ProjectWorkspace
    /// Brings the editor's window back when it's closed (the Mac's File menu works without one).
    var showEditor: () -> Void = {}
    private var session: EditorSession { workspace.current.session }
    private var projects: ProjectController { workspace.current.controller }

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            // Dialog text fields keep native text undo; document history
            // is unavailable while an import or modal edit is active.
            if session.textDraft != nil || session.levels != nil || session.isProjectBusy || session.showsNewDocument || session.showsImporter || session.renamingLayerID != nil || session.transformEdit?.persistent == true {
                Button("Undo") { TextEditing.undo() }
                    .configuredKeyboardShortcut("z")
                Button("Redo") { TextEditing.redo() }
                    .configuredKeyboardShortcut("z", modifiers: [.command, .shift])
            } else {
                Button(session.history.canUndo ? "Undo \(session.history.undoName)" : "Undo") { session.undo() }
                    .configuredKeyboardShortcut("z").disabled(!session.canUndo)
                Button(session.history.canRedo ? "Redo \(session.history.redoName)" : "Redo") { session.redo() }
                    .configuredKeyboardShortcut("z", modifiers: [.command, .shift]).disabled(!session.canRedo)
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Canvas…") {
                showEditor()
                Task { await projects.newCanvas() }
            }.configuredKeyboardShortcut("n")
                .disabled(!projects.canStart)
            Button("Open Project…") {
                showEditor()
                Task { await projects.open() }
            }
                .configuredKeyboardShortcut("o").disabled(!projects.canStart)
            Menu("Open Recent") {
                ForEach(RecentProjects.shared.urls, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        showEditor()
                        Task { await projects.open(url) }
                    }
                }
                Divider()
                Button("Clear Menu") { RecentProjects.shared.clear() }
                    .disabled(RecentProjects.shared.urls.isEmpty)
            }
                .disabled(!projects.canStart)
            Button("Import Images…") { session.showsImporter = true }
                .disabled(session.levels != nil || session.showsBusy || session.isImporting || session.showsNewDocument)
        }
        #if os(macOS)
        CommandGroup(replacing: .saveItem) {
            Button("Save") { Task { await projects.save() } }
                .configuredKeyboardShortcut("s").disabled(session.document == nil || !projects.canStart)
            Button("Save As…") { Task { await projects.save(asNew: true) } }
                .configuredKeyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(session.document == nil || !projects.canStart)
            Divider()
            Button("Export PNG…") { Task { await projects.exportPNG() } }
                .configuredKeyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session.document == nil || !projects.canStart)
            Button("Export JPEG…") { Task { await projects.exportJPEG() } }
                .configuredKeyboardShortcut("s", modifiers: [.command, .option, .shift])
                .disabled(session.document == nil || !projects.canStart)
            Divider()
            Button("Close Project") {
                if let window = projects.window {
                    Task { await projects.close(window) }
                }
            }.configuredKeyboardShortcut("w").disabled(!projects.canStart)
        }
        #else
        CommandGroup(replacing: .saveItem) {
            // iPad saves as it goes, so there is no Save: what's left is getting pictures in and out.
            Button("Import from Photos…") { Task { await projects.importPhotos() } }
                .disabled(session.levels != nil || session.showsBusy || session.isImporting || session.showsNewDocument)
            Divider()
            Button("Export PNG…") { Task { await projects.exportPNG() } }
                .configuredKeyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(session.document == nil || !projects.canStart)
            Button("Export JPEG…") { Task { await projects.exportJPEG() } }
                .configuredKeyboardShortcut("s", modifiers: [.command, .option, .shift])
                .disabled(session.document == nil || !projects.canStart)
            Button("Save to Photos") { Task { await projects.saveToPhotos() } }
                .disabled(session.document == nil || !projects.canStart)
            Divider()
            Button("Close Project") { Task { await workspace.close(workspace.current.id) } }
                .configuredKeyboardShortcut("w").disabled(!projects.canStart)
        }
        #endif
        CommandGroup(after: .toolbar) {
            // With a dialog's preview open (Export JPEG), these zoom that preview rather than the canvas.
            Button("Fit Canvas") {
                if let preview = session.previewZoom { preview(.fit) } else { session.fit() }
            }.configuredKeyboardShortcut("0").disabled(session.document == nil)
            Button("Actual Pixels") {
                if let preview = session.previewZoom { preview(.actual) } else { session.zoom(to: 1) }
            }.configuredKeyboardShortcut("1").disabled(session.document == nil)
            Button("Zoom In") {
                guard !TextEditing.isActive else { return }
                if let preview = session.previewZoom { preview(.zoomIn) } else { session.zoomKeyboard(by: 1) }
            }
                .configuredKeyboardShortcut("=").disabled(session.document == nil)
            Button("Zoom Out") {
                guard !TextEditing.isActive else { return }
                if let preview = session.previewZoom { preview(.zoomOut) } else { session.zoomKeyboard(by: -1) }
            }
                .configuredKeyboardShortcut("-").disabled(session.document == nil)
            #if !os(macOS)
            Toggle("Full Screen Canvas", isOn: Binding(get: { FullScreenCanvas.shared.isOn },
                                                       set: { FullScreenCanvas.shared.isOn = $0 }))
                .configuredKeyboardShortcut("f", modifiers: [.command, .control])
                .disabled(session.document == nil && !FullScreenCanvas.shared.isOn)
            #endif
            Toggle("Pixel Grid (800% and above)", isOn: Binding(get: { session.showsPixelGrid },
                                                                  set: { session.showsPixelGrid = $0 }))
            Toggle("Snap", isOn: Binding(get: { session.snappingEnabled },
                                         set: { session.snappingEnabled = $0 }))
            Toggle("Show Transform Controls", isOn: Binding(get: { session.showsTransformControls },
                                                              set: { session.showsTransformControls = $0 }))
                .configuredKeyboardShortcut("h").disabled(session.tool != .move || session.document == nil)
            Group {
                Divider()
                Menu("Show") {
                    Toggle("Grid", isOn: Binding(get: { session.showsGrid }, set: { session.showsGrid = $0 }))
                        .configuredKeyboardShortcut("'").disabled(session.document == nil)
                    Toggle("Guides", isOn: Binding(get: { session.showsGuides }, set: { session.showsGuides = $0 }))
                        .configuredKeyboardShortcut(";").disabled(session.document == nil)
                }
                Button("Grid Settings…") { Task { await projects.gridSettings() } }
                    .disabled(session.document == nil)
                Toggle("Rulers", isOn: Binding(get: { session.showsRulers }, set: { session.showsRulers = $0 }))
                    .configuredKeyboardShortcut("r").disabled(session.document == nil)
                Divider()
                Toggle("Snap", isOn: Binding(get: { session.snapEnabled }, set: { session.snapEnabled = $0 }))
                    .configuredKeyboardShortcut(";", modifiers: [.command, .shift]).disabled(session.document == nil)
                Menu("Snap To") {
                    Toggle("Guides", isOn: Binding(get: { session.snapToGuides }, set: { session.snapToGuides = $0 }))
                        .disabled(session.document == nil)
                    Toggle("Grid", isOn: Binding(get: { session.snapToGrid }, set: { session.snapToGrid = $0 }))
                        .disabled(session.document == nil)
                    Toggle("Layers", isOn: Binding(get: { session.snapToLayers }, set: { session.snapToLayers = $0 }))
                        .disabled(session.document == nil)
                    Toggle("Document Bounds", isOn: Binding(get: { session.snapToDocumentBounds },
                                                            set: { session.snapToDocumentBounds = $0 }))
                        .disabled(session.document == nil)
                }
                Divider()
                Toggle("Lock Guides", isOn: Binding(get: { session.locksGuides }, set: { session.locksGuides = $0 }))
                    .configuredKeyboardShortcut(";", modifiers: [.command, .option]).disabled(session.document == nil)
                Button("Clear Guides") { session.clearGuides() }
                    .disabled(!session.canClearGuides)
            }
        }
        CommandGroup(replacing: .pasteboard) {
            // Canvas pixels when the canvas has focus; text fields keep their own editing.
            // Cut, Copy and Paste check when chosen rather than through .disabled: what they depend on
            // (the pasteboard, the copied pixels, the busy flag) isn't observed, so a disabled state could
            // go stale — the first Paste after a Copy used to beep until something else refreshed the menu.
            Button("Cut") {
                if TextEditing.cut() {}
                else if session.selection != nil, session.canCopyPixels { Task { await session.cutSelection() } }
                else { Feedback.beep() }
            }
                .configuredKeyboardShortcut("x")
            Button("Copy") {
                if TextEditing.copy() {}
                else if session.canCopyPixels || session.canCopyLayer { session.copySelection() }
                else { Feedback.beep() }
            }
                .configuredKeyboardShortcut("c")
            Button("Copy Merged") { session.copyMergedSelection() }
                .configuredKeyboardShortcut("c", modifiers: [.command, .shift]).disabled(!session.canCopyMerged)
            Button("Paste") {
                if TextEditing.paste() {}
                else if workspace.pasteCopiedLayer() { }
                else if session.canPaste { session.paste() }
                else { Feedback.beep() }
            }
                .configuredKeyboardShortcut("v")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Keyboard Shortcuts…") { ShortcutSettings.shared.show() }
            Button("Plugins…") { PluginsPanel.shared.show() }
            // Photoshop's fill shortcuts; in a text field they keep their text meaning.
            Button("Fill with Foreground Color") {
                if TextEditing.isActive { TextEditing.deleteWordBackward() }
                else { Task { await session.fillSelection(with: .foreground) } }
            }
                .configuredKeyboardShortcut(.delete, modifiers: .option).disabled(!session.canEditPixels)
            Button("Fill with Background Color") {
                if TextEditing.isActive { TextEditing.deleteToBeginningOfLine() }
                else { Task { await session.fillSelection(with: .background) } }
            }
                .configuredKeyboardShortcut(.delete, modifiers: .command).disabled(!session.canEditPixels)
            Button("Clear Selection Pixels") { Task { await session.clearSelectedPixels() } }
                .disabled(session.selection == nil || !session.canEditPixels)
            Button("Content-Aware Fill…") { session.beginFilter(.contentAwareFill) }
                .configuredKeyboardShortcut(.delete, modifiers: .shift).disabled(!session.canContentAwareFill)
        }
        CommandMenu("Select") {
            // A field being edited keeps its own Select All: offer it to the responder chain
            // first, which covers every kind of text control rather than NSTextView alone,
            // and select the canvas only when nothing there wanted it.
            Button("All") {
                if TextEditing.selectAll() { return }
                guard session.document != nil else { return }
                session.selectAll()
            }
                // Never disabled: on macOS this menu item is what binds Cmd-A to selectAll:, so
                // switching it off takes Select All away from every text field too. With no
                // document and nothing being edited the action simply does nothing.
                .configuredKeyboardShortcut("a")
            Button("Deselect") { session.deselect() }
                .configuredKeyboardShortcut("d").disabled(session.selection == nil || !session.canEditSelection)
            Button("Inverse") { session.invertSelection() }
                .configuredKeyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(session.selection == nil || !session.canEditSelection)
            Button("Layer's Pixels") {
                if let id = session.activeLayerID { session.loadLayerSelection(layerID: id) }
            }
                .disabled(session.activeLayer?.asset == nil || !session.canEditSelection)
            Button("Subject") { Task { await session.selectSubject() } }
                .configuredKeyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!session.canSelectSubject)
            Button("Color Range…") { session.beginColorRange() }
                .disabled(!session.canSelectColorRange)
            Button("Mask's Black Areas") {
                if let id = session.activeLayerID { session.loadMaskSelection(layerID: id) }
            }
                .disabled(session.activeLayer?.mask == nil || !session.canEditSelection)
            Divider()
            Button("Expand…") { session.promptSelectionAmount(.expand) }
                .disabled(!session.canModifySelection)
            Button("Contract…") { session.promptSelectionAmount(.contract) }
                .disabled(!session.canModifySelection)
            Button("Feather…") { session.promptSelectionAmount(.feather) }
                .disabled(!session.canModifySelection)
        }
        CommandMenu("Image") {
            Button("Curves…") { session.beginFilter(.curves) }
                .configuredKeyboardShortcut("m").disabled(!session.canAdjustColors || session.hueSaturation != nil)
            Button("Levels…") { session.beginLevels() }
                .configuredKeyboardShortcut("l").disabled(!session.canAdjustColors || session.hueSaturation != nil)
            Button("Hue/Saturation…") { session.beginHueSaturation() }
                .configuredKeyboardShortcut("u").disabled(!session.canAdjustColors)
            ForEach([FilterKind.blackWhite, .colorBalance, .exposure, .gradientMap, .grain], id: \.self) { kind in
                Button("\(kind.rawValue)…") { session.beginFilter(kind) }
                    .disabled(!session.canAdjustColors || session.hueSaturation != nil)
            }
            Button(session.isMaskSelected ? "Invert Mask" : "Invert") { Task { await session.invertPixels() } }
                .configuredKeyboardShortcut("i")
                .disabled(!session.canInvert)
            Divider()
            Button("Canvas Size…") { Task { await projects.canvasSize() } }
                .configuredKeyboardShortcut("c", modifiers: [.command, .option])
                .disabled(session.document == nil || !projects.canStart)
            Button("Image Size…") { Task { await projects.imageSize() } }
                .configuredKeyboardShortcut("i", modifiers: [.command, .option])
                .disabled(session.document == nil || !projects.canStart)
            Button("Trim…") { Task { await projects.trim() } }
                .disabled(session.document == nil || !projects.canStart)
            Group {
                Divider()
                Button("Flip Canvas Horizontal") { session.flipCanvas(horizontally: true) }
                    .disabled(!session.canEditLayers)
                Button("Flip Canvas Vertical") { session.flipCanvas(horizontally: false) }
                    .disabled(!session.canEditLayers)
            }
        }
        CommandMenu("Filter") {
            ForEach(FilterKind.allCases.filter { $0 != .contentAwareFill && !$0.isImageAdjustment }, id: \.self) { kind in
                Button("\(kind.rawValue)…") { session.beginFilter(kind) }
                    .disabled(!(kind == .vignette ? session.canVignette : session.canAdjustColors) || session.hueSaturation != nil)
            }
        }
        CommandMenu("Layer") {
            Menu("New Adjustment Layer") {
                ForEach(AdjustmentKind.allCases, id: \.self) { kind in
                    Button(kind.rawValue + (kind.isEditable ? "…" : "")) { session.addAdjustment(kind) }
                }
            }.disabled(!session.canEditLayers || session.document == nil)
            Button("Edit Adjustment…") {
                session.adjustmentEditingID = session.activeLayerID
            }.disabled(!session.canEditLayers || session.activeLayer?.adjustment == nil)
            Divider()
            Button(session.canTransformSelection ? "Transform Selection" : "Transform Layer") { session.transformCommand() }
                .configuredKeyboardShortcut("t").disabled(!session.canTransform && !session.canTransformSelection)
            Button(session.selection == nil ? "Duplicate Layer" : "Layer via Copy") { session.layerViaCopy() }
                .configuredKeyboardShortcut("j").disabled(!session.canCopyPixels && !(session.selection == nil && session.canEditLayers && session.activeLayer != nil))
            Divider()
            Button(session.activeLayer?.maskSourceID == nil ? "Create Clipping Mask" : "Release Clipping Mask") {
                if let id = session.activeLayerID { session.toggleClippingMask(id) }
            }
            .configuredKeyboardShortcut("g", modifiers: [.command, .option])
            .disabled(session.activeLayerID.map { !session.canToggleClippingMask($0) } ?? true)
            Divider()
            Button("Group Selected Layers") { session.groupSelectedLayers() }
                .configuredKeyboardShortcut("g").disabled(!session.canEditLayers)
            Button("Ungroup Layers") { session.ungroupLayers() }
                .configuredKeyboardShortcut("g", modifiers: [.command, .shift]).disabled(!session.canUngroupLayers)
            Button("Move Out of Folder") { session.moveActiveLayerOutOfGroup() }
                .disabled(!session.canEditLayers || session.activeLayer?.parentID == nil)
            Button("New Blank Layer") { session.addBlankLayer() }
                .configuredKeyboardShortcut("n", modifiers: [.command, .shift]).disabled(!session.canEditLayers)
            Button("Rename Layer…") { session.renamingLayerID = session.activeLayerID }
                .disabled(!session.canEditLayers || session.activeLayer == nil)
            Button(session.activeLayer?.isVisible == false ? "Show Layer" : "Hide Layer") {
                if let id = session.activeLayerID { session.toggleLayerVisibility(id) }
            }.disabled(!session.canEditLayers || session.activeLayer == nil)
            Divider()
            Button("Move Layer Up") { session.moveActiveLayer(by: 1) }
                .configuredKeyboardShortcut("]").disabled(!session.canMoveActiveLayer(by: 1))
            Button("Move Layer Down") { session.moveActiveLayer(by: -1) }
                .configuredKeyboardShortcut("[").disabled(!session.canMoveActiveLayer(by: -1))
            Group {
                Button(session.mergeTitle) { session.mergeLayers() }
                    .configuredKeyboardShortcut("e").disabled(!session.canMergeLayers)
                Divider()
                Button("Flip Layer Horizontal") { session.flipLayers(horizontally: true) }
                    .disabled(!session.canTransform)
                Button("Flip Layer Vertical") { session.flipLayers(horizontally: false) }
                    .disabled(!session.canTransform)
            }
            Divider()
            Button(session.selectedEffect != nil ? "Delete " + session.selectedEffect!.kind.rawValue : session.isMaskSelected && session.activeLayer?.mask != nil ? "Delete Layer Mask" : session.selectedLayerIDs.count > 1 ? "Delete Layers" : "Delete Layer") {
                session.deleteLayerOrMask()
            }
                .disabled(!session.canEditLayers || session.activeLayer == nil)
        }
    }
}
