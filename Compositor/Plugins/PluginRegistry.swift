import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

extension UTType {
    /// A plugin's folder, which the Finder and Files show as one item.
    static let compositorPlugin = UTType(exportedAs: "com.compositor.plugin", conformingTo: .package)
}

/// A brush a plugin adds, as the Brush tool's menu and bar show it.
nonisolated struct PluginBrush: Identifiable, Sendable, Hashable {
    /// The plugin's id and the brush's: "com.example.plugin/brush".
    let id: String
    let pluginID: String
    let brushID: String
    let name: String
    let symbol: String
    let options: [PluginOption]
}

/// A dither pattern a plugin adds, which any plugin brush can paint in.
nonisolated struct PluginPattern: Identifiable, Sendable, Hashable {
    /// The plugin's id and the pattern's: "com.example.plugin/pattern".
    let id: String
    let name: String
    let pattern: DitherPattern
}

/// The plugins the app has: the ones built in (`Plugins` in the app) and the ones the person has added, in
/// Application Support's Plugins folder on the Mac and in Files' Compositor › Plugins on iPad. It loads them, keeps
/// which are turned off and how their brushes are set, and asks each brush's script what its settings do as they change.
@Observable final class PluginRegistry {
    static let shared = PluginRegistry()

    struct Plugin: Identifiable {
        let url: URL
        let isBuiltIn: Bool
        var manifest: PluginManifest?
        /// Why it isn't running, when it isn't.
        var problem: String?
        var patterns: [PluginPattern] = []
        var brushes: [PluginBrush] = []
        var id: String { manifest?.id ?? url.path }
        var name: String { manifest?.name ?? url.deletingPathExtension().lastPathComponent }
    }

    private(set) var plugins: [Plugin] = []
    private(set) var disabled: Set<String>
    /// Each plugin brush's options as they're set, by brush.
    private(set) var values: [String: [String: PluginValue]] = [:]
    /// What each brush's script makes of those options, by brush.
    private(set) var behaviors: [String: PluginScriptRuntime.BrushBehavior] = [:]
    /// Why a brush's script couldn't say, by brush.
    private(set) var brushProblems: [String: String] = [:]
    let builtInFolder: URL?
    let userFolder: URL
    @ObservationIgnored private var runtimes: [String: PluginScriptRuntime] = [:]
    /// Plugins whose scripts stopped responding. Their queues are stuck, so they aren't tried again until the app is.
    @ObservationIgnored private var hung = Set<String>()
    @ObservationIgnored private var updates: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var fingerprint: [String] = []
    @ObservationIgnored private var hasLoaded = false

    init(builtIn: URL? = Bundle.main.resourceURL?.appendingPathComponent("Plugins"), user: URL = PluginRegistry.defaultUserFolder) {
        builtInFolder = builtIn
        userFolder = user
        disabled = Set(ToolDefaults.string("disabledPlugins", "").split(separator: "\n").map(String.init))
    }

