import AppKit

extension Prompts {
    /// Asks with a modal alert and answers before returning, with the index of the button chosen.
    static func ask(_ prompt: Prompt, answer: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        for button in prompt.buttons { alert.addButton(withTitle: button) }
        let response = alert.runModal()
        answer(response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
    }
}
