import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Opens, saves and resizes the project in one tab. What it asks and shows goes through its platform's dialogs
/// (ProjectController+AppKit on the Mac, ProjectController+UIKit on iPad): panels and sheets on the Mac's window, and
/// the scene's SwiftUI sheets and file pickers on iPad, where projects save themselves as they change.
@MainActor
final class ProjectController {
    let session: EditorSession
    #if os(macOS)
    weak var window: NSWindow?
    #else
    /// The scene the project is shown in, which presents its dialogs.
    weak var dialogs: SceneDialogs?
    /// Saves the project a moment after each change (see ProjectController+UIKit).
    var autosave: Task<Void, Never>?
    #endif
    weak var workspace: ProjectWorkspace?
    var saveGeneration = 0
    /// Keeps the document in step with its package when something else writes it. See ProjectController+ExternalChanges.
    let externalChanges = ExternalChangeState()
    var canStart: Bool {
        session.canStartProjectOperation && workspace?.isManaging != true
    }
    init(session: EditorSession) { self.session = session }

    func begin() -> Bool {
        guard session.canStartProjectOperation else { return false }
        session.cancelCrop()
        session.commitTransform()
        session.isProjectBusy = true
        return true
    }

    @discardableResult
    func save(asNew: Bool = false) async -> Bool {
        guard session.document != nil else { return false }
        // Another save still writing finishes first; then this one saves whatever has changed since.
        await finishWriting()
        guard begin() else { return false }
        let prepared = await prepareSave(asNew: asNew)
        // Only the snapshot (and the Save panel) holds the tools. The document is captured, so editing can go on
        // while the package is written in the background, as in Photoshop.
        session.isProjectBusy = false
        guard let prepared else { return false }
        return await write(prepared.snapshot, to: prepared.destination, revision: prepared.revision)
    }

    /// The save still writing, if any. Close, quit and replacing the document wait for it.
    var writing: Task<Bool, Never>?
    func finishWriting() async { if let writing { _ = await writing.value } }

    func canvasSize() async {
        guard canPresentDialogs, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: CanvasSizeOptions? = await presentSheet(title: "Canvas Size") { [session] finish in
            CanvasSizeSheet(document: document, session: session, finish: finish)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
            session.applyDocumentSize(resized, actionName: "Canvas Size")
        } catch { await showError("Couldn’t change canvas size", error: error) }
    }

    func imageSize() async {
        guard canPresentDialogs, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: ImageSizeOptions? = await presentSheet(title: "Image Size") { finish in
            ImageSizeSheet(document: document, finish: finish)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let resized = try await ImageResizer.shared.resize(snapshot, to: options)
            session.applyImageSize(resized)
        } catch { await showError("Couldn’t resize the image", error: error) }
    }

