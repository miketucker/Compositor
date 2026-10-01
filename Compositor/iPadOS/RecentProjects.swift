import Foundation
import Observation
import UIKit

/// The projects opened lately, most recent first, for the welcome screen and File > Open Recent. iPad hands the app a
/// project somewhere else in Files only for as long as it's open, so each is kept as a bookmark that can open it again.
@MainActor @Observable
final class RecentProjects {
    static let shared = RecentProjects()
    private(set) var urls: [URL] = []
    @ObservationIgnored private var activation: NSObjectProtocol?
    private static let storageKey = "recentProjectBookmarks"
    private static let limit = 10

    private init() {
        refresh()
        activation = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in RecentProjects.shared.refresh() }
        }
    }

    private var bookmarks: [Data] {
        get { UserDefaults.standard.array(forKey: Self.storageKey) as? [Data] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.storageKey) }
    }

    func note(_ url: URL) {
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        let path = url.standardizedFileURL.path
        bookmarks = Array(([bookmark] + bookmarks.filter { Self.resolve($0)?.standardizedFileURL.path != path }).prefix(Self.limit))
        refresh()
    }

    func clear() {
        bookmarks = []
        refresh()
    }

    /// Projects since moved or deleted are left out, checked again each time the app comes back.
    func refresh() {
        urls = bookmarks.compactMap(Self.resolve).filter { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private static func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
