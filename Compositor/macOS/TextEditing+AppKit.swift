import AppKit

/// Text being typed in a field or on the canvas keeps its own editing keys: undo, the clipboard, Select All and the
/// deletions Photoshop's fill shortcuts share.
enum TextEditing {
    /// A text view has the keyboard focus.
    static var isActive: Bool { NSApp.keyWindow?.firstResponder is NSTextView }

    static func undo() {
        if isActive { NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil) }
    }
    static func redo() {
        if isActive { NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil) }
    }
    /// Each of these answers whether the text took it.
    static func cut() -> Bool { send(#selector(NSText.cut(_:))) }
    static func copy() -> Bool { send(#selector(NSText.copy(_:))) }
    static func paste() -> Bool { send(#selector(NSText.paste(_:))) }
    /// Offered to the responder chain first, which covers every kind of text control rather than NSTextView alone.
    static func selectAll() -> Bool { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
    static func deleteWordBackward() { NSApp.sendAction(#selector(NSResponder.deleteWordBackward(_:)), to: nil, from: nil) }
    static func deleteToBeginningOfLine() { NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil) }

    private static func send(_ action: Selector) -> Bool {
        guard isActive else { return false }
        NSApp.sendAction(action, to: nil, from: nil)
        return true
    }
}
