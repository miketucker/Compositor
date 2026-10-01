import AppKit
import SwiftUI

struct EditorCanvas: NSViewRepresentable {
    let session: EditorSession
    func makeNSView(context: Context) -> CanvasView { CanvasView(session: session) }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.consumeFocusRequest(session.canvasFocusRequest)
        _ = session.showsTransformControls // observed here so ⌘H redraws the transform box at once
        _ = session.showsGrid
        _ = session.layoutGrid
        _ = session.gridAppearance
        _ = session.showsGuides
        _ = session.guideDrag
        _ = session.document?.guides
        view.synchronizeDisplay()
        view.window?.isDocumentEdited = session.isModified
    }
}

/// On the Mac the canvas's cursor is AppKit's own.
typealias CanvasCursor = NSCursor

extension CanvasPointer {
    init(_ event: NSEvent, in view: NSView) {
        self.init(location: view.convert(event.locationInWindow, from: nil), modifierFlags: KeyModifiers(event.modifierFlags),
                  clickCount: event.type == .leftMouseDown || event.type == .leftMouseUp ? event.clickCount : 1, event: event)
        // A drawing tablet's pen says how firmly it presses; a mouse or trackpad presses at full.
        if event.subtype == .tabletPoint, event.type != .mouseMoved { pressure = CGFloat(event.pressure) }
    }
}

extension CanvasKey {
    init(_ event: NSEvent) {
        self.init(keyCode: event.keyCode, charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                  modifierFlags: KeyModifiers(event.modifierFlags), isARepeat: event.isARepeat)
    }
}

