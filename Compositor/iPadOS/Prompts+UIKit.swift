import Foundation

extension Prompts {
    /// Asks with an alert in the window, answering once a button is chosen with its index.
    static func ask(_ prompt: Prompt, answer: @escaping (Int) -> Void) {
        SceneDialogs.shared.ask(prompt, answer: answer)
    }
}
