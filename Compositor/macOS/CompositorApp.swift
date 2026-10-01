import SwiftUI
import Sparkle

@main
struct CompositorApp: App {
    @NSApplicationDelegateAdaptor(CompositorApplicationDelegate.self) private var applicationDelegate
    var body: some Scene {
        Window("Compositor", id: "editor") {
            ProjectWorkspaceView(applicationDelegate: applicationDelegate).roundedControls()
        }
            .defaultSize(width: 1180, height: 780)
            // Files opened from Finder or dropped on the Dock icon go to the app delegate, which imports them into
            // the open window. Left to SwiftUI, each one builds a throwaway window and fades the editor out and back.
            .handlesExternalEvents(matching: [])
            // A first launch fills the screen (without going full screen); after that macOS reopens the window at the
            // size it was left.
            .defaultWindowPlacement { _, context in
                WindowPlacement(size: context.defaultDisplay.visibleRect.size)
            }
            // The project's name is already on its tab, so the toolbar doesn't repeat it as a window title.
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .commands {
                EditorCommands(workspace: applicationDelegate.workspace, showEditor: { applicationDelegate.showEditor?() })
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { applicationDelegate.updater.checkForUpdates(nil) }
                }
                // ⌘H toggles the Move tool's transform controls instead of hiding the app, so Hide keeps its
                // place in the app menu without the shortcut.
                CommandGroup(replacing: .appVisibility) {
                    Button("Hide Compositor") { NSApp.hide(nil) }
                    Button("Hide Others") { NSApp.hideOtherApplications(nil) }
                        .configuredKeyboardShortcut("h", modifiers: [.command, .option])
                    Button("Show All") { NSApp.unhideAllApplications(nil) }
                }
            }
    }
}
