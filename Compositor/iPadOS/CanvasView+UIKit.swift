import SwiftUI
import UIKit

struct EditorCanvas: UIViewRepresentable {
    let session: EditorSession
    func makeUIView(context: Context) -> CanvasView { CanvasView(session: session) }
    func updateUIView(_ view: CanvasView, context: Context) {
        view.consumeFocusRequest(session.canvasFocusRequest)
        _ = session.showsTransformControls
        _ = session.showsGrid
        _ = session.layoutGrid
        _ = session.gridAppearance
        _ = session.showsGuides
        _ = session.guideDrag
        _ = session.document?.guides
        view.pencil.note(PencilActions.ToolChoice(tool: session.tool, brushMode: session.brushMode))
        view.synchronizeDisplay()
    }
}

/// The pointer's shape over the canvas, with a trackpad or mouse. iPad draws its own pointer, so a tool only says what
/// kind it wants: none where the tool draws its own (the brush circle), a beam for text, a cross for picking a point,
/// and the system's round pointer otherwise.
final class CanvasCursor: Equatable {
    enum Shape { case system, hidden, text, crosshair }
    let shape: Shape
    init(_ shape: Shape) { self.shape = shape }
    static func == (a: CanvasCursor, b: CanvasCursor) -> Bool { a === b }

    static let arrow = CanvasCursor(.system)
    static let openHand = CanvasCursor(.system)
    static let closedHand = CanvasCursor(.system)
    static let crosshair = CanvasCursor(.crosshair)
    static let iBeam = CanvasCursor(.text)
    static let resizeLeftRight = CanvasCursor(.system)
    static let resizeUpDown = CanvasCursor(.system)

    /// The shape the canvas last asked for.
    private(set) static var current = CanvasCursor.arrow
    /// Told when it changes, so the pointer can follow.
    static var changed: (() -> Void)?
    func set() {
        guard CanvasCursor.current !== self else { return }
        CanvasCursor.current = self
        CanvasCursor.changed?()
    }
}

/// The canvas's cursors on iPad: the Mac's names, for the shapes iPad has.
extension CanvasView {
    static let hiddenCursor = CanvasCursor(.hidden)
    static let movePixelsCursor = CanvasCursor(.system)
    static let duplicateCursor = CanvasCursor(.system)
    static let distortCursor = CanvasCursor(.system)
    static let moveCursor = CanvasCursor(.system)
    static let moveSelectionCursor = CanvasCursor(.system)
    static let selectionCursors: [SelectionIcon: [SelectionMode: CanvasCursor]] = Dictionary(uniqueKeysWithValues:
        SelectionIcon.allCases.map { ($0, Dictionary(uniqueKeysWithValues: SelectionMode.allCases.map { ($0, CanvasCursor.crosshair) })) })
    static let wandCursors: [SelectionMode: CanvasCursor] = Dictionary(uniqueKeysWithValues: SelectionMode.allCases.map { ($0, CanvasCursor.crosshair) })
    static let rotationCursor = CanvasCursor(.system)
    // Each its own, so the canvas can tell an eyedropper left over from a picker.
    static let eyedropperCursor = CanvasCursor(.crosshair)
    static let eyedropperAddCursor = CanvasCursor(.crosshair)
    static let eyedropperRemoveCursor = CanvasCursor(.crosshair)
    static let zoomInCursor = CanvasCursor(.system)
    static let zoomOutCursor = CanvasCursor(.system)
    static func resizeCursor(direction: Int) -> CanvasCursor { .arrow }
}

extension CanvasKey {
    /// A key code for a modifier key pressed on its own, which is part of a shortcut still being pressed.
    static let modifierOnly: UInt16 = 0xfffe

