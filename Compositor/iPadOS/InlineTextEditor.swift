import UIKit

/// The text system on the canvas: selection, marked text and dictation, the clipboard and local undo stay with
/// UITextView. Its logical bounds are layer pixels; the view's transform supplies zoom and rotation. Its glyphs are
/// clear: the canvas draws the text as the layer's own pixels underneath, as Photoshop does, so what is typed looks the
/// same at any zoom as it will once it is committed. It lays text out with TextKit 1, as the canvas does, so the caret
/// sits on the letters the canvas draws.
final class CanvasTextView: UITextView {
    weak var editor: InlineTextEditor?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let key = presses.first?.key, let session = editor?.canvas?.session else {
            super.pressesBegan(presses, with: event); return
        }
        let flags = KeyModifiers(key.modifierFlags)
        if key.keyCode == .keyboardEscape { session.cancelText(); return }
        // Command-Return finishes, as on the Mac.
        if key.keyCode == .keyboardReturnOrEnter || key.keyCode == .keypadEnter, flags.contains(.command) {
            _ = session.finishText(); return
        }
        // Option with the arrows sets spacing, as in Photoshop: left and right the tracking, up and down the leading.
        // Shift makes each step ten.
        if flags.contains(.option), [.keyboardLeftArrow, .keyboardRightArrow, .keyboardUpArrow, .keyboardDownArrow].contains(key.keyCode) {
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            switch key.keyCode {
            case .keyboardLeftArrow: session.changeTextStyle { $0.tracking -= step }
            case .keyboardRightArrow: session.changeTextStyle { $0.tracking += step }
            case .keyboardUpArrow: session.changeTextStyle { $0.leading = max(1, $0.lineHeight - step) }
            default: session.changeTextStyle { $0.leading = $0.lineHeight + step }
            }
            return
        }
        super.pressesBegan(presses, with: event)
    }

    // Pasted text takes the text's own style, as it does on the Mac.
    override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string else { return }
        insertText(text)
    }
}

