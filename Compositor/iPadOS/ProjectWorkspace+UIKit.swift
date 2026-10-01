import Foundation

extension ProjectWorkspace {
    /// Lets a tab's controller show its dialogs in the window.
    func attach(_ controller: ProjectController) { controller.dialogs = dialogs }

    func chooseProjectsToOpen() async -> [URL] {
        await dialogs?.chooseFiles([.compositorProject], multiple: true) ?? []
    }

    /// iPad's drags carry what they hold, not where from, so any tab takes a drop; one that lands where it started
    /// adds a copy, as pasting does.
    func canReceiveDrag(into destination: UUID?) -> Bool { true }

    /// Saves every tab that has changes: the app is going to the background, where iPadOS may close it.
    func saveAll() async {
        for tab in tabs where tab.session.document != nil { await tab.controller.autosaveNow() }
    }
}