    /// A hardware keyboard's key, as the Mac's key code the canvas's keys are written against. Nil for a key the
    /// canvas has no use for.
    init?(_ key: UIKey) {
        let codes: [UIKeyboardHIDUsage: UInt16] = [
            .keyboardEscape: 53, .keyboardReturnOrEnter: 36, .keypadEnter: 76, .keyboardDeleteOrBackspace: 51,
            .keyboardDeleteForward: 117, .keyboardLeftArrow: 123, .keyboardRightArrow: 124, .keyboardDownArrow: 125,
            .keyboardUpArrow: 126, .keyboardTab: 48, .keyboardSpacebar: 49, .keyboardEqualSign: 24, .keyboardHyphen: 27,
            .keypadPlus: 69, .keypadHyphen: 78,
        ]
        let modifierKeys: Set<UIKeyboardHIDUsage> = [.keyboardLeftShift, .keyboardRightShift, .keyboardLeftAlt, .keyboardRightAlt,
                                                     .keyboardLeftGUI, .keyboardRightGUI, .keyboardLeftControl, .keyboardRightControl,
                                                     .keyboardCapsLock]
        let flags = KeyModifiers(key.modifierFlags)
        if modifierKeys.contains(key.keyCode) {
            self.init(keyCode: Self.modifierOnly, charactersIgnoringModifiers: nil, modifierFlags: flags)
            return
        }
        var characters = key.charactersIgnoringModifiers
        // As the Mac reports them: Shift still counts, so Shift-[ is "{".
        if flags.contains(.shift), let shifted = ["[": "{", "]": "}", "=": "+", "-": "_"][characters] {
            characters = shifted
        }
        guard let code = codes[key.keyCode] ?? (characters.isEmpty ? nil : 0xffff) else { return nil }
        self.init(keyCode: code, charactersIgnoringModifiers: characters, modifierFlags: flags)
    }
}

