import SwiftUI
import UIKit

@main
struct CompositorApp: App {
    /// The window's projects, one per tab. iPad runs Compositor in one window.
    @State private var workspace = ProjectWorkspace()

    init() { TextInputChrome.install() }

    var body: some Scene {
        WindowGroup {
            ProjectWorkspaceView(workspace: workspace)
        }
        .commands { EditorCommands(workspace: workspace) }
    }
}

struct ProjectWorkspaceView: View {
    let workspace: ProjectWorkspace
    @Environment(\.scenePhase) private var phase
    /// The projects open in the window, kept with it so they open again when iPadOS relaunches the app it quit in the
    /// background. Closing the window from the app switcher lets them go, as it does everything kept with a window.
    @SceneStorage("openProjects") private var openProjects: Data?
    @State private var reopened = false
    private var session: EditorSession { workspace.current.session }

    var body: some View {
        NavigationStack {
            ContentView(session: session, workspace: workspace)
                .id(workspace.current.id)
                .disabled(workspace.isManaging)
                .psdConversionSheet(session)
                .rawDevelopSheet(session)
                // The status bar sits on the window's bottom edge: its text, at either end, is clear of the home
                // indicator in the middle, so the margin iPadOS keeps for it would only be empty space. Ignored
                // together with the keyboard's, so the editor keeps its size with the keyboard up as well.
                .ignoresSafeArea([.container, .keyboard], edges: .bottom)
        }
        // The keyboard, or the bar iPadOS shows for a hardware keyboard, covers the bottom of the window rather than
        // squeezing the editor above it: the canvas and panels stay where they are while a field is typed in.
        .ignoresSafeArea(.keyboard)
        .overlay { FloatingPanelsOverlay().ignoresSafeArea(.keyboard) }
        .overlay { PencilPaletteOverlay() }
        .sceneDialogs(SceneDialogs.shared)
        .onAppear {
            workspace.dialogs = .shared
            for tab in workspace.tabs { workspace.attach(tab.controller) }
            Task { await reopenProjects() }
        }
        .onChange(of: workspace.tabs.map(\.session.projectURL)) { _, _ in rememberOpenProjects() }
        .onChange(of: workspace.selectedID) { _, _ in rememberOpenProjects() }
        // Opened from Files, or shared from another app.
        .onOpenURL { url in Task { await workspace.receive([url]) } }
        // A project saves itself a moment after each change, and whenever the app leaves the screen.
        .onChange(of: session.history.currentRevision) { _, _ in workspace.current.controller.scheduleAutosave() }
        .onChange(of: session.document?.id) { _, _ in workspace.current.controller.scheduleAutosave() }
        .onChange(of: phase) { _, phase in
            if phase != .active { saveInBackground() }
        }
        .preferredColorScheme(.dark)
    }

    /// Opens again what was open when iPadOS last quit the app, with the same one on screen. One since moved or
    /// deleted is left out without a word. (UI tests turn this off with `-reopensProjects NO`, to start afresh.)
    private func reopenProjects() async {
        guard !reopened else { return }
        defer {
            reopened = true
            rememberOpenProjects()
        }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "reopensProjects") == nil || defaults.bool(forKey: "reopensProjects"),
              let data = openProjects, let saved = try? JSONDecoder().decode(OpenProjects.self, from: data) else { return }
        var selected: UUID?
        for (index, bookmark) in saved.bookmarks.enumerated() {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            let exists = FileManager.default.fileExists(atPath: url.path)
            if scoped { url.stopAccessingSecurityScopedResource() }
            guard exists, await workspace.open(url) else { continue }
            if index == saved.selected { selected = workspace.current.id }
        }
        if let selected { workspace.select(selected) }
    }

    /// Notes the projects open now, once any from before are open again.
    private func rememberOpenProjects() {
        guard reopened else { return }
        var saved = OpenProjects()
        for tab in workspace.tabs {
            guard let url = tab.session.projectURL, let bookmark = try? url.bookmarkData() else { continue }
            if tab.id == workspace.selectedID { saved.selected = saved.bookmarks.count }
            saved.bookmarks.append(bookmark)
        }
        openProjects = try? JSONEncoder().encode(saved)
    }

    /// Saves every project that has changes, asking iPadOS for the time to finish if the app is on its way out.
    private func saveInBackground() {
        let task = BackgroundSave()
        task.begin()
        Task {
            await workspace.saveAll()
            task.end()
        }
    }
}

/// The window's open projects, as bookmarks (so one elsewhere in Files can be reached again), and which is on screen.
private struct OpenProjects: Codable {
    var bookmarks: [Data] = []
    var selected: Int?
}

/// The time iPadOS allows an app that's leaving the screen to finish writing.
@MainActor private final class BackgroundSave {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save projects") { [weak self] in self?.end() }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