    static var defaultUserFolder: URL {
        // Tests get a folder of their own, never the person's plugins.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("Compositor Test Plugins", isDirectory: true)
        }
        #if os(macOS)
        return URL.applicationSupportDirectory.appendingPathComponent("Compositor/Plugins", isDirectory: true)
        #else
        return URL.documentsDirectory.appendingPathComponent("Plugins", isDirectory: true)
        #endif
    }

    /// The plugins that are on and loaded.
    var running: [Plugin] { plugins.filter { $0.problem == nil && !disabled.contains($0.id) } }
    var brushes: [PluginBrush] { running.flatMap(\.brushes) }
    var patterns: [PluginPattern] { running.flatMap(\.patterns) }
    func brush(_ id: String?) -> PluginBrush? { id.flatMap { id in brushes.first { $0.id == id } } }

    // MARK: Loading

    /// Finds and loads every plugin again, from scratch, after any load already under way.
    func reload() async {
        let previous = loading
        let task = Task { await previous?.value; await load() }
        loading = task
        await task.value
        if loading == task { loading = nil }
    }

    /// Loads them again if the person's Plugins folder has changed: when the app comes back from the Finder or Files.
    /// One already loading does.
    func reloadIfChanged() async {
        if let loading { await loading.value; return }
        if !hasLoaded || currentFingerprint() != fingerprint { await reload() }
    }

    private func load() async {
        // Made up front on iPad, so the folder is there in Files to drop plugins into.
        try? FileManager.default.createDirectory(at: userFolder, withIntermediateDirectories: true)
        fingerprint = currentFingerprint()
        hasLoaded = true
        runtimes = [:]
        var found: [Plugin] = []
        var ids = Set<String>()
        for (folder, builtIn) in [(builtInFolder, true), (userFolder, false)] {
            guard let folder else { continue }
            for url in Self.packages(in: folder) {
                var plugin = Plugin(url: url, isBuiltIn: builtIn)
                do {
                    let manifest = try PluginManifest.load(from: url)
                    plugin.manifest = manifest
                    guard ids.insert(manifest.id).inserted else {
                        throw PluginError.invalid("Another plugin already has its id, “\(manifest.id)”.")
                    }
                    guard !hung.contains(manifest.id) else { throw PluginError.notResponding }
                    try await start(&plugin, manifest)
                } catch {
                    plugin.problem = error.localizedDescription
                    plugin.patterns = []
                    plugin.brushes = []
                }
                found.append(plugin)
            }
        }
        plugins = found
        for brush in brushes {
            values[brush.id] = storedValues(of: brush)
            await updateBehavior(of: brush)
        }
    }

    /// Reads a plugin's patterns and runs its script. Turned off, it's only checked.
    private func start(_ plugin: inout Plugin, _ manifest: PluginManifest) async throws {
        var patterns: [PluginPattern] = []
        for entry in manifest.contributes.patterns {
            let pattern = try entry.matrix.flatMap(DitherPattern.init(matrix:)) ?? Self.picture(entry, in: plugin.url)
            patterns.append(PluginPattern(id: "\(manifest.id)/\(entry.id)", name: entry.name, pattern: pattern))
        }
        var registered = Set<String>()
        if let main = manifest.main, !disabled.contains(manifest.id) {
            let url = try PluginManifest.resource(main, in: plugin.url)
            guard let script = try? String(contentsOf: url, encoding: .utf8) else { throw PluginError.invalid("“\(main)” isn’t UTF-8 text.") }
            let runtime = PluginScriptRuntime(pluginID: manifest.id)
            let registrations: PluginScriptRuntime.Registrations
            do { registrations = try await runtime.load(script: script, from: url) }
            catch PluginError.notResponding { hung.insert(manifest.id); throw PluginError.notResponding }
            for (id, name, matrix) in registrations.patterns {
                let qualified = "\(manifest.id)/\(id)"
                guard !patterns.contains(where: { $0.id == qualified }), let pattern = DitherPattern(matrix: matrix) else {
                    throw PluginError.invalid("Its script adds a pattern, “\(id)”, that plugin.json already has.")
                }
                patterns.append(PluginPattern(id: qualified, name: name, pattern: pattern))
            }
            registered = registrations.brushes
            runtimes[manifest.id] = runtime
        }
        if let stray = registered.first(where: { id in !manifest.contributes.brushes.contains { $0.id == id } }) {
            throw PluginError.invalid("Its script sets up a brush, “\(stray)”, that plugin.json doesn’t list.")
        }
        plugin.patterns = patterns
        plugin.brushes = manifest.contributes.brushes.map { brush in
            PluginBrush(id: "\(manifest.id)/\(brush.id)", pluginID: manifest.id, brushID: brush.id, name: brush.name,
                        symbol: brush.symbol ?? "paintbrush.pointed", options: brush.options)
        }
    }

    private static func picture(_ entry: PluginManifest.Pattern, in package: URL) throws -> DitherPattern {
        guard let path = entry.image else { throw PluginError.invalid("Pattern “\(entry.name)” needs a matrix or an image.") }
        let url = try PluginManifest.resource(path, in: package)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let pattern = DitherPattern(image: image) else {
            throw PluginError.invalid("Pattern “\(entry.name)” should be a picture up to \(DitherPattern.maxSide) × \(DitherPattern.maxSide) pixels.")
        }
        return pattern
    }

    /// The plugin folders in `folder`, by name.
    private static func packages(in folder: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: .skipsHiddenFiles)) ?? []
        return contents.filter { $0.pathExtension == PluginManifest.packageExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// What's in the person's folder, and when each plugin's files last changed.
    private func currentFingerprint() -> [String] {
        Self.packages(in: userFolder).map { url in
            let dates = [PluginManifest.fileName, "main.js"].map { name in
                ((try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent(name).path))?[.modificationDate] as? Date)?
                    .timeIntervalSinceReferenceDate ?? 0
            }
            return "\(url.lastPathComponent) \(dates)"
        }
    }

    // MARK: Turning plugins on and off, adding and removing them

    func isEnabled(_ plugin: Plugin) -> Bool { !disabled.contains(plugin.id) }

    func setEnabled(_ enabled: Bool, for plugin: Plugin) async {
        if enabled { disabled.remove(plugin.id) } else { disabled.insert(plugin.id) }
        ToolDefaults.set(disabled.sorted().joined(separator: "\n"), "disabledPlugins")
        await reload()
    }

    /// Copies the plugin at `source` into the person's Plugins folder, replacing any older copy, and loads it. Returns
    /// its name.
    @discardableResult
    func install(from source: URL) async throws -> String {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        guard source.pathExtension == PluginManifest.packageExtension else {
            throw PluginError.invalid("Choose a plugin: a folder whose name ends in .\(PluginManifest.packageExtension).")
        }
        let manifest = try PluginManifest.load(from: source)
        if plugins.contains(where: { $0.isBuiltIn && $0.manifest?.id == manifest.id }) {
            throw PluginError.invalid("“\(manifest.name)” is built into Compositor already.")
        }
        let manager = FileManager.default
        try manager.createDirectory(at: userFolder, withIntermediateDirectories: true)
        let destination = userFolder.appendingPathComponent(source.lastPathComponent, isDirectory: true)
        guard destination.standardizedFileURL != source.standardizedFileURL else { await reload(); return manifest.name }
        for plugin in plugins where !plugin.isBuiltIn && plugin.manifest?.id == manifest.id { try? manager.removeItem(at: plugin.url) }
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        try manager.copyItem(at: source, to: destination)
        await reload()
        return manifest.name
    }

    /// Moves an added plugin to the Trash, or deletes it where there's no Trash to move it to.
    func remove(_ plugin: Plugin) async throws {
        guard !plugin.isBuiltIn else { return }
        do { try FileManager.default.trashItem(at: plugin.url, resultingItemURL: nil) }
        catch { try FileManager.default.removeItem(at: plugin.url) }
        await reload()
    }

    // MARK: Brush settings

    func value(_ option: PluginOption, of brush: PluginBrush) -> PluginValue {
        values[brush.id]?[option.id] ?? qualified(option.initialValue, option, brush)
    }

    func setValue(_ value: PluginValue, for option: PluginOption, of brush: PluginBrush) {
        let fitted = qualified(option.fitted(value), option, brush)
        guard values[brush.id]?[option.id] != fitted else { return }
        values[brush.id, default: storedValues(of: brush)][option.id] = fitted
        let stored: Any = switch fitted {
        case .number(let number): number
        case .bool(let flag): flag
        case .string(let text): text
        }
        ToolDefaults.set(object: stored, "plugin.\(brush.id).\(option.id)")
        // A slider sends a stream of values: the script is asked about the last of them, once it stops for a moment.
        updates[brush.id]?.cancel()
        updates[brush.id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            await self?.updateBehavior(of: brush)
        }
    }

    /// Waits for the brushes' scripts to catch up with their settings.
    func settle() async {
        for update in updates.values { await update.value }
    }

    /// The ink `brush` paints with as it's set, or nil without a pattern to paint.
    func ink(for brush: PluginBrush) -> PatternInk? {
        let behavior = behaviors[brush.id] ?? PluginScriptRuntime.BrushBehavior()
        let chosen = behavior.pattern ?? brush.options.first { $0.kind == .pattern }.map { value($0, of: brush).string ?? "" }
        guard let pattern = pattern(chosen, for: brush) else { return nil }
        return PatternInk(pattern: pattern.pattern, colors: behavior.colors.flatMap(PatternInk.Colors.init) ?? .foreground,
                          dynamics: behavior.dynamics)
    }

    /// The pattern `id` names (its plugin's own, without the plugin's id in front), or the brush's plugin's first.
    func pattern(_ id: String?, for brush: PluginBrush) -> PluginPattern? {
        let qualified = id.map { $0.contains("/") ? $0 : "\(brush.pluginID)/\($0)" }
        return patterns.first { $0.id == qualified } ?? patterns.first { $0.id.hasPrefix(brush.pluginID + "/") } ?? patterns.first
    }

    private func updateBehavior(of brush: PluginBrush) async {
        guard let runtime = runtimes[brush.pluginID] else { behaviors[brush.id] = PluginScriptRuntime.BrushBehavior(); return }
        do {
            let behavior = try await runtime.behavior(of: brush.brushID, options: values[brush.id] ?? storedValues(of: brush))
            if behaviors[brush.id] != behavior { behaviors[brush.id] = behavior }
            brushProblems[brush.id] = nil
        } catch {
            brushProblems[brush.id] = error.localizedDescription
            if runtime.isHung, let index = plugins.firstIndex(where: { $0.id == brush.pluginID }) {
                hung.insert(brush.pluginID)
                plugins[index].problem = error.localizedDescription
            }
        }
    }

    private func storedValues(of brush: PluginBrush) -> [String: PluginValue] {
        Dictionary(uniqueKeysWithValues: brush.options.map { option in
            let stored = ToolDefaults.object("plugin.\(brush.id).\(option.id)")
            let value: PluginValue? = switch option.kind {
            case .slider: (stored as? Double).map(PluginValue.number)
            case .toggle: (stored as? Bool).map(PluginValue.bool)
            case .choice, .pattern: (stored as? String).map(PluginValue.string)
            }
            return (option.id, qualified(option.fitted(value), option, brush))
        })
    }

    /// A pattern option's value with its plugin's id in front, as plugin.json's defaults leave it off.
    private func qualified(_ value: PluginValue, _ option: PluginOption, _ brush: PluginBrush) -> PluginValue {
        guard option.kind == .pattern, case .string(let id) = value, !id.contains("/") else { return value }
        return .string("\(brush.pluginID)/\(id)")
    }
}