/// The canvas on iPad: the Pencil, a finger or a trackpad click works the current tool, two fingers pan and pinch to
/// zoom, a two-finger tap undoes and a three-finger tap redoes, the Pencil's double tap and squeeze do what Settings
/// says they should, and a hardware keyboard has the Mac's keys.
extension CanvasView {
    func consumeFocusRequest(_ request: Int) {
        guard request != lastFocusRequest else { return }
        lastFocusRequest = request
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            // Text being edited takes the keys back (after the color picker, say).
            if self.session.textDraft == nil { _ = self.becomeFirstResponder() }
            else { self.inlineTextEditor?.focus() }
        }
    }

    /// The modifier keys held now, for a touch or a key that doesn't carry its own.
    static var currentModifiers: KeyModifiers { HeldModifiers.shared.canvasFlags }
    /// Where the pointer or the hovering Pencil is, when either is over the canvas.
    var pointerLocation: CGPoint? { hoverLocation }
    var pointerOverCanvas: Bool { hoverLocation.map { bounds.contains($0) } ?? false }
    var backingScaleFactor: CGFloat { window?.screen.scale ?? traitCollection.displayScale }
    var isDrawingToScreen: Bool { true }
    func invalidateCursor() { pointerInteraction?.invalidate() }
    func refreshPointerTracking() {}
    func takeKeyFocus() { if !isFirstResponder { _ = becomeFirstResponder() } }
    func lockCursor() {}
    func unlockCursor() { invalidateCursor() }
    func refocusPanel(_ name: String) {}
    func refocusColorPicker() {}
    func keepColorRangeCursor(after delay: TimeInterval = 0) {}
    func insertCanvasSurface(_ view: MetalCanvasView) {
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        insertSubview(view, at: 0)
    }
    func redrawRulers() {
        func find(_ view: UIView) {
            if view is CanvasRulerStrip { view.setNeedsDisplay() }
            view.subviews.forEach(find)
        }
        window.map(find)
    }

    func setUpPlatform() {
        isAccessibilityElement = true
        accessibilityLabel = "Canvas"
        accessibilityIdentifier = "editorCanvas"
        accessibilityTraits = .image
        isOpaque = true
        contentMode = .redraw
        isMultipleTouchEnabled = true

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.minimumNumberOfTouches = 2
        pan.allowedScrollTypesMask = .continuous
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(undoTapped))
        undoTap.numberOfTouchesRequired = 2
        let redoTap = UITapGestureRecognizer(target: self, action: #selector(redoTapped))
        redoTap.numberOfTouchesRequired = 3
        for recognizer in [pinch, pan, undoTap, redoTap] as [UIGestureRecognizer] {
            // Only fingers (and the trackpad, for pan and pinch) navigate: the Pencil always draws.
            recognizer.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber,
                                            UITouch.TouchType.indirectPointer.rawValue as NSNumber]
            recognizer.delegate = navigationDelegate
            addGestureRecognizer(recognizer)
        }
        undoTap.require(toFail: redoTap)
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
        addInteraction(UIPencilInteraction(delegate: pencil))
        let pointer = UIPointerInteraction(delegate: pointerDelegate)
        addInteraction(pointer)
        pointerInteraction = pointer
        CanvasCursor.changed = { [weak self] in self?.invalidateCursor() }
        registerForTraitChanges([UITraitDisplayScale.self]) { (view: CanvasView, _) in view.layoutOverlays() }
    }

    override var canBecomeFirstResponder: Bool { true }
    /// The canvas takes a hardware keyboard's keys but never typing. Holding the keys with no input view of its own, it
    /// had iPadOS raise the on-screen keyboard whenever a menu opened over it; an empty one keeps the keyboard down.
    override var inputView: UIView? { Self.noKeyboard }
    private static let noKeyboard = UIView(frame: .zero)

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutOverlays()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        layoutOverlays()
        if updateLink == nil, window != nil { updateLink = makeUpdateLink() }
        updateLink?.isEnabled = window != nil
        guard window != nil else { return }
        HeldModifiers.shared.changed = { [weak self] flags in self?.modifiersChanged(flags) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session.document != nil, self.session.textDraft == nil else { return }
            _ = self.becomeFirstResponder()
        }
    }

    // MARK: Touches

    /// A touch as a press on the canvas: where it is (the Pencil's precise position), with the keys held on a
    /// keyboard, the on-screen modifier keys, or the tool bar's Option button. `predicted` marks where UIKit only
    /// expects it to be, which presses at the latest pressure measured rather than its own guess of one.
    private func pointer(for touch: UITouch, event: UIEvent?, predicted: Bool = false) -> CanvasPointer {
        let location = touch.type == .pencil ? touch.preciseLocation(in: self) : touch.location(in: self)
        let keys = KeyModifiers(event?.modifierFlags ?? []).union(HeldModifiers.shared.onScreen)
            .union(HeldModifiers.shared.latched)
        let estimate = !predicted && touch.type == .pencil && touch.estimatedPropertiesExpectingUpdates.contains(.force)
            ? touch.estimationUpdateIndex?.intValue : nil
        return CanvasPointer(location: location, modifierFlags: keys, clickCount: max(1, touch.tapCount),
                             pressure: pressure(of: touch, predicted: predicted, estimate: estimate),
                             pressureEstimate: estimate)
    }

    /// How firmly the Pencil presses, 0–1, as the current press has followed it (see `PencilPressure`: a force that's
    /// only an estimate, awaiting UIKit's correction, is never drawn). A finger and the trackpad can't tell, so press
    /// at 1.
    private func pressure(of touch: UITouch, predicted: Bool, estimate: Int?) -> CGFloat {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return 1 }
        if predicted { return pencilPressure.predicted }
        return pencilPressure.sample(force: touch.force, maximum: touch.maximumPossibleForce, estimate: estimate)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A second finger coming down makes it a gesture: whatever the first started is put down (see `navigate`). Only
        // fingers on the canvas count, so a thumb holding the shortcut circle leaves the other hand free to work.
        let fingers = event?.allTouches?.filter {
            $0.view === self && $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 0
        guard toolTouch == nil, fingerPan == nil, !navigating, fingers <= 1, let touch = touches.first else { return }
        if touch.type == .direct, fingerNavigates {
            fingerPan = (touch, touch.location(in: self))
            return
        }
        toolTouch = touch
        pencilPressure = PencilPressure()
        hoverLocation = nil
        beginFrames(pencil: touch.type == .pencil)
        pointerDown(pointer(for: touch, event: event))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let pan = fingerPan, touches.contains(pan.touch) {
            let point = pan.touch.location(in: self)
            if !navigating, canNavigate {
                session.viewport.translate(by: CGSize(width: point.x - pan.point.x, height: point.y - pan.point.y))
                redrawRulers()
            }
            fingerPan = (pan.touch, point)
            return
        }
        guard let touch = toolTouch, touches.contains(touch) else { return }
        // Every sample the Pencil took since the last frame, so a quick stroke keeps its curve, and where it's
        // predicted to be by the time the frame is on screen.
        let events = (event?.coalescedTouches(for: touch) ?? [touch]).map { pointer(for: $0, event: event) }
        let predicted = (event?.predictedTouches(for: touch) ?? []).map { pointer(for: $0, event: event, predicted: true) }
        guard updateLink?.isEnabled == true else {
            pointerDragged(events, predicted: predicted)
            return
        }
        // Drawn once a frame, when the last samples for it are in (see `makeUpdateLink`).
        pendingDrag.events += events
        pendingDrag.predicted = predicted
    }

    /// UIKit's corrections of the forces it first only estimated (see `PencilPressure`), arriving a moment after the
    /// samples they belong to: a stroke that follows pressure is drawn at the estimate, then handed each measured
    /// force once it lands (see `HeldBrushSamples`). Drawn once a frame, with the drag's samples.
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        var corrections: [(estimate: Int, pressure: CGFloat)] = []
        for touch in touches where touch.type == .pencil && touch.maximumPossibleForce > 0
            && !touch.estimatedPropertiesExpectingUpdates.contains(.force) {
            // Monotonic across presses, so whichever correction the guard takes is the newest (see `PencilPressure`).
            guard let estimate = touch.estimationUpdateIndex?.intValue else { continue }
            pencilPressure.update(force: touch.force, maximum: touch.maximumPossibleForce, estimate: estimate)
            corrections.append((estimate, PencilPressure.eased(force: touch.force, maximum: touch.maximumPossibleForce)))
        }
        guard !corrections.isEmpty, toolTouch != nil else { return }
        if updateLink?.isEnabled == true {
            pendingCorrections += corrections
        } else {
            session.correctBrush(corrections)
            synchronizeDisplay()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let pan = fingerPan, touches.contains(pan.touch) { fingerPan = nil; return }
        guard let touch = toolTouch, touches.contains(touch) else { return }
        flushDrag()
        toolTouch = nil
        endFrames()
        var up = pointer(for: touch, event: event)
        up.isLiftOff = touch.type == .pencil
        pointerUp(up)
        HeldModifiers.shared.canvasPressEnded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let pan = fingerPan, touches.contains(pan.touch) { fingerPan = nil; return }
        guard let touch = toolTouch, touches.contains(touch) else { return }
        toolTouch = nil
        pendingDrag = ([], [])
        pendingCorrections = []
        endFrames()
        canvasLostFocus()
        synchronizeDisplay()
    }

    /// Where "Only Draw with Apple Pencil" is on (Settings › Apple Pencil), a finger pans rather than paints: the tools
    /// that draw answer to the Pencil alone. The rest still take a finger, since moving or selecting isn't drawing.
    private var fingerNavigates: Bool {
        UIPencilInteraction.prefersPencilOnlyDrawing && session.document != nil
            && (session.tool.isBrushTool || session.tool == .gradient || session.tool == .shape)
    }

    /// Two fingers came down: what the first finger started is taken back, and the canvas pans and zooms instead.
    private func navigate() {
        guard !navigating else { return }
        navigating = true
        fingerPan = nil
        if toolTouch != nil {
            toolTouch = nil
            pendingDrag = ([], [])
            pendingCorrections = []
            endFrames()
            canvasLostFocus()
            synchronizeDisplay()
        }
    }

    // MARK: Frames

    /// The display link drawing keeps pace with. A drag's samples are drawn once a frame, after the last of them
    /// has arrived: with the Pencil, iPadOS hands over its latest samples partway through the frame, and puts the
    /// frame on screen as soon as it's drawn, so the stroke stays at the Pencil's tip.
    private func makeUpdateLink() -> UIUpdateLink {
        let link = UIUpdateLink(view: self)
        link.addAction(to: .afterEventDispatch) { [weak self] _, info in
            // When the Pencil's late samples are coming, the frame waits for them rather than being drawn twice.
            guard let self, !self.pendingDrag.events.isEmpty || !self.pendingCorrections.isEmpty,
                  !info.isLowLatencyEventDispatchConfirmed else { return }
            self.flushDrag()
        }
        link.addAction(to: .afterLowLatencyEventDispatch) { [weak self] _, _ in self?.flushDrag() }
        link.addAction(to: .afterUpdateComplete) { [weak self] link, info in
            guard let self, self.toolTouch != nil, link.wantsImmediatePresentation else { return }
            self.missedFrames = CACurrentMediaTime() > info.completionDeadlineTime ? self.missedFrames + 1 : 0
            // Too much to draw at that pace (a big brush on a big canvas): the rest of the stroke goes at the
            // ordinary one, a frame behind, rather than juddering.
            if self.missedFrames >= 3 {
                link.wantsImmediatePresentation = false
                link.wantsLowLatencyEventDispatch = false
            }
        }
        return link
    }

    /// Draws what the drag has done since the last frame, and hands the stroke the measured forces UIKit sent back.
    private func flushDrag() {
        guard !pendingDrag.events.isEmpty || !pendingCorrections.isEmpty, toolTouch != nil else { return }
        let drag = pendingDrag
        let corrections = pendingCorrections
        pendingDrag = ([], [])
        pendingCorrections = []
        if !drag.events.isEmpty {
            // Taken in but not drawn on its own: the samples alongside draw it, so the frame renders once.
            session.correctBrush(corrections, redraw: false)
            pointerDragged(drag.events, predicted: drag.predicted)
        } else {
            session.correctBrush(corrections)
            synchronizeDisplay()
        }
    }

    /// A press has begun: frames come at the display's full rate until it ends, and a Pencil's as soon as they can.
    private func beginFrames(pencil: Bool) {
        guard let link = updateLink else { return }
        pendingDrag = ([], [])
        pendingCorrections = []
        missedFrames = 0
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.requiresContinuousUpdates = true
        link.wantsLowLatencyEventDispatch = pencil
        link.wantsImmediatePresentation = pencil
    }

    private func endFrames() {
        guard let link = updateLink else { return }
        link.requiresContinuousUpdates = false
        link.wantsLowLatencyEventDispatch = false
        link.wantsImmediatePresentation = false
        link.preferredFrameRateRange = .default
    }

    private var canNavigate: Bool {
        transformDrag == nil && cropDrag == nil && !guideDragging && session.brushStroke == nil && session.warpStroke == nil
            && session.document != nil
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            navigate()
            pinchZoom = session.viewport.zoom
            pinchLifted = false
        case .changed:
            // With one finger left, the pinch's center is that finger and its scale is stale: zooming to them would
            // jump the canvas just as the gesture ends. Nor does the scale pick up cleanly if a finger comes back.
            if pinch.numberOfTouches == 1 { pinchLifted = true }
            guard canNavigate, !pinchLifted else { return }
            session.zoom(to: pinchZoom * pinch.scale, anchor: pinch.location(in: self))
        default:
            finishNavigating()
        }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let point = pan.location(in: self)
        switch pan.state {
        case .began:
            navigate()
            twoFingerPan = TwoFingerPan(at: point, touches: pan.numberOfTouches)
        case .changed:
            guard let delta = twoFingerPan?.move(to: point, touches: pan.numberOfTouches), canNavigate,
                  delta != .zero else { return }
            session.viewport.translate(by: delta)
            redrawRulers()
        default:
            twoFingerPan = nil
            finishNavigating()
        }
    }

    private func finishNavigating() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.gestureRecognizers?.contains(where: { $0.state == .changed || $0.state == .began }) != true else { return }
            self.navigating = false
        }
    }

    @objc private func undoTapped() {
        navigate()
        if session.canUndo { session.undo() }
        finishNavigating()
    }

    @objc private func redoTapped() {
        navigate()
        if session.canRedo { session.redo() }
        finishNavigating()
    }

    /// The pointer, or the Pencil hovering over the screen: the brush circle follows it before anything is pressed.
    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        switch hover.state {
        case .began, .changed:
            guard toolTouch == nil else { return }
            let location = hover.location(in: self)
            hoverLocation = location
            pointerHovered(CanvasPointer(location: location, modifierFlags: Self.currentModifiers))
        default:
            hoverLocation = nil
            pointerExited()
        }
    }

    // MARK: Keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        HeldModifiers.shared.keyboard = KeyModifiers(event?.modifierFlags ?? [])
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let canvasKey = CanvasKey(key) else { unhandled.insert(press); continue }
            if canvasKey.keyCode == CanvasKey.modifierOnly { continue }
            guard let remapped = ShortcutSettings.shared.canvasKey(canvasKey) else { continue }
            if !handleKey(remapped, physicalKey: canvasKey.keyCode) { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        HeldModifiers.shared.keyboard = KeyModifiers(event?.modifierFlags ?? [])
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let canvasKey = CanvasKey(key) else { unhandled.insert(press); continue }
            if canvasKey.keyCode == CanvasKey.modifierOnly { continue }
            if !handleKeyUp(canvasKey.keyCode) { unhandled.insert(press) }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        HeldModifiers.shared.keyboard = []
        _ = handleKeyUp(49)
        super.pressesCancelled(presses, with: event)
    }

    override func resignFirstResponder() -> Bool {
        canvasLostFocus()
        return super.resignFirstResponder()
    }

    // MARK: Delegates

    private var navigationDelegate: NavigationGestures { NavigationGestures.shared }
    private var pointerDelegate: PointerShapes { PointerShapes.shared }

    /// The Pencil's palette, beside where the Pencil is hovering, or failing that where it or the pointer last was.
    func showPencilPalette(at location: CGPoint?) {
        let point = location ?? hoverLocation ?? CGPoint(x: bounds.midX, y: bounds.midY)
        PencilPalette.shared.show(for: session, at: convert(point, to: nil))
    }
}