/// The canvas on the Mac: AppKit's mouse, trackpad and key events, cursor rects, and the event monitors that let the
/// canvas follow the keys wherever the focus is.
extension CanvasView {
    func consumeFocusRequest(_ request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.attachedSheet == nil else { return }
            // Text being edited takes the keys back (after the color picker, say), so typing and ⌘Return still reach it.
            if self.session.textDraft == nil { window.makeFirstResponder(self) }
            else if let editor = self.inlineTextEditor { window.makeFirstResponder(editor.textView) }
        }
    }

    /// The modifier keys held now, for a press or a key that doesn't carry its own.
    static var currentModifiers: KeyModifiers { KeyModifiers.current }
    /// Where the pointer is now, in the canvas's coordinates.
    var pointerLocation: CGPoint? { window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } }
    var backingScaleFactor: CGFloat { convertToBacking(CGSize(width: 1, height: 1)).width }
    var isDrawingToScreen: Bool { NSGraphicsContext.current?.isDrawingToScreen == true }
    func invalidateCursor() { window?.invalidateCursorRects(for: self) }
    func refreshPointerTracking() { updateTrackingAreas() }
    func takeKeyFocus() { window?.makeFirstResponder(self) }
    /// Holds the drag's cursor however the pointer moves, until `unlockCursor`.
    func lockCursor() {
        cursorLockWindow = window
        cursorLockWindow?.disableCursorRects()
    }
    func unlockCursor() {
        cursorLockWindow?.enableCursorRects()
        cursorLockWindow?.invalidateCursorRects(for: self)
        cursorLockWindow = nil
    }
    func refocusPanel(_ name: String) { FloatingPanelController.refocus(named: name) }
    func refocusColorPicker() { ColorPickerPanelController.refocus() }
    func insertCanvasSurface(_ view: MetalCanvasView) {
        view.autoresizingMask = [.width, .height]
        addSubview(view, positioned: .below, relativeTo: subviews.first)
    }
    func setUpPlatform() {
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Canvas")
        setAccessibilityIdentifier("editorCanvas")
    }

    /// With Color Range's panel focused, anything that rebuilds this view's cursor rects (a new selection redrawn, the
    /// panel taking the focus back after a click) leaves the arrow up until the pointer moves. Put the eyedropper back
    /// once that's done.
    func keepColorRangeCursor(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.session.colorRange != nil, self.pointerOverCanvas else { return }
            self.pickCursor.set()
        }
    }
    /// The pointer is on the canvas itself, not over a panel floating above it.
    var pointerOverCanvas: Bool {
        guard let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) else { return false }
        return NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber
    }
    func redrawRulers() {
        func find(_ view: NSView) {
            if view is CanvasRulerStrip { view.needsDisplay = true }
            view.subviews.forEach(find)
        }
        window?.contentView.map(find)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layoutOverlays()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncGeometry()
        if let modifierMonitor { NSEvent.removeMonitor(modifierMonitor); self.modifierMonitor = nil }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        if let sampleClickMonitor { NSEvent.removeMonitor(sampleClickMonitor); self.sampleClickMonitor = nil }
        if let cursorUpdateMonitor { NSEvent.removeMonitor(cursorUpdateMonitor); self.cursorUpdateMonitor = nil }
        guard window != nil else { return }
        // Sampling the canvas for an open panel (the color picker, Levels, a filter) handles the click here, before
        // the window sees it: a click would make this window key, and the panel would lose focus and its shadow
        // would fade until the release gave focus back.
        // With Color Range's panel focused, the cursor update AppKit sends after Shift or Option changes reaches a view
        // that answers with the arrow. Over the canvas, answer it here with the eyedropper instead.
        cursorUpdateMonitor = NSEvent.addLocalMonitorForEvents(matching: .cursorUpdate) { [weak self] event in
            guard let self, self.session.colorRange != nil, self.pointerOverCanvas else { return event }
            self.pickCursor.set()
            return nil
        }
        sampleClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            switch event.type {
            case .leftMouseDown:
                guard self.picking, !window.isKeyWindow, NSApp.keyWindow is NSPanel,
                      let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: self) else { return event }
                self.sampleClickActive = true
                self.mouseDown(with: event)
            case .leftMouseDragged:
                guard self.sampleClickActive else { return event }
                self.mouseDragged(with: event)
            default:
                guard self.sampleClickActive else { return event }
                self.sampleClickActive = false
                self.mouseUp(with: event)
            }
            return nil
        }
        optionHeld = NSEvent.modifierFlags.contains(.option)
        // A tab mounts a new canvas. Restore keyboard focus after SwiftUI finishes
        // installing it, without taking focus from a newly presented dialog.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session.document != nil, let window = self.window,
                  window.attachedSheet == nil, !self.session.showsNewDocument,
                  !self.session.showsImporter, self.session.colorPicker == nil else { return }
            window.makeFirstResponder(self)
        }
        // Modifier changes reach only the first responder; watch them app-wide so the
        // lasso badge updates even while another control has keyboard focus.
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            self.modifiersChanged(KeyModifiers(event.modifierFlags))
            return event
        }
        // Window-wide keys that work wherever focus sits — the canvas, the Layers panel, a header
        // control, the tool rail — except while typing in a text field.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let originalEvent = event
            guard let event = ShortcutSettings.shared.canvasEvent(event) else { return originalEvent }
            guard let self, let window = self.window, event.windowNumber == window.windowNumber,
                  !(window.firstResponder is NSText) else { return originalEvent }
            if self.handleKeyboardZoom(event) { return nil }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let key = event.charactersIgnoringModifiers else { return originalEvent }
            // Shift-+ / Shift-− step the active layer's blend mode, in every tool.
            if event.modifierFlags.contains(.shift), key == "+" || key == "_" || event.keyCode == 24 || event.keyCode == 27 {
                self.session.cycleBlendMode(forward: key == "+" || event.keyCode == 24)
                return nil
            }
            // Brush size ([ ]) and hardness (Shift-[ ]); with focus on the canvas its own keyDown handles them.
            guard (self.session.tool.isBrushTool), self.session.levels == nil, window.firstResponder !== self,
                  ["[", "]", "{", "}"].contains(key) else { return originalEvent }
            if key == "[" || key == "]" { self.session.changeBrushSize(increase: key == "]") }
            else { self.session.changeBrushHardness(increase: key == "}") }
            return nil
        }
    }

    /// Handle default zoom shortcuts on keyDown, including key repeat, without waiting for a menu command.
    func handleKeyboardZoom(_ event: NSEvent) -> Bool {
        guard session.document != nil, event.modifierFlags.contains(.command),
              event.modifierFlags.intersection([.control, .option]).isEmpty else { return false }

        let zoomInIsDefault = ShortcutDefinition.all.first(where: { $0.isMenu && $0.title == "Zoom In" })
            .map { ShortcutSettings.shared.chord($0) == $0.original } ?? true
        let zoomOutIsDefault = ShortcutDefinition.all.first(where: { $0.isMenu && $0.title == "Zoom Out" })
            .map { ShortcutSettings.shared.chord($0) == $0.original } ?? true

        // '+' is '=' with Shift on a Mac keyboard; the keypad has its own key codes.
        let isZoomIn = [24, 69].contains(event.keyCode)
        let isZoomOut = [27, 78].contains(event.keyCode) && !event.modifierFlags.contains(.shift)
        guard (isZoomIn && zoomInIsDefault) || (isZoomOut && zoomOutIsDefault) else { return false }

        session.zoomKeyboard(by: isZoomIn ? 1 : -1)
        synchronizeDisplay()
        return true
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); syncGeometry() }
    override func cacheDisplay(in rect: NSRect, to bitmapImageRep: NSBitmapImageRep) {
        snapshotting = true
        defer { snapshotting = false }
        super.cacheDisplay(in: rect, to: bitmapImageRep)
    }
    override func resetCursorRects() {
        guard session.document != nil else { return }
        if let dragCursor { addCursorRect(bounds, cursor: dragCursor); return }
        if picking {
            addCursorRect(bounds, cursor: pickCursor)
            keepColorRangeCursor()
            return
        }
        if session.hueTargeting { addCursorRect(bounds, cursor: .resizeLeftRight); return }
        if session.tool.isSelectionTool, !spaceHeld { addCursorRect(bounds, cursor: lassoCursor); return }
        // Clone Stamp with a source: the brush circle, its preview and the source crosshair stand in
        // for the cursor. Holding Option to pick a new source brings the crosshair back.
        if session.tool == .cloneStamp, session.cloneSource != nil, !optionHeld, !spaceHeld {
            addCursorRect(bounds, cursor: Self.hiddenCursor)
            return
        }
        addCursorRect(bounds, cursor: toolCursor)
        guard session.tool == .crop, !spaceHeld else { return }
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        for region in transformOverlay.cropResizeRegions.reversed() {
            let rect = region.rect.intersection(bounds)
            if !rect.isEmpty && !rect.isNull {
                addCursorRect(rect, cursor: .frameResize(position: positions[region.index], directions: [.inward, .outward]))
            }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        hoverTrackingArea = nil
        guard session.document != nil else { return }
        // Every tool hears the mouse leave, so its cursor never follows it out of the canvas;
        // only tools whose cursor depends on where the pointer is also track movement.
        // The picker panel stays key, so sampling must track while this window is not.
        var options: NSTrackingArea.Options = [.mouseEnteredAndExited, picking ? .activeAlways : .activeInKeyWindow, .inVisibleRect]
        if picking || session.tool == .move || session.tool.isBrushTool || session.tool.isSelectionTool {
            options.formUnion([.mouseMoved, .cursorUpdate])
        }
        let area = NSTrackingArea(rect: .zero, options: options, owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) {
        pointerExited()
        // Tools set their cursor directly while over the canvas, so put the arrow back on the
        // way out. A drag keeps its cursor until mouse-up.
        if session.document != nil, NSEvent.pressedMouseButtons == 0 {
            NSCursor.setHiddenUntilMouseMoves(false)
            NSCursor.arrow.set()
        }
    }
    override func mouseMoved(with event: NSEvent) {
        guard session.document != nil else { return }
        if !pointerHovered(CanvasPointer(event, in: self)) { super.mouseMoved(with: event) }
    }
    override func cursorUpdate(with event: NSEvent) {
        guard session.document != nil else { return }
        if picking { pickCursor.set() }
        else if session.tool.isSelectionTool, !spaceHeld { lassoCursor.set() }
        // Cursor-update events carry no modifier flags (AppKit sends one after every key change), so read
        // the keys as they are now; the event's flags would undo Option's duplicate cursor straight away.
        else if session.tool == .move { updateTransformCursor(at: convert(event.locationInWindow, from: nil), flags: Self.currentModifiers) }
        else { super.cursorUpdate(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard session.tool.isBrushTool, session.brushStroke == nil, session.warpStroke == nil, !spaceHeld else {
            super.rightMouseDown(with: event); return
        }
        let point = convert(event.locationInWindow, from: nil)
        brushTipDrag = (point, session.brushSettings.diameter, session.brushSettings.hardness, event.modifierFlags.contains(.shift))
        brushPointer = point
        updateBrushCursor()
    }
    override func rightMouseDragged(with event: NSEvent) {
        guard let drag = brushTipDrag else { super.rightMouseDragged(with: event); return }
        brushTipDrag?.hardnessShown = event.modifierFlags.contains(.shift)
        let dx = convert(event.locationInWindow, from: nil).x - drag.start.x
        if event.modifierFlags.contains(.shift) {
            // The full range across 200 points.
            session.brushSettings.hardness = min(1, max(0, drag.hardness + dx / 200))
            session.brushSettings.diameter = drag.diameter
        } else {
            // The circle's edge follows the pointer: each point moved widens the radius by a point on screen.
            let perPixel = max(0.0001, session.viewport.pointsPerPixel)
            session.brushSettings.diameter = min(2000, max(1, (drag.diameter + 2 * dx / perPixel).rounded()))
            session.brushSettings.hardness = drag.hardness
        }
        brushPointer = drag.start
        updateBrushCursor()
    }
    override func rightMouseUp(with event: NSEvent) {
        guard brushTipDrag != nil else { super.rightMouseUp(with: event); return }
        brushTipDrag = nil
        brushPointer = convert(event.locationInWindow, from: nil)
        updateBrushCursor()
    }
    /// The middle button pans from any tool, without reaching for Space or the Hand tool. It keeps
    /// its own drag point so it can't disturb whatever the left button is in the middle of.
    private func panPoint(of event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, session.document != nil else { super.otherMouseDown(with: event); return }
        middlePanPoint = panPoint(of: event)
        if session.tool.isBrushTool { updateBrushCursor() }
        NSCursor.closedHand.set()
    }
    override func otherMouseDragged(with event: NSEvent) {
        guard let last = middlePanPoint else { super.otherMouseDragged(with: event); return }
        let point = panPoint(of: event)
        session.viewport.translate(by: CGSize(width: point.x - last.x, height: point.y - last.y))
        middlePanPoint = point
        redrawRulers()
    }
    override func otherMouseUp(with event: NSEvent) {
        guard middlePanPoint != nil else { super.otherMouseUp(with: event); return }
        middlePanPoint = nil
        // The closed hand was set directly, so put the tool's own cursor back rather than waiting
        // for the next move.
        refreshLassoCursor(KeyModifiers(event.modifierFlags))
        if session.tool.isBrushTool { updateBrushCursor() }
        window?.invalidateCursorRects(for: self)
    }
    override func scrollWheel(with event: NSEvent) {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, session.brushStroke == nil, session.warpStroke == nil else { return }
        guard session.document != nil else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            session.zoom(to: session.viewport.zoom * exp(-event.scrollingDeltaY * 0.015),
                         anchor: convert(event.locationInWindow, from: nil))
        } else {
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            session.viewport.translate(by: CGSize(width: event.scrollingDeltaX * multiplier,
                                                  height: event.scrollingDeltaY * multiplier))
            redrawRulers()
        }
    }
    override func magnify(with event: NSEvent) {
        guard transformDrag == nil, cropDrag == nil, !guideDragging, session.brushStroke == nil, session.warpStroke == nil else { return }
        session.zoom(to: session.viewport.zoom * (1 + event.magnification),
                     anchor: convert(event.locationInWindow, from: nil))
    }
    override func resignFirstResponder() -> Bool {
        canvasLostFocus()
        return super.resignFirstResponder()
    }
}

extension CanvasView {
    override func mouseDown(with event: NSEvent) { pointerDown(CanvasPointer(event, in: self)) }
    override func mouseDragged(with event: NSEvent) { pointerDragged(CanvasPointer(event, in: self)) }
    override func mouseUp(with event: NSEvent) { pointerUp(CanvasPointer(event, in: self)) }
    override func keyDown(with event: NSEvent) {
        let physicalKey = event.keyCode
        guard let event = ShortcutSettings.shared.canvasEvent(event) else { return }
        if handleKeyboardZoom(event) { return }
        if !handleKey(CanvasKey(event), physicalKey: physicalKey) { super.keyDown(with: event) }
    }
    override func keyUp(with event: NSEvent) {
        if !handleKeyUp(event.keyCode) { super.keyUp(with: event) }
    }
}