final class InlineTextEditor: UIView, UITextViewDelegate {
    weak var canvas: CanvasView?
    let textView = CanvasTextView(usingTextLayoutManager: false)
    var draftID: UUID?
    private var shownStyle: LayerTextStyle?
    /// The style after an edit UITextView has accepted but not yet made, with its color and font runs moved to fit.
    private var pendingStyle: LayerTextStyle?
    private var synchronizing = false
    private var logicalSize = CGSize(width: 360, height: 160)
    private var handleSize: CGFloat = 6
    /// The transform the editor is actually showing. Point text grows as it is typed, so this is not always the
    /// draft's own transform, and a resize has to start from what is on screen or the text jumps.
    private(set) var shownTransform: LayerTransform?
    private struct Geometry: Equatable {
        let transform: LayerTransform
        let logicalSize: CGSize
        let anchor: CGPoint
        let scale: CGFloat
    }
    private var shownGeometry: Geometry?
    private var measuredStyle: LayerTextStyle?
    private var measuredSize: CGSize = .zero
    private var resize: (handle: Int, draft: TextDraft, transform: LayerTransform, start: CGPoint)?

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: .zero)
        textView.editor = self
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.accessibilityLabel = "Canvas text"
        textView.inlinePredictionType = .no
        textView.inputAssistantItem.leadingBarButtonGroups = []
        textView.inputAssistantItem.trailingBarButtonGroups = []
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        layer.anchorPoint = .zero
        addSubview(textView)
        clipsToBounds = false
        // Shown once it has been placed, so it never appears for a frame somewhere else.
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func focus() {
        if !textView.isFirstResponder { textView.becomeFirstResponder() }
    }

    func synchronize(_ draft: TextDraft) {
        guard let canvas, let document = canvas.session.document else { return }
        let fresh = draftID != draft.id
        draftID = draft.id
        let style = draft.style
        let layer = document.layers.first { $0.id == draft.layerID }
        // Point text has no box: it is as big as what has been typed, growing as it is typed.
        if let boxSize = style.boxSize {
            logicalSize = boxSize
        } else {
            if measuredStyle != style {
                measuredSize = EditorSession.textBoxSize(style)
                measuredStyle = style
            }
            logicalSize = measuredSize
        }
        var transform = draft.transform ?? LayerTransform(origin: draft.origin, size: logicalSize)
        // Point text already on a layer grows as it is typed too, keeping whatever scale the layer was given.
        if style.boxSize == nil, draft.transform != nil, let asset = layer?.asset, asset.image.width > 0 {
            let factor = transform.size.width / CGFloat(asset.image.width)
            let anchor = transform.point(.zero)
            transform.size = CGSize(width: logicalSize.width * factor, height: logicalSize.height * factor)
            let moved = transform.point(.zero)
            transform.origin.x += anchor.x - moved.x
            transform.origin.y += anchor.y - moved.y
        }
        shownTransform = transform
        let scale = canvas.session.viewport.pointsPerPixel
        let anchor = canvas.session.viewport.viewPoint(from: transform.point(.zero), documentSize: document.size)
        let geometry = Geometry(transform: transform, logicalSize: logicalSize, anchor: anchor, scale: scale)
        if fresh || shownGeometry != geometry {
            // The layer's box in layer pixels, scaled to the zoom and turned with the layer about its top-left corner,
            // which is pinned where the layer's is on screen.
            let across = transform.size.width * scale / max(1, logicalSize.width)
            let down = transform.size.height * scale / max(1, logicalSize.height)
            self.transform = .identity
            bounds = CGRect(origin: .zero, size: logicalSize)
            center = anchor
            self.transform = CGAffineTransform(scaleX: across, y: down)
                .concatenating(CGAffineTransform(rotationAngle: transform.rotation * .pi / 180))
            let padding = LayerTextStyle.padding
            let textFrame = bounds.insetBy(dx: padding, dy: padding)
            textView.transform = .identity
            if textView.frame != textFrame { textView.frame = textFrame }
            // Mirroring belongs to the text surface, leaving the resize handles in their logical order.
            textView.transform = CGAffineTransform(scaleX: transform.flipX ? -1 : 1, y: transform.flipY ? -1 : 1)
            handleSize = max(2, 6 / max(0.01, scale * transform.size.width / logicalSize.width))
            shownGeometry = geometry
            setNeedsDisplay()
        }
        if shownStyle != style {
            synchronizing = true
            let live = textView.selectedRange
            let kept = canvas.session.textDraft?.selection ?? live
            let selection = kept.length > 0 ? kept : live
            if textView.text != style.content { textView.text = style.content }
            var attributes = EditorSession.textAttributes(style)
            attributes[.foregroundColor] = UIColor.clear
            if textView.markedTextRange == nil {
                let length = textView.text.utf16.count
                textView.textStorage.setAttributes(attributes, range: NSRange(location: 0, length: length))
                for run in style.fontRuns ?? [] where EditorSession.containsTextRun(run.location, run.length, in: length) {
                    let font = UIFont(name: run.fontName, size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
                    textView.textStorage.addAttribute(.font, value: font, range: NSRange(location: run.location, length: run.length))
                }
                textView.selectedRange = NSRange(location: min(selection.location, length),
                                                 length: min(selection.length, max(0, length - selection.location)))
            }
            let caret = selection.length > 0 ? selection.location : max(0, selection.location - 1)
            attributes[.font] = UIFont(name: style.fontName(at: caret), size: style.fontSize) ?? .systemFont(ofSize: style.fontSize)
            textView.typingAttributes = attributes
            shownStyle = style
            updateCaretColor(style)
            synchronizing = false
            setNeedsDisplay()
        }
        if isHidden { isHidden = false }
        if fresh {
            textView.undoManager?.removeAllActions()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.canvas?.session.textDraft?.id == draft.id else { return }
                self.textView.becomeFirstResponder()
                // Opening existing text puts the cursor after it, ready to add to it, unless a tap already placed it.
                if draft.layerID != nil, self.textView.selectedRange == NSRange(location: 0, length: 0) {
                    self.textView.selectedRange = NSRange(location: self.textView.text.utf16.count, length: 0)
                }
            }
        }
    }

    /// Puts the caret at a point on the canvas, where a tap on the text landed.
    func placeCaret(at point: CGPoint) {
        guard let canvas else { return }
        let local = textView.convert(point, from: canvas)
        guard let position = textView.closestPosition(to: local) else { return }
        textView.selectedTextRange = textView.textRange(from: position, to: position)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !synchronizing, let session = canvas?.session, var draft = session.textDraft else { return }
        if let pendingStyle, pendingStyle.content == textView.text {
            draft.style.colorRuns = pendingStyle.colorRuns
            draft.style.fontRuns = pendingStyle.fontRuns
        }
        pendingStyle = nil
        draft.style.content = textView.text
        // Text UITextView changed without saying how can't keep its colors and faces letter for letter.
        if !draft.style.isValid { draft.style.colorRuns = nil; draft.style.fontRuns = nil }
        draft.selection = textView.selectedRange
        shownStyle = draft.style
        session.textDraft = draft
        setNeedsDisplay()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        let length = text.utf16.count
        guard textView.text.utf16.count - range.length + length <= 100_000 else { return false }
        if !synchronizing, let draft = canvas?.session.textDraft,
           draft.style.colorRuns != nil || draft.style.fontRuns != nil {
            var style = pendingStyle ?? draft.style
            guard NSMaxRange(range) <= style.content.utf16.count else { return true }
            style.replaceCharacters(in: range, withLength: length)
            style.content = (style.content as NSString).replacingCharacters(in: range, with: text)
            pendingStyle = style
        }
        return true
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !synchronizing, let session = canvas?.session, session.textDraft?.id == draftID else { return }
        let selection = textView.selectedRange
        if session.textDraft?.selection != selection { session.textDraft?.selection = selection }
        if let style = session.textDraft?.style { updateCaretColor(style) }
    }

    private func updateCaretColor(_ style: LayerTextStyle) {
        let location = textView.selectedRange.location
        let color = style.color(at: location > 0 ? location - 1 : 0)
        textView.tintColor = .sRGB(color.red, color.green, color.blue)
    }

    /// How far either side of an edge counts as that edge, in the box's own units: a fingertip's reach on screen.
    /// Capped so a small box keeps a middle to type in.
    private var edgeReach: CGFloat {
        let perPoint = handleSize / 6
        return min(max(handleSize * 10 / 6, 22 * perPoint), min(bounds.width, bounds.height) / 3)
    }

    /// The edge or corner at a point, in handle order: a band along each edge. Nil anywhere else, which is the text.
    private func handle(at point: CGPoint) -> Int? {
        let reach = edgeReach
        let left = point.x <= reach, right = point.x >= bounds.width - reach
        let top = point.y <= reach, bottom = point.y >= bounds.height - reach
        guard point.x >= -reach, point.x <= bounds.width + reach,
              point.y >= -reach, point.y <= bounds.height + reach else { return nil }
        switch (left, right, top, bottom) {
        case (true, _, true, _): return 0
        case (_, true, true, _): return 2
        case (_, true, _, true): return 4
        case (true, _, _, true): return 6
        case (_, _, true, _): return 1
        case (_, true, _, _): return 3
        case (_, _, _, true): return 5
        case (true, _, _, _): return 7
        default: return nil
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if canvas?.session.colorPicker != nil { return false }
        let reach = edgeReach
        return bounds.insetBy(dx: -reach, dy: -reach).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event) else { return nil }
        if handle(at: point) != nil { return self }
        return super.hitTest(point, with: event) ?? self
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(PlatformColor.accent.cgColor)
        context.setLineWidth(handleSize / 6)
        context.stroke(bounds.insetBy(dx: handleSize / 12, dy: handleSize / 12))
        for unit in LayerTransform.handles {
            let square = CGRect(x: unit.x * bounds.width - handleSize / 2, y: unit.y * bounds.height - handleSize / 2,
                                width: handleSize, height: handleSize)
            context.setFillColor(UIColor.white.cgColor)
            context.fill(square)
            context.stroke(square)
        }
        // Text that doesn't fit is marked by a plus drawn in the bottom-right handle, as in Photoshop.
        let layout = textView.layoutManager
        layout.ensureLayout(for: textView.textContainer)
        let range = layout.glyphRange(for: textView.textContainer)
        if NSMaxRange(range) < layout.numberOfGlyphs {
            let unit = LayerTransform.handles[4]
            let center = CGPoint(x: unit.x * bounds.width, y: unit.y * bounds.height)
            let arm = handleSize * 0.42
            context.setStrokeColor(UIColor.black.cgColor)
            context.move(to: CGPoint(x: center.x - arm, y: center.y)); context.addLine(to: CGPoint(x: center.x + arm, y: center.y))
            context.move(to: CGPoint(x: center.x, y: center.y - arm)); context.addLine(to: CGPoint(x: center.x, y: center.y + arm))
            context.strokePath()
        }
    }

    // Dragging an edge or a corner resizes the box.

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let canvas, let document = canvas.session.document, let draft = canvas.session.textDraft,
              let handle = handle(at: touch.location(in: self)) else { return }
        let transform = shownTransform ?? draft.transform ?? LayerTransform(origin: draft.origin, size: logicalSize)
        let pixel = canvas.session.viewport.documentPoint(from: touch.location(in: canvas), documentSize: document.size)
        // Dragging a handle turns point text into a box of the size it has right now, which then holds the text and
        // wraps it, rather than scaling the text. Its scale and rotation are whatever the layer already had.
        var fixed = draft
        if fixed.style.boxSize == nil {
            fixed.style.boxSize = logicalSize
            fixed.transform = transform
            fixed.origin = transform.origin
            canvas.session.textDraft = fixed
        }
        resize = (handle, fixed, transform, pixel)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let resize, let canvas, let document = canvas.session.document else { return }
        let point = canvas.session.viewport.documentPoint(from: touch.location(in: canvas), documentSize: document.size)
        let old = resize.transform
        let dx = point.x - resize.start.x, dy = point.y - resize.start.y
        let localX = dx * cos(old.radians) + dy * sin(old.radians)
        let localY = -dx * sin(old.radians) + dy * cos(old.radians)
        let unit = LayerTransform.handles[resize.handle]
        var left: CGFloat = 0, top: CGFloat = 0, right = old.size.width, bottom = old.size.height
        let source = resize.draft.style.boxSize ?? logicalSize
        let minW = 16 * old.size.width / source.width, minH = 16 * old.size.height / source.height
        if unit.x == 0 { left = min(localX, right - minW) }
        if unit.x == 1 { right = max(left + minW, right + localX) }
        if unit.y == 0 { top = min(localY, bottom - minH) }
        if unit.y == 1 { bottom = max(top + minH, bottom + localY) }
        var draft = resize.draft
        draft.style.boxSize = CGSize(width: ((right - left) * source.width / old.size.width).rounded(),
                                     height: ((bottom - top) * source.height / old.size.height).rounded())
        guard draft.style.boxIsValid else { return }
        var transform = old
        transform.size = CGSize(width: draft.style.boxSize!.width * old.size.width / source.width,
                                height: draft.style.boxSize!.height * old.size.height / source.height)
        let anchor = old.point(CGPoint(x: left / old.size.width, y: top / old.size.height))
        let current = transform.point(.zero)
        transform.origin.x += anchor.x - current.x
        transform.origin.y += anchor.y - current.y
        guard transform.isValid else { return }
        draft.origin = transform.origin
        draft.transform = transform
        canvas.session.textDraft = draft
        canvas.synchronizeDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        resize = nil
        textView.becomeFirstResponder()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { resize = nil }
}