/// Lets two-finger panning and pinching run together, as they do in Photos.
private final class NavigationGestures: NSObject, UIGestureRecognizerDelegate {
    static let shared = NavigationGestures()
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }
}

/// The Pencil's double tap and squeeze, doing what Settings › Apple Pencil says each should: switch to the eraser and
/// back, switch to the tool used before, or show the colors, or a palette of the brush's size and opacity, beside
/// the Pencil. Ignore (and a system shortcut, which iPadOS runs itself) does nothing here.
final class PencilActions: NSObject, UIPencilInteractionDelegate {
    /// A tool as the Pencil switches between them: the Eraser is the Brush erasing.
    struct ToolChoice: Equatable {
        let tool: NavigationTool
        let brushMode: BrushToolMode
    }
    private var current: ToolChoice?
    private var previous: ToolChoice?
    /// What was in use when the Pencil switched to the eraser, to switch back to.
    private var beforeEraser: ToolChoice?

    /// Follows the tool in use, however it was chosen, so "switch to previous" knows what came before.
    func note(_ choice: ToolChoice) {
        guard choice != current else { return }
        previous = current
        current = choice
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        perform(UIPencilInteraction.preferredTapAction, at: tap.hoverPose?.location, on: interaction)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        perform(UIPencilInteraction.preferredSqueezeAction, at: squeeze.hoverPose?.location, on: interaction)
    }

