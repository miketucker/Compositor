import UIKit

/// Text being typed in a field or on the canvas keeps its own editing keys: undo, the clipboard, Select All and the
/// deletions Photoshop's fill shortcuts share. The menu's shortcuts reach the app before the text does, so they hand
/// them on.
enum TextEditing {
    /// A text field or text view has the keyboard focus.
    static var isActive: Bool { focusedText != nil }

    static func undo() { focusedText?.undoManager?.undo() }
    static func redo() { focusedText?.undoManager?.redo() }
    /// Each of these answers whether the text took it.
    static func cut() -> Bool { send(#selector(UIResponderStandardEditActions.cut(_:))) }
    static func copy() -> Bool { send(#selector(UIResponderStandardEditActions.copy(_:))) }
    static func paste() -> Bool { send(#selector(UIResponderStandardEditActions.paste(_:))) }
    static func selectAll() -> Bool { send(#selector(UIResponderStandardEditActions.selectAll(_:))) }
    static func deleteWordBackward() { delete(to: .word) }
    static func deleteToBeginningOfLine() { delete(to: .line) }

    private static func send(_ action: Selector) -> Bool {
        guard let text = focusedText, text.canPerformAction(action, withSender: nil) else { return false }
        text.perform(action, with: nil)
        return true
    }

    /// Deletes back from the insertion point to the start of the word or line it's in, or the selection if there is one.
    private static func delete(to boundary: UITextGranularity) {
        guard let input = focusedText as? (UIResponder & UITextInput), let selection = input.selectedTextRange else { return }
        if !selection.isEmpty { input.replace(selection, withText: ""); return }
        guard let start = input.tokenizer.position(from: selection.start, toBoundary: boundary, inDirection: .storage(.backward)),
              let range = input.textRange(from: start, to: selection.start) else { return }
        input.replace(range, withText: "")
    }

    /// The text control with the keyboard focus, found by asking the focused responder to name itself.
    private static var focusedText: UIResponder? {
        FocusedResponder.current = nil
        UIApplication.shared.sendAction(#selector(UIResponder.compositorReportFocus), to: nil, from: nil, for: nil)
        let responder = FocusedResponder.current
        FocusedResponder.current = nil
        return responder is UITextField || responder is UITextView ? responder : nil
    }
}

@MainActor private enum FocusedResponder {
    static weak var current: UIResponder?
}

private extension UIResponder {
    @objc func compositorReportFocus() { FocusedResponder.current = self }
}
