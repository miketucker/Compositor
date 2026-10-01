import CoreTransferable
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iPad's dialogs for a project, and the way it saves: as it goes. A project is written a moment after each change,
/// when the app goes to the background, and before its tab closes, so there is no Save and nothing to lose. A new
/// project gets its file straight away, in the app's own folder (On My iPad › Compositor in Files).
extension ProjectController {
    var canPresentDialogs: Bool { dialogs != nil }
    var isPresentingSheet: Bool { dialogs?.sheet != nil }

    /// Shows `content` as a sheet until it finishes, and returns what it finished with.
    func presentSheet<Result, Content: View>(title: String,
                                             _ content: (@escaping (Result?) -> Void) -> Content) async -> Result? {
        guard let dialogs else { return nil }
        return await dialogs.presentSheet(title: title, content)
    }

    private var exportName: String {
        session.projectURL?.deletingPathExtension().lastPathComponent ?? tabName
    }

    private var tabName: String {
        workspace?.tabs.first { $0.controller === self }?.defaultName ?? "Untitled"
    }

    /// The Share button: the flattened image as a PNG named `name`, the project's, for the share sheet. It's made
    /// first, with the editor dimmed as for any export, and the sheet opens on the finished file (see `ShareSheet`).
    func share(named name: String, from anchor: UIView?) async {
        guard session.document != nil, begin() else { return }
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: name).appendingPathExtension("png")
        do {
            guard let snapshot = session.projectSnapshot() else { session.isProjectBusy = false; return }
            let data = try await ImageExporter.shared.pngData(snapshot)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            session.isProjectBusy = false
            await showError("Couldn’t share the image", error: error)
            return
        }
        session.isProjectBusy = false
        await ShareSheet.present(url, title: name, from: anchor)
    }

    func exportPNG() async {
        guard let dialogs, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        do {
            let data = try await ImageExporter.shared.pngData(snapshot)
            _ = await dialogs.export(data, type: .png, name: exportName + ".png")
        } catch { await showError("Couldn’t export PNG", error: error) }
    }

    func exportJPEG() async {
        guard let dialogs, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            let data: Data? = await presentSheet(title: "Export JPEG") { [session] finish in
                JPEGExportSheet(raster: raster, session: session, finish: finish)
            }
            guard let data else { return }
            _ = await dialogs.export(data, type: .jpeg, name: exportName + ".jpg")
        } catch { await showError("Couldn’t export JPEG", error: error) }
    }

    /// Adds the flattened image to the photo library, which is where most images on iPad go next.
    func saveToPhotos() async {
        guard session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = session.projectSnapshot() else { return }
        do {
            let data = try await ImageExporter.shared.pngData(snapshot)
            guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
                await showError("Couldn’t save to Photos", error: PhotosAccessError())
                return
            }
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
        } catch { await showError("Couldn’t save to Photos", error: error) }
    }

    /// Brings in photos chosen from the library, where most of an iPad's pictures are, as Import Images brings in files.
    func importPhotos() async {
        guard let dialogs else { return }
        let items = await dialogs.choosePhotos()
        guard !items.isEmpty, begin() else { return }
        // Each comes as a file in its own format (HEIC, RAW and all), downloaded from iCloud first if it has to be.
        var files: [URL] = []
        for item in items {
            if let photo = try? await item.loadTransferable(type: PhotoFile.self) { files.append(photo.url) }
        }
        session.isProjectBusy = false
        guard !files.isEmpty else {
            await showError("Couldn’t import photos", error: CocoaError(.fileReadUnknown))
            return
        }
        await session.importImages(files)
        for file in files { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    }

    // MARK: The project's file

    /// Renames the project's file where it is, as Files would, from the Rename in the title's menu. A project not
    /// written yet is written first.
    func rename(to proposed: String) async {
        // A file's name: no slashes or colons, which Files won't take either.
        let name = proposed.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, session.document != nil else { return }
        if session.projectURL == nil { guard await save() else { return } }
        guard let url = session.projectURL, name != url.deletingPathExtension().lastPathComponent, begin() else { return }
        defer { session.isProjectBusy = false }
        autosave?.cancel()
        await finishWriting()
        let destination = url.deletingLastPathComponent().appending(path: name).appendingPathExtension("comp")
        // Only a change of case can land on the file itself.
        let recased = destination.path.lowercased() == url.path.lowercased()
        guard recased || !FileManager.default.fileExists(atPath: destination.path) else {
            await showError("Couldn’t rename the project", error: ProjectNameTaken(name: name))
            return
        }
        // Held throughout: letting go of the watch lets go of the file too.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        stopWatchingProject()
        var failure: Error?, coordinationError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: url, options: .forMoving, writingItemAt: destination, options: .forReplacing,
                               error: &coordinationError) { from, to in
            do {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            } catch { failure = error }
        }
        if let error = coordinationError ?? failure {
            watchProject(at: url)
            await showError("Couldn’t rename the project", error: error)
            return
        }
        await adopt(destination)
    }

    /// Moves the project to a folder chosen in Files (iCloud Drive, say), from the title's menu.
    func moveProject() async {
        guard let dialogs, session.document != nil else { return }
        if session.projectURL == nil { guard await save() else { return } }
        guard let url = session.projectURL, begin() else { return }
        defer { session.isProjectBusy = false }
        autosave?.cancel()
        await finishWriting()
        // The move isn't a change made by someone else, so the watch stops for it; the file is held meanwhile.
        let scoped = url.startAccessingSecurityScopedResource()
        stopWatchingProject()
        let moved = await dialogs.chooseMoveDestination(for: url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard let moved else {
            watchProject(at: url)
            return
        }
        await adopt(moved)
    }

    /// Makes a copy of the project as it is now, in the app's folder, and opens it in a tab of its own.
    func duplicate() async {
        guard let workspace, session.document != nil, begin() else { return }
        let destination = ProjectLocations.newProjectURL(named: exportName + " copy")
        do {
            guard let snapshot = session.projectSnapshot() else { session.isProjectBusy = false; return }
            let quickLook = await ImageExporter.shared.quickLookImages(snapshot)
            try await ProjectStore.shared.save(snapshot, to: destination, quickLook: quickLook)
        } catch {
            session.isProjectBusy = false
            await showError("Couldn’t duplicate the project", error: error)
            return
        }
        session.isProjectBusy = false
        await workspace.open(destination)
    }

    /// Makes `url` the project's file: where it saves, what's watched, and what Open Recent lists.
    private func adopt(_ url: URL) async {
        session.projectURL = url
        RecentProjects.shared.note(url)
        await rememberProjectDigest(for: url)
        watchProject(at: url)
    }

    /// Where a project with no file yet goes: a new file in the app's own folder, named after its tab. Duplicating
    /// (asNew) makes a copy there beside it.
    func chooseProjectDestination(asNew: Bool) async -> URL? {
        let name = asNew ? exportName + " copy" : exportName
        return ProjectLocations.newProjectURL(named: name)
    }

    func chooseProjectToOpen() async -> URL? {
        await dialogs?.chooseFiles([.compositorProject], multiple: false).first
    }

    /// Nothing to ask: iPad keeps projects saved, so closing or replacing one saves what's left.
    func askToSaveChanges() async -> SaveChoice { .save }

    func ask(_ prompt: Prompt) async -> Int {
        guard let dialogs else { return prompt.cancel ?? 0 }
        return await dialogs.ask(prompt)
    }

    func showError(_ title: String, error: Error) async {
        _ = await dialogs?.ask(Prompt(title: title, message: error.localizedDescription, buttons: ["OK"], cancel: nil))
    }

    // MARK: Autosave

    /// How long the project waits after a change before it's saved, so a run of strokes is saved once.
    static let autosaveDelay: Duration = .seconds(2)

    /// Saves a moment after the last change.
    func scheduleAutosave() {
        autosave?.cancel()
        guard session.document != nil else { return }
        autosave = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.autosaveNow()
        }
    }

    /// Saves now if there is anything to save and nothing in the way; otherwise tries again shortly.
    func autosaveNow() async {
        autosave?.cancel()
        guard session.document != nil, session.isModified || session.projectURL == nil else { return }
        guard canAutosave else { scheduleAutosave(); return }
        // Changed on disk since it was last read or written (by an agent, say, or another device through iCloud):
        // that's looked at first, and written over only if the person chooses to keep what they have.
        if let url = session.projectURL, await changedOnDisk(url) {
            noteExternalChange()
            return
        }
        await save()
    }

    /// Nothing is half done: no stroke, drag, dialog or edit waiting for Apply, which saving would cut short.
    private var canAutosave: Bool {
        canStart && session.transformEdit == nil && session.cropRect == nil && session.textDraft == nil
            && session.hueSaturation == nil && session.levels == nil && session.filterEdit == nil
            && session.gradientEdit == nil && session.pixelMove == nil && session.colorPicker == nil
            && session.colorRange == nil && !externalChanges.pending && !externalChanges.checking
    }

    private func changedOnDisk(_ url: URL) async -> Bool {
        guard let known = externalChanges.knownDigest else { return false }
        let digest = await Task.detached(priority: .utility) { () -> ProjectDigest? in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try? ProjectDigest.compute(for: url)
        }.value
        return digest.map { $0 != known } ?? false
    }

    /// A project somewhere else in Files is only reachable while the app holds it open: held from when it's opened or
    /// first saved until its tab closes, so the watch on it and each save can reach it.
    func keepAccess(to url: URL) {
        guard ProjectAccess.held[ObjectIdentifier(self)] != url else { return }
        releaseAccess()
        if url.startAccessingSecurityScopedResource() { ProjectAccess.held[ObjectIdentifier(self)] = url }
    }

    func releaseAccess() {
        ProjectAccess.held.removeValue(forKey: ObjectIdentifier(self))?.stopAccessingSecurityScopedResource()
    }
}

