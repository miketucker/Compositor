import Foundation

/// Toggles that belong to the person rather than to a document: Auto Select, the transform box,
/// rulers, guides, the grid (and its spacing and look) and the snapping switches. They keep whatever they were last set to,
/// across tabs and across launches, the way Photoshop's tool options do.
///
/// Tests get the compiled defaults instead, so one test flipping a switch can't reach another —
/// or the app the person is actually using.
nonisolated enum ToolDefaults {
    private static let prefix = "tool."
    private static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static func bool(_ key: String, _ fallback: Bool) -> Bool {
        guard !isTesting else { return fallback }
        return UserDefaults.standard.object(forKey: prefix + key) as? Bool ?? fallback
    }

    static func set(_ value: Bool, _ key: String) {
        guard !isTesting else { return }
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    static func int(_ key: String, _ fallback: Int) -> Int {
        guard !isTesting else { return fallback }
        return UserDefaults.standard.object(forKey: prefix + key) as? Int ?? fallback
    }

    static func set(_ value: Int, _ key: String) {
        guard !isTesting else { return }
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    static func string(_ key: String, _ fallback: String) -> String {
        guard !isTesting else { return fallback }
        return UserDefaults.standard.string(forKey: prefix + key) ?? fallback
    }

    static func set(_ value: String, _ key: String) {
        guard !isTesting else { return }
        UserDefaults.standard.set(value, forKey: prefix + key)
    }

    /// Whatever's kept under `key` (a number, switch or string), for values whose kind the caller knows, such as a
    /// plugin brush's options. Nil puts the default back.
    static func object(_ key: String) -> Any? {
        guard !isTesting else { return nil }
        return UserDefaults.standard.object(forKey: prefix + key)
    }

    static func set(object value: Any?, _ key: String) {
        guard !isTesting else { return }
        UserDefaults.standard.set(value, forKey: prefix + key)
    }
}
