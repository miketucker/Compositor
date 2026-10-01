import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Mac's dialogs for a project: sheets on its window, open and save panels, and alerts.
extension ProjectController {
    var canPresentDialogs: Bool { window != nil }
    var isPresentingSheet: Bool { window?.attachedSheet != nil }

    /// Shows `content` as a sheet on the window until it finishes, and returns what it finished with.
    func presentSheet<Result, Content: View>(title: String,
                                             _ content: (@escaping (Result?) -> Void) -> Content) async -> Result? {
        guard let window else { return nil }
        return await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = title
            sheet.contentViewController = NSHostingController(rootView: content { result in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                // Release the hosted view and its closure after dismissal.
                sheet.contentViewController = nil
                continuation.resume(returning: result)
            })
            window.beginSheet(sheet)
        }
    }

    func exportPNG() async {
        guard session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export PNG"
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".png"
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { try await ImageExporter.shared.exportPNG(snapshot, to: url) }
        catch { await showError("Couldn’t export PNG", error: error) }
    }

    func exportJPEG() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            let data: Data? = await presentSheet(title: "Export JPEG") { [session] finish in
                JPEGExportSheet(raster: raster, session: session, finish: finish)
            }
            guard let data else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.jpeg]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = "Export JPEG"
            panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".jpg"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try await ImageExporter.shared.write(data, to: url)
        } catch { await showError("Couldn’t export JPEG", error: error) }
    }

    /// Where a project with no file yet (or saved as a new one) goes: asked with the Save panel.
    func chooseProjectDestination(asNew: Bool) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.compositorProject]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = session.projectURL?.lastPathComponent ?? "Untitled.comp"
        panel.title = asNew ? "Save Project As" : "Save Project"
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }

    func chooseProjectToOpen() async -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.compositorProject]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.title = "Open Project"
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return nil }
        return url
    }

    func close(_ window: NSWindow) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.close(tab.id); return
        }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed {
            session.clearProject()
            stopWatchingProject()
            window.close()
        }
    }

    func askToSaveChanges() async -> SaveChoice {
        let alert = NSAlert()
        alert.messageText = "Save changes to \(session.projectURL?.lastPathComponent ?? "Untitled")?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        let response = await show(alert)
        if response == .alertFirstButtonReturn { return .save }
        return response == .alertThirdButtonReturn ? .discard : .cancel
    }

    /// Asks with an alert on the window, answering with the index of the button chosen.
    func ask(_ prompt: Prompt) async -> Int {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        for button in prompt.buttons { alert.addButton(withTitle: button) }
        return await show(alert).rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    }

    func showError(_ title: String, error: Error) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await show(alert)
    }

    /// A Mac app is given a project for as long as it likes once it's been chosen, so there's nothing to hold.
    func keepAccess(to url: URL) {}
    func releaseAccess() {}

    private func show(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }
}