/// The project files the app is holding open, by the controller holding each.
@MainActor private enum ProjectAccess {
    static var held: [ObjectIdentifier: URL] = [:]
}

private struct PhotosAccessError: LocalizedError {
    var errorDescription: String? { "Allow Compositor to add photos in Settings › Privacy & Security › Photos." }
}

private struct ProjectNameTaken: LocalizedError {
    let name: String
    var errorDescription: String? { "There’s already a project named “\(name)” in that folder." }
}

/// A photo from the library as a file of its own, in its original format, imported as any image file is.
nonisolated private struct PhotoFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            // The picker's copy is gone once this returns, so it's copied somewhere that lasts until the import is done.
            let folder = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appending(path: received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PhotoFile(url: copy)
        }
    }
}

/// Where the app keeps projects of its own.
enum ProjectLocations {
    /// The app's folder in Files: On My iPad › Compositor.
    static var documents: URL { URL.documentsDirectory }

    /// A name no project in the app's folder has yet: "Untitled", then "Untitled 2" and so on.
    static func newProjectURL(named name: String) -> URL {
        let base = name.isEmpty ? "Untitled" : name
        var candidate = documents.appendingPathComponent(base).appendingPathExtension("comp")
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = documents.appendingPathComponent("\(base) \(number)").appendingPathExtension("comp")
            number += 1
        }
        return candidate
    }
}