    private func perform(_ action: UIPencilPreferredAction, at location: CGPoint?, on interaction: UIPencilInteraction) {
        guard let canvas = interaction.view as? CanvasView, canvas.toolTouch == nil else { return }
        let session = canvas.session
        switch action {
        case .switchEraser:
            if session.tool == .brush, session.brushMode == .erase {
                select(beforeEraser ?? ToolChoice(tool: .brush, brushMode: .paint), in: session)
                beforeEraser = nil
            } else {
                beforeEraser = ToolChoice(tool: session.tool, brushMode: session.brushMode)
                select(ToolChoice(tool: .brush, brushMode: .erase), in: session)
            }
        case .switchPrevious:
            if let previous { select(previous, in: session) }
        case .showColorPalette:
            session.openColorPicker(background: false)
        case .showInkAttributes, .showContextualPalette:
            canvas.showPencilPalette(at: location)
        default:
            break
        }
    }

    private func select(_ choice: ToolChoice, in session: EditorSession) {
        session.selectTool(choice.tool)
        // The tool can refuse to change (text still being typed, say); the Brush's mode goes with it or not at all.
        if session.tool == choice.tool { session.brushMode = choice.brushMode }
    }
}

/// The trackpad pointer over the canvas, in the shape the current tool asks for (see `CanvasCursor`).
private final class PointerShapes: NSObject, UIPointerInteractionDelegate {
    static let shared = PointerShapes()
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        switch CanvasCursor.current.shape {
        case .system: return nil
        case .hidden: return .hidden()
        case .text: return UIPointerStyle(shape: .verticalBeam(length: 20), constrainedAxes: [])
        case .crosshair:
            let cross = UIBezierPath(rect: CGRect(x: -8, y: -0.75, width: 16, height: 1.5))
            cross.append(UIBezierPath(rect: CGRect(x: -0.75, y: -8, width: 1.5, height: 16)))
            return UIPointerStyle(shape: .path(cross), constrainedAxes: [])
        }
    }
    func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest,
                            defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        defaultRegion
    }
}