    func trim() async {
        guard canPresentDialogs, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: TrimOptions? = await presentSheet(title: "Trim") { finish in TrimSheet(finish: finish) }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            guard let resized = try await ImageTrim.trim(snapshot, options: options) else {
                return
            }
            session.applyDocumentSize(resized, actionName: "Trim")
        } catch { await showError("Couldn’t trim image", error: error) }
    }

    /// View > Grid Settings…: changes only how the grid is drawn and snapped to, so nothing is saved or undone. The
    /// grid shows while the sheet is open, changing as it's edited, and goes back to how it was on Cancel.
    func gridSettings() async {
        guard canPresentDialogs, !isPresentingSheet else { return }
        let original = (grid: session.layoutGrid, appearance: session.gridAppearance, shown: session.showsGrid)
        session.showsGrid = true
        let settings: (LayoutGrid, GridAppearance)? = await presentSheet(title: "Grid") { [session] finish in
            GridSettingsSheet(
                session: session, grid: original.grid, appearance: original.appearance,
                preview: { grid, appearance in
                    session.layoutGrid = grid
                    session.gridAppearance = appearance
                }, finish: finish)
        }
        session.showsGrid = original.shown
        session.layoutGrid = settings?.0 ?? original.grid
        session.gridAppearance = settings?.1 ?? original.appearance
    }

    func saveCurrent(asNew: Bool = false) async -> Bool {
        guard session.document != nil else { return true }
        guard let prepared = await prepareSave(asNew: asNew) else { return false }
        return await write(prepared.snapshot, to: prepared.destination, revision: prepared.revision)
    }

    /// The document as it is now, and where it goes: asks where to save it when it has no file yet (or Save As).
    private func prepareSave(asNew: Bool) async -> (snapshot: ProjectSnapshot, destination: URL, revision: UUID)? {
        let revision = session.history.currentRevision
        guard let snapshot = session.projectSnapshot() else { return nil }
        var destination = asNew ? nil : session.projectURL
        if destination == nil { destination = await chooseProjectDestination(asNew: asNew) }
        guard let destination else { return nil }
        return (snapshot, destination, revision)
    }

    /// Writes a captured document in the background. Only that captured version counts as saved.
    func write(_ snapshot: ProjectSnapshot, to destination: URL, revision: UUID) async -> Bool {
        let task = Task { @MainActor [self] () -> Bool in
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            // Our own save changes the package too; the watch ignores events until the saved bytes are remembered.
            externalChanges.saving = true
            defer { externalChanges.saving = false }
            do {
                let quickLook = await ImageExporter.shared.quickLookImages(snapshot)
                try await ProjectStore.shared.save(snapshot, to: destination, quickLook: quickLook)
                session.projectURL = destination
                session.history.markSaved(revision)
                saveGeneration += 1
                RecentProjects.shared.note(destination)
                await rememberProjectDigest(for: destination)
                watchProject(at: destination)
                return true
            } catch {
                await showError("Couldn’t save the project", error: error)
                return false
            }
        }
        writing = task
        let saved = await task.value
        if writing == task { writing = nil }
        return saved
    }

    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        if let workspace { return await workspace.open(suppliedURL) }
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        var source = suppliedURL
        if source == nil { source = await chooseProjectToOpen() }
        guard let source else { return false }
        // A recent project deleted in Finder: name the project, not the manifest inside it the load would miss.
        guard FileManager.default.fileExists(atPath: source.path) else {
            RecentProjects.shared.refresh()
            await showError("Couldn’t open the project", error: CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path]))
            return false
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            // Validate first. A corrupt project never discards the live document.
            var snapshot = try await ProjectStore.shared.load(from: source)
            let previousSave = saveGeneration
            guard await confirmReplacement() else { return false }
            // Saving in the confirmation can replace the very file being opened.
            if saveGeneration != previousSave,
               session.projectURL?.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() {
                snapshot = try await ProjectStore.shared.load(from: source)
            }
            session.installProject(snapshot, from: source)
            RecentProjects.shared.note(source)
            await rememberProjectDigest(for: source)
            watchProject(at: source)
            return true
        } catch {
            await showError("Couldn’t open the project", error: error)
            return false
        }
    }

    func newCanvas() async {
        if let workspace { workspace.newCanvas(); return }
        guard begin() else { return }
        let proceed = await confirmReplacement()
        session.isProjectBusy = false
        if proceed { session.clearProject(); stopWatchingProject() }
    }

    func confirmQuit() async -> Bool {
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        return await confirmReplacement()
    }

    func confirmReplacement() async -> Bool {
        // A save still writing finishes before the project can be closed or replaced, so its file is never cut short.
        await finishWriting()
        guard session.isModified, session.document != nil else { return true }
        switch await askToSaveChanges() {
        case .save: return await saveCurrent()
        case .discard: return true
        case .cancel: return false
        }
    }

    enum SaveChoice { case save, cancel, discard }

    private struct Incoming {
        let files: [(URL, Bool)]
        let point: CGPoint?
        let completion: CheckedContinuation<Void, Never>
    }
    private var incoming: [Incoming] = []
    private var processing = false

    func receive(_ urls: [URL], at point: CGPoint? = nil) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.receive(urls, into: tab.id, at: point); return
        }
        guard !urls.isEmpty else { return }
        let files = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        await withCheckedContinuation { completion in
            incoming.append(Incoming(files: files, point: point, completion: completion))
            if !processing {
                processing = true
                Task { await drainIncoming() }
            }
        }
    }

    private func drainIncoming() async {
        while !incoming.isEmpty {
            let request = incoming.removeFirst()
            await session.waitForFileRequest()
            let urls = request.files.map(\.0)
            let projects = urls.filter { $0.pathExtension.lowercased() == "comp" }
            if projects.count > 1 {
                await showError("Open one project at a time", error: ProjectError.invalid)
            } else {
                var proceed = true
                if let project = projects.first { proceed = await open(project) }
                if proceed {
                    await session.importImages(urls.filter { $0.pathExtension.lowercased() != "comp" },
                                               at: projects.isEmpty ? request.point : nil)
                }
            }
            for (url, scoped) in request.files where scoped { url.stopAccessingSecurityScopedResource() }
            request.completion.resume()
        }
        processing = false
    }
}
