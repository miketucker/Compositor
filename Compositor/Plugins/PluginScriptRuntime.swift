import Foundation
import JavaScriptCore
import os

/// A plugin's script, run by JavaScriptCore on a queue of its own. A script reaches nothing but what this hands it:
/// `compositor.registerPattern` and `compositor.registerBrush` as it loads, and `console` for messages, which go to the
/// system log. It has no files, network or documents.
///
/// Scripts never run under the Pencil: a brush's is asked what it does at every pressure when its options change (see
/// `behavior(of:options:)`), and strokes look that up. Every call has a deadline. JavaScriptCore can't stop a script
/// that runs on, so one that misses it is given up on, with its queue, until the app is next opened.
nonisolated final class PluginScriptRuntime: @unchecked Sendable {
    /// What a script registered as it loaded.
    struct Registrations: Sendable {
        var patterns: [(id: String, name: String, matrix: [[Int]])] = []
        var brushes: Set<String> = []
    }

    /// What a brush's script makes of its options: its density and size at each pressure, and the pattern and colors it
    /// paints in, where it names them.
    struct BrushBehavior: Sendable, Equatable {
        var dynamics = BrushDynamicsTable(density: 1)
        var pattern: String?
        var colors: String?
    }

    static let loadLimit: TimeInterval = 1
    static let callLimit: TimeInterval = 0.25
    static let maxPatterns = 64

    private let queue: DispatchQueue
    private let log: Logger
    /// Set once a call runs past its deadline. The queue is stuck behind it, so nothing more is sent.
    private let hung = OSAllocatedUnfairLock(initialState: false)
    // Touched only on `queue`.
    private var context: JSContext?
    private var brushes: [String: JSValue] = [:]
    private var registrations = Registrations()
    private var exception: String?

    var isHung: Bool { hung.withLock { $0 } }

    init(pluginID: String) {
        queue = DispatchQueue(label: "com.compositor.plugin.\(pluginID)", qos: .userInitiated)
        log = Logger(subsystem: "com.compositor", category: "Plugin \(pluginID)")
    }

    /// Runs the plugin's script, from `url`, and gathers what it registered.
    func load(script: String, from url: URL) async throws -> Registrations {
        try await run(limit: Self.loadLimit) { [self] in
            guard let context = JSContext() else { throw PluginError.script("Its script couldn’t be started.") }
            context.name = url.lastPathComponent
            context.exceptionHandler = { [weak self] _, value in self?.exception = Self.describe(value) }
            self.context = context
            context.setObject(compositorObject(in: context), forKeyedSubscript: "compositor" as NSString)
            context.setObject(consoleObject(in: context), forKeyedSubscript: "console" as NSString)
            exception = nil
            context.evaluateScript(script, withSourceURL: url)
            if let exception { throw PluginError.script(exception) }
            return registrations
        }
    }

    /// Asks `brush`'s script what it does with `options` set: once for its pattern and colors, and at 256 pressures,
    /// from the lightest to the firmest, for its density and size. A script without a `dab` paints in full.
    func behavior(of brush: String, options: [String: PluginValue]) async throws -> BrushBehavior {
        try await run(limit: Self.callLimit) { [self] in
            guard let context, let object = brushes[brush] else { return BrushBehavior() }
            let settings = JSValue(newObjectIn: context)!
            for (key, value) in options {
                let converted: JSValue = switch value {
                case .number(let number): JSValue(double: number, in: context)
                case .bool(let flag): JSValue(bool: flag, in: context)
                case .string(let text): JSValue(object: text, in: context)
                }
                settings.setValue(converted, forProperty: key)
            }
            var behavior = BrushBehavior()
            exception = nil
            if object.hasProperty("ink") {
                let ink = object.invokeMethod("ink", withArguments: [settings])
                if let exception { throw PluginError.script(exception) }
                if let ink, ink.isObject {
                    behavior.pattern = ink.forProperty("pattern").flatMap { $0.isString ? $0.toString() : nil }
                    behavior.colors = ink.forProperty("colors").flatMap { $0.isString ? $0.toString() : nil }
                }
            }
            guard object.hasProperty("dab") else { return behavior }
            var density = [Float](), size = [Float]()
            density.reserveCapacity(BrushDynamicsTable.steps)
            size.reserveCapacity(BrushDynamicsTable.steps)
            let input = JSValue(newObjectIn: context)!
            for step in 0..<BrushDynamicsTable.steps {
                input.setValue(Double(step) / Double(BrushDynamicsTable.steps - 1), forProperty: "pressure")
                let dab = object.invokeMethod("dab", withArguments: [input, settings])
                if let exception { throw PluginError.script(exception) }
                // Whatever it leaves out is full.
                func number(_ key: String) -> Float {
                    guard let value = dab?.forProperty(key), value.isNumber else { return 1 }
                    return Float(value.toDouble())
                }
                density.append(number("density"))
                size.append(number("size"))
            }
            behavior.dynamics = BrushDynamicsTable(density: density, size: size)
            return behavior
        }
    }

    /// `work` on the script's queue, given up on after `limit` seconds.
    private func run<T: Sendable>(limit: TimeInterval, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        guard !isHung else { throw PluginError.notResponding }
        let waiting = OSAllocatedUnfairLock<CheckedContinuation<T, Error>?>(initialState: nil)
        @Sendable func take() -> CheckedContinuation<T, Error>? { waiting.withLock { continuation in defer { continuation = nil }; return continuation } }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.withLock { $0 = continuation }
            queue.async { let result = Result { try work() }; take()?.resume(with: result) }
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) { [hung] in
                guard let continuation = take() else { return }
                hung.withLock { $0 = true }
                continuation.resume(throwing: PluginError.notResponding)
            }
        }
    }

    private func compositorObject(in context: JSContext) -> JSValue {
        let compositor = JSValue(newObjectIn: context)!
        let registerPattern: @convention(block) (JSValue) -> Void = { [weak self] value in
            guard let self else { return }
            let id = value.forProperty("id")?.toString() ?? "", name = value.forProperty("name")?.toString() ?? ""
            let raw = value.forProperty("matrix")?.toArray() as? [[Any]]
            // Whole numbers only: anything else in a row leaves it short.
            let rows = raw?.map { $0.compactMap { ($0 as? NSNumber).flatMap { $0.doubleValue.rounded() == $0.doubleValue ? $0.intValue : nil } } }
            guard PluginManifest.isIdentifier(id), !name.isEmpty, name.count <= 60 else {
                return Self.raise("registerPattern needs an id (letters, digits and dashes) and a name.", in: context)
            }
            guard let raw, let rows, zip(raw, rows).allSatisfy({ $0.count == $1.count }), DitherPattern(matrix: rows) != nil else {
                return Self.raise("Pattern “\(name)” should be 1–\(DitherPattern.maxSide) equal rows of 1–\(DitherPattern.maxSide) whole numbers, none negative.", in: context)
            }
            guard registrations.patterns.count < Self.maxPatterns else { return Self.raise("A plugin can add up to \(Self.maxPatterns) patterns.", in: context) }
            registrations.patterns.removeAll { $0.id == id }
            registrations.patterns.append((id, name, rows))
        }
        let registerBrush: @convention(block) (JSValue, JSValue) -> Void = { [weak self] id, behavior in
            guard let self else { return }
            guard id.isString, let brush = id.toString(), PluginManifest.isIdentifier(brush), behavior.isObject else {
                return Self.raise("registerBrush needs the brush’s id, as plugin.json names it, and an object with its dab and ink.", in: context)
            }
            brushes[brush] = behavior
            registrations.brushes.insert(brush)
        }
        compositor.setObject(registerPattern, forKeyedSubscript: "registerPattern" as NSString)
        compositor.setObject(registerBrush, forKeyedSubscript: "registerBrush" as NSString)
        compositor.setObject(PluginManifest.apiVersion, forKeyedSubscript: "apiVersion" as NSString)
        return compositor
    }

    private func consoleObject(in context: JSContext) -> JSValue {
        let console = JSValue(newObjectIn: context)!
        for level in ["log", "info", "warn", "error"] {
            let write: @convention(block) () -> Void = { [log] in
                let message = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }.joined(separator: " ")
                if level == "warn" || level == "error" { log.error("\(message, privacy: .public)") }
                else { log.info("\(message, privacy: .public)") }
            }
            console.setObject(write, forKeyedSubscript: level as NSString)
        }
        return console
    }

    private static func raise(_ message: String, in context: JSContext) {
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    /// A thrown value as a sentence, with where it was thrown.
    private static func describe(_ value: JSValue?) -> String {
        guard let value else { return "Its script failed." }
        let message = value.forProperty("message").flatMap { $0.isUndefined ? nil : $0.toString() } ?? value.toString() ?? "an error"
        if let line = value.forProperty("line"), line.isNumber { return "Its script stopped at line \(line.toInt32()): \(message)" }
        return "Its script stopped: \(message)"
    }
}
