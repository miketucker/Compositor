import UIKit

/// Keeps iPadOS's typing bar out of the editor: the strip of undo, paste, dictation and keyboard buttons (and word
/// suggestions) it shows along the bottom when a field is typed in with a hardware keyboard or the Pencil. Every text
/// field and text view has its shortcuts taken away as it starts editing, and no suggestions, which leaves the bar
/// nothing to show. The editor's own undo, the clipboard and the tool bars cover what it offered.
enum TextInputChrome {
    @MainActor private static var observers: [NSObjectProtocol] = []

    @MainActor static func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { (note.object as? UIResponder).map(strip) }
            })
        }
    }

    /// Takes the shortcuts and suggestions away from one field, and has iPadOS look again.
    @MainActor static func strip(_ responder: UIResponder) {
        responder.inputAssistantItem.leadingBarButtonGroups = []
        responder.inputAssistantItem.trailingBarButtonGroups = []
        if let field = responder as? UITextField {
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.inlinePredictionType = .no
        } else if let view = responder as? UITextView {
            view.autocorrectionType = .no
            view.spellCheckingType = .no
            view.inlinePredictionType = .no
        }
        responder.reloadInputViews()
    }
}