extension CanvasView {
    func synchronizeInlineText() {
        guard let draft = session.textDraft else {
            if let editor = inlineTextEditor {
                let hadFocus = editor.textView.isFirstResponder
                editor.removeFromSuperview()
                inlineTextEditor = nil
                needsDisplay = true
                if hadFocus { _ = becomeFirstResponder() }
            }
            return
        }
        if inlineTextEditor?.draftID != draft.id { needsDisplay = true }
        if inlineTextEditor == nil {
            let editor = InlineTextEditor(canvas: self)
            inlineTextEditor = editor
            addSubview(editor)
            needsDisplay = true
        }
        inlineTextEditor?.synchronize(draft)
    }

    func beginTextGesture(at point: CGPoint, event: CanvasPointer) {
        guard let document = session.document, session.finishText() else { return }
        let pixel = session.viewport.documentPoint(from: point, documentSize: document.size)
        let visible = document.effectiveVisibleIDs
        if let layer = document.layers.reversed().first(where: { visible.contains($0.id) && $0.liveText != nil && $0.transform.contains(pixel) }) {
            session.selectLayer(layer.id)
            session.editActiveText()
            synchronizeInlineText()
            inlineTextEditor?.placeCaret(at: point)
        } else {
            textBoxAnchor = pixel
            textBoxRect = CGRect(origin: pixel, size: .zero)
        }
        needsDisplay = true
    }
}
