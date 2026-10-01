import Foundation
import Testing
@testable import Compositor

/// Plugins: their manifests, their scripts, and the registry that loads them, turns them on and off, and asks their
/// brushes what their settings do.
@MainActor
struct PluginTests {
    /// A folder of its own holding one plugin, `Test.compositorplugin`, made of `manifest`, `script` and `files`.
    private func package(_ manifest: String, script: String? = nil, files: [String: Data] = [:]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PluginTests-\(UUID())", isDirectory: true)
        let url = folder.appendingPathComponent("Test.compositorplugin", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(manifest.utf8).write(to: url.appendingPathComponent("plugin.json"))
        if let script { try Data(script.utf8).write(to: url.appendingPathComponent("main.js")) }
        for (path, data) in files { try data.write(to: url.appendingPathComponent(path)) }
        return url
    }

    private func manifest(id: String = "com.example.test", api: Int = 1, main: Bool = false, patterns: String = "[]",
                          brushes: String = "[]") -> String {
        """
        { "id": "\(id)", "name": "Test", "version": "1.0", "apiVersion": \(api), \(main ? "\"main\": \"main.js\"," : "")
          "contributes": { "patterns": \(patterns), "brushes": \(brushes) } }
        """
    }

    private let brush = """
        [{ "id": "dots", "name": "Dots", "ink": "pattern", "options": [
            { "id": "pattern", "type": "pattern", "title": "Pattern", "default": "two" },
            { "id": "amount", "type": "slider", "title": "Amount", "min": 0, "max": 100, "default": 40 } ] }]
        """
    private let two = #"[{ "id": "two", "name": "Two", "matrix": [[0, 1]] }]"#

    /// A registry of the one plugin at `url`, loaded.
    private func registry(_ url: URL) async -> PluginRegistry {
        let registry = PluginRegistry(builtIn: nil, user: url.deletingLastPathComponent())
        await registry.reload()
        return registry
    }

    private func problem(_ manifest: String, script: String? = nil) async throws -> String? {
        await registry(try package(manifest, script: script)).plugins.first?.problem
    }

    // MARK: Manifests

    @Test func theBuiltInDitherBrushLoads() async throws {
        let registry = PluginRegistry(builtIn: Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
                                      user: FileManager.default.temporaryDirectory.appendingPathComponent("PluginTests-\(UUID())"))
        await registry.reload()
        let plugin = try #require(registry.plugins.first { $0.id == "com.compositor.dither-brush" })
        #expect(plugin.problem == nil)
        #expect(plugin.isBuiltIn)
        let ids = Set(plugin.patterns.map(\.id))
        for id in ["bayer2", "bayer4", "bayer8", "checker", "cross-hatch", "dots", "blue-noise"] {
            #expect(ids.contains("com.compositor.dither-brush/\(id)"), "\(id)")
        }
        // Built by the script as Aseprite builds them.
        let bayer8 = try #require(plugin.patterns.first { $0.id.hasSuffix("/bayer8") })
        #expect(bayer8.pattern == DitherPattern(matrix: DitherBrushTests.bayer(8)))
        let dither = try #require(registry.brush("com.compositor.dither-brush/dither"))
        #expect(dither.options.map(\.id) == ["pattern", "density", "fillGaps", "pressureDensity", "pressureSize", "lightest", "firmest"])
        // The picture's 256 pixels are 256 steps.
        let noise = try #require(plugin.patterns.first { $0.id.hasSuffix("/blue-noise") })
        #expect(Set(noise.pattern.thresholds).count == 256)
    }

    @Test func badManifestsAreTurnedAway() async throws {
        #expect(try await problem("{ \"name\": \"Test\" }")?.contains("“id” is missing") == true)
        #expect(try await problem(manifest(id: "has spaces"))?.contains("Its id") == true)
        #expect(try await problem(manifest(api: 2))?.contains("plugin API 2") == true)
        #expect(try await problem(manifest(main: true))?.contains("main.js") == true)
        #expect(try await problem(manifest(patterns: #"[{ "id": "up", "name": "Up", "image": "../../secret.png" }]"#))?
            .contains("isn’t inside the plugin") == true)
        let wide = "[[" + Array(repeating: "0", count: 65).joined(separator: ",") + "]]"
        #expect(try await problem(manifest(patterns: #"[{ "id": "wide", "name": "Wide", "matrix": \#(wide) }]"#)) != nil)
        #expect(try await problem(manifest(patterns: #"[{ "id": "a", "name": "A", "matrix": [[0]] }, { "id": "a", "name": "B", "matrix": [[0]] }]"#))?
            .contains("two of the pattern") == true)
        #expect(try await problem(manifest(brushes: #"[{ "id": "b", "name": "B", "ink": "sparkles" }]"#))?.contains("ink") == true)
        let choice = #"[{ "id": "b", "name": "B", "ink": "pattern", "options": [{ "id": "c", "type": "choice", "title": "C", "default": "z", "choices": [{ "id": "a", "title": "A" }] }] }]"#
        #expect(try await problem(manifest(brushes: choice))?.contains("isn’t one of its choices") == true)
        #expect(try await problem(manifest(patterns: two, brushes: brush)) == nil)
    }

    @Test func twoPluginsCantShareAnID() async throws {
        let first = try package(manifest())
        let second = first.deletingLastPathComponent().appendingPathComponent("Again.compositorplugin")
        try FileManager.default.copyItem(at: first, to: second)
        let registry = await registry(first)
        #expect(registry.plugins.count == 2)
        #expect(registry.plugins[1].problem?.contains("Another plugin") == true)
    }

    // MARK: Scripts

    @Test func aScriptAddsPatternsAndShapesItsBrush() async throws {
        let script = """
            compositor.registerPattern({ id: "three", name: "Three", matrix: [[2, 0, 1]] });
            compositor.registerBrush("dots", {
                ink(options) { return { pattern: "three", colors: "foregroundToBackground" }; },
                dab(input, options) { return { density: input.pressure * options.amount / 100, size: 0.5 }; },
            });
            """
        let registry = await registry(try package(manifest(main: true, patterns: two, brushes: brush), script: script))
        #expect(registry.plugins.first?.problem == nil)
        #expect(registry.patterns.map(\.name) == ["Two", "Three"])
        let dots = try #require(registry.brushes.first)
        let ink = try #require(registry.ink(for: dots))
        #expect(ink.pattern == DitherPattern(matrix: [[2, 0, 1]]))
        #expect(ink.colors == .foregroundToBackground)
        #expect(ink.dynamics.at(1).density == 0.4)
        #expect(abs(ink.dynamics.at(0.5).density - 0.2) < 0.002)
        #expect(ink.dynamics.at(0).density == 0)
        #expect(ink.dynamics.at(0.7).size == 0.5)
        // Its settings change what the script says.
        registry.setValue(.number(100), for: dots.options[1], of: dots)
        await registry.settle()
        #expect(registry.ink(for: dots)?.dynamics.at(1).density == 1)
        // Past its range, a value is brought back in.
        registry.setValue(.number(400), for: dots.options[1], of: dots)
        #expect(registry.value(dots.options[1], of: dots) == .number(100))
    }

    /// The Dither Brush's dynamics: pressure between Lightest and Firmest, as Aseprite's are.
    @Test func theDitherBrushFollowsPressureAsAsepriteDoes() async throws {
        let registry = PluginRegistry(builtIn: Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
                                      user: FileManager.default.temporaryDirectory.appendingPathComponent("PluginTests-\(UUID())"))
        await registry.reload()
        let dither = try #require(registry.brush("com.compositor.dither-brush/dither"))
        func option(_ id: String) throws -> PluginOption { try #require(dither.options.first { $0.id == id }) }
        var ink = try #require(registry.ink(for: dither))
        #expect(ink.pattern == DitherPattern(matrix: DitherBrushTests.bayer(4)))
        #expect(ink.colors == .foreground)
        #expect(ink.dynamics.at(1).density == 0.5)
        #expect(ink.dynamics.at(0).density == 0)
        #expect(abs(ink.dynamics.at(0.5).density - 0.25) < 0.002)
        #expect(ink.dynamics.at(0.5).size == 1)
        registry.setValue(.number(20), for: try option("lightest"), of: dither)
        registry.setValue(.number(80), for: try option("firmest"), of: dither)
        registry.setValue(.bool(true), for: try option("pressureSize"), of: dither)
        registry.setValue(.bool(true), for: try option("fillGaps"), of: dither)
        registry.setValue(.string("com.compositor.dither-brush/checker"), for: try option("pattern"), of: dither)
        await registry.settle()
        ink = try #require(registry.ink(for: dither))
        #expect(ink.dynamics.at(0.1).density == 0)
        #expect(ink.dynamics.at(0.9).density == 0.5)
        #expect(abs(ink.dynamics.at(0.5).density - 0.25) < 0.002)
        #expect(ink.dynamics.at(0.1).size == 0.02)
        #expect(ink.colors == .foregroundToBackground)
        #expect(ink.pattern == DitherPattern(matrix: [[0, 1], [1, 0]]))
        // Pressure doesn't have to count.
        registry.setValue(.bool(false), for: try option("pressureDensity"), of: dither)
        await registry.settle()
        #expect(registry.ink(for: dither)?.dynamics.at(0.1).density == 0.5)
    }

    @Test func aScriptThatThrowsSaysWhere() async throws {
        let message = try await problem(manifest(main: true), script: "let a = 1;\nthrow new Error(\"no brush today\");")
        #expect(message?.contains("line 2") == true)
        #expect(message?.contains("no brush today") == true)
        #expect(try await problem(manifest(main: true), script: #"compositor.registerPattern({ id: "bad", name: "Bad", matrix: [[0, -1]] });"#)?
            .contains("Pattern “Bad”") == true)
        #expect(try await problem(manifest(main: true), script: #"compositor.registerBrush("stray", { dab() { return {}; } });"#)?
            .contains("doesn’t list") == true)
    }

    /// One that runs on past its deadline is given up on, rather than waited for.
    @Test func aScriptThatRunsOnIsGivenUpOn() async throws {
        let message = try await problem(manifest(main: true), script: "const end = Date.now() + 1500; while (Date.now() < end) {}")
        #expect(message == PluginError.notResponding.errorDescription)
    }

    @Test func aScriptHasNoWayOut() async throws {
        let script = """
            const reachable = [typeof fetch, typeof XMLHttpRequest, typeof require, typeof process].filter(t => t !== "undefined");
            if (reachable.length) throw new Error("reached " + reachable.join());
            """
        #expect(try await problem(manifest(main: true), script: script) == nil)
    }

    // MARK: The registry

    /// Loads asked for while one is under way (the editor opening as the app becomes active) wait their turn rather
    /// than spinning on the main actor.
    @Test(.timeLimit(.minutes(1))) func overlappingReloadsAllFinish() async throws {
        let registry = PluginRegistry(builtIn: Bundle.main.resourceURL?.appendingPathComponent("Plugins"),
                                      user: FileManager.default.temporaryDirectory.appendingPathComponent("PluginTests-\(UUID())"))
        async let first: Void = registry.reload()
        async let second: Void = registry.reloadIfChanged()
        async let third: Void = registry.reload()
        _ = await (first, second, third)
        await registry.reloadIfChanged()
        #expect(registry.plugins.count == 1)
        #expect(registry.brushes.count == 1)
    }

    @Test func pluginsCanBeTurnedOffInstalledAndRemoved() async throws {
        let source = try package(manifest(patterns: two, brushes: brush))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PluginTests-\(UUID())", isDirectory: true)
        let registry = PluginRegistry(builtIn: nil, user: folder)
        await registry.reload()
        #expect(registry.plugins.isEmpty)
        #expect(try await registry.install(from: source) == "Test")
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Test.compositorplugin/plugin.json").path))
        let plugin = try #require(registry.plugins.first)
        #expect(registry.brushes.map(\.name) == ["Dots"])
        await registry.setEnabled(false, for: plugin)
        #expect(registry.brushes.isEmpty && registry.patterns.isEmpty)
        #expect(registry.plugins.count == 1)
        await registry.setEnabled(true, for: plugin)
        #expect(registry.brushes.count == 1)
        try await registry.remove(try #require(registry.plugins.first))
        #expect(registry.plugins.isEmpty)
        await #expect(throws: PluginError.self) { try await registry.install(from: folder) }
    }
}
