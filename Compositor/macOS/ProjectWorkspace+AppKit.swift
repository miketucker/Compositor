import AppKit

extension ProjectWorkspace {
    /// Lets a tab's controller show its dialogs on the workspace's window.
    func attach(_ controller: ProjectController) { controller.window = window }

    func chooseProjectsToOpen() async -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.compositorProject]
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        let response = if let window { await panel.beginSheetModal(for: window) } else { await panel.begin() }
        guard response == .OK else { return [] }
        return panel.urls
    }

    func closeWindow(_ window: NSWindow) async {
        guard await confirmQuit() else { return }
        removeAllTabs()
        window.close()
    }
}
