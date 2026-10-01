import Foundation

/// A plugin's `plugin.json`: who it is, the script that runs it, and what it adds to the app.
///
/// A plugin is a folder named `Something.compositorplugin` holding this file, an optional script and anything they
/// refer to. In version 1 a plugin can add dither patterns and brushes that paint in them; see
/// `Plugins/Dither Brush.compositorplugin` for one that does both.
nonisolated struct PluginManifest: Decodable, Sendable {
    /// The plugin API this app provides. A plugin made for another can't be loaded.
    static let apiVersion = 1
    static let fileName = "plugin.json"
    static let packageExtension = "compositorplugin"

    let id: String
    let name: String
    let version: String
    let apiVersion: Int
    var author: String?
    var description: String?
    /// A JavaScript file in the package, run once as the plugin loads.
    var main: String?
    var contributes = Contributions()

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        apiVersion = try container.decode(Int.self, forKey: .apiVersion)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        main = try container.decodeIfPresent(String.self, forKey: .main)
        contributes = try container.decodeIfPresent(Contributions.self, forKey: .contributes) ?? Contributions()
    }
    private enum CodingKeys: String, CodingKey { case id, name, version, apiVersion, author, description, main, contributes }

    nonisolated struct Contributions: Decodable, Sendable {
        var patterns: [Pattern] = []
        var brushes: [Brush] = []

        init() {}
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            patterns = try container.decodeIfPresent([Pattern].self, forKey: .patterns) ?? []
            brushes = try container.decodeIfPresent([Brush].self, forKey: .brushes) ?? []
        }
        private enum CodingKeys: String, CodingKey { case patterns, brushes }
    }

    /// A dither pattern drawn as a matrix (rows of whole numbers, the lower turning on first, as Aseprite's are) or as
    /// a grayscale picture in the package (brighter turning on first).
    nonisolated struct Pattern: Decodable, Sendable {
        let id: String
        let name: String
        var matrix: [[Int]]?
        var image: String?
    }

    nonisolated struct Brush: Decodable, Sendable {
        let id: String
        let name: String
        /// An SF Symbol for the brush menu and the tool rail.
        var symbol: String?
        /// How it paints: "pattern", a dither pattern, is the only ink there is so far.
        let ink: String
        var options: [PluginOption] = []

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
            ink = try container.decode(String.self, forKey: .ink)
            options = try container.decodeIfPresent([PluginOption].self, forKey: .options) ?? []
        }
        private enum CodingKeys: String, CodingKey { case id, name, symbol, ink, options }
    }

    /// Reads and checks the manifest of the plugin at `package`.
    static func load(from package: URL) throws -> PluginManifest {
        let data: Data
        do { data = try Data(contentsOf: package.appendingPathComponent(fileName)) }
        catch { throw PluginError.invalid("It has no \(fileName).") }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: data) }
        catch { throw PluginError.invalid("Its \(fileName) couldn’t be read: \(PluginError.describe(error))") }
        try manifest.validate(in: package)
        return manifest
    }

    func validate(in package: URL) throws {
        guard Self.isIdentifier(id, allowingDots: true) else {
            throw PluginError.invalid("Its id, “\(id)”, should be letters, digits, dots and dashes, like com.example.my-plugin.")
        }
        guard apiVersion == Self.apiVersion else {
            throw PluginError.invalid("It’s made for plugin API \(apiVersion); this version of Compositor runs API \(Self.apiVersion).")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 60 else {
            throw PluginError.invalid("Its name should be 1–60 characters.")
        }
        if let main { _ = try Self.resource(main, in: package) }
        guard contributes.patterns.count <= 64, contributes.brushes.count <= 16 else {
            throw PluginError.invalid("It adds more than 64 patterns or 16 brushes.")
        }
        try Self.checkUnique(contributes.patterns.map(\.id), "pattern")
        for pattern in contributes.patterns {
            try Self.checkName(pattern.id, pattern.name, "pattern")
            switch (pattern.matrix, pattern.image) {
            case (let matrix?, nil):
                guard DitherPattern(matrix: matrix) != nil else {
                    throw PluginError.invalid("Pattern “\(pattern.name)” should be 1–\(DitherPattern.maxSide) equal rows of 1–\(DitherPattern.maxSide) whole numbers, none negative.")
                }
            case (nil, let image?): _ = try Self.resource(image, in: package)
            default: throw PluginError.invalid("Pattern “\(pattern.name)” needs a matrix or an image, not both.")
            }
        }
        try Self.checkUnique(contributes.brushes.map(\.id), "brush")
        for brush in contributes.brushes {
            try Self.checkName(brush.id, brush.name, "brush")
            guard brush.ink == "pattern" else { throw PluginError.invalid("Brush “\(brush.name)” has an ink, “\(brush.ink)”, this version doesn’t know.") }
            guard brush.options.count <= 24 else { throw PluginError.invalid("Brush “\(brush.name)” has more than 24 options.") }
            try Self.checkUnique(brush.options.map(\.id), "option")
            for option in brush.options { try option.validate(in: brush.name) }
        }
    }

    /// The file at `path` inside the package. Nothing outside it can be reached, through `..` or a link.
    static func resource(_ path: String, in package: URL) throws -> URL {
        let root = package.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard !path.hasPrefix("/"), url.path.hasPrefix(root.path + "/") else {
            throw PluginError.invalid("“\(path)” isn’t inside the plugin.")
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw PluginError.invalid("It has no “\(path)”.") }
        return url
    }

    static func isIdentifier(_ text: String, allowingDots: Bool = false) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: allowingDots ? "-_." : "-_"))
        return (1...100).contains(text.count) && text.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    private static func checkName(_ id: String, _ name: String, _ kind: String) throws {
        guard isIdentifier(id) else { throw PluginError.invalid("A \(kind)’s id, “\(id)”, should be letters, digits and dashes.") }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, name.count <= 60 else {
            throw PluginError.invalid("The \(kind) “\(id)” needs a name of 1–60 characters.")
        }
    }

    private static func checkUnique(_ ids: [String], _ kind: String) throws {
        if let repeated = Dictionary(grouping: ids, by: { $0 }).first(where: { $0.value.count > 1 })?.key {
            throw PluginError.invalid("It has two of the \(kind) “\(repeated)”.")
        }
    }
}

/// One of a plugin brush's options, which the tool bar shows as a control: a slider, a switch, a menu of choices, or a
/// menu of dither patterns (from any plugin).
nonisolated struct PluginOption: Decodable, Sendable, Hashable {
    enum Kind: String, Decodable, Sendable { case slider, toggle, choice, pattern }
    nonisolated struct Choice: Decodable, Sendable, Hashable {
        let id: String
        let title: String
    }
    let id: String
    let kind: Kind
    let title: String
    var help: String?
    /// A slider's range and unit, such as "%" or "px".
    var min: Double?
    var max: Double?
    var unit: String?
    var choices: [Choice] = []
    var defaultValue: PluginValue?
    /// Shown in Full Screen Canvas's compact bar too, for what's reached for mid-drawing.
    var compact = false
    /// About the Pencil's pressure: grouped with the brush's other pressure settings.
    var pressure = false

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .type)
        title = try container.decode(String.self, forKey: .title)
        help = try container.decodeIfPresent(String.self, forKey: .help)
        min = try container.decodeIfPresent(Double.self, forKey: .min)
        max = try container.decodeIfPresent(Double.self, forKey: .max)
        unit = try container.decodeIfPresent(String.self, forKey: .unit)
        choices = try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        defaultValue = try container.decodeIfPresent(PluginValue.self, forKey: .default)
        compact = try container.decodeIfPresent(Bool.self, forKey: .compact) ?? false
        pressure = try container.decodeIfPresent(Bool.self, forKey: .pressure) ?? false
    }
    private enum CodingKeys: String, CodingKey { case id, type, title, help, min, max, unit, choices, `default`, compact, pressure }

    var range: ClosedRange<Double> { (min ?? 0)...Swift.max(min ?? 0, max ?? 100) }

    /// What it starts as: the manifest's default, or the least it can be.
    var initialValue: PluginValue {
        if let defaultValue { return defaultValue }
        switch kind {
        case .slider: return .number(range.lowerBound)
        case .toggle: return .bool(false)
        case .choice: return .string(choices.first?.id ?? "")
        case .pattern: return .string("")
        }
    }

    /// `value` made fit for the option, or its initial value where it can't be.
    func fitted(_ value: PluginValue?) -> PluginValue {
        switch (kind, value) {
        case (.slider, .number(let number)?) where number.isFinite: return .number(Swift.min(range.upperBound, Swift.max(range.lowerBound, number)))
        case (.toggle, .bool?): return value!
        case (.choice, .string(let id)?) where choices.contains(where: { $0.id == id }): return value!
        case (.pattern, .string?): return value!
        default: return initialValue
        }
    }

    func validate(in brush: String) throws {
        guard PluginManifest.isIdentifier(id), !title.isEmpty, title.count <= 40 else {
            throw PluginError.invalid("Brush “\(brush)” has an option without a proper id and a title of up to 40 characters.")
        }
        switch kind {
        case .slider:
            guard let min, let max, min.isFinite, max.isFinite, min < max else {
                throw PluginError.invalid("“\(title)” in “\(brush)” needs a min below its max.")
            }
            if let defaultValue, case .number = defaultValue {} else if defaultValue != nil {
                throw PluginError.invalid("“\(title)” in “\(brush)” should default to a number.")
            }
        case .toggle:
            if let defaultValue, case .bool = defaultValue {} else if defaultValue != nil {
                throw PluginError.invalid("“\(title)” in “\(brush)” should default to true or false.")
            }
        case .choice:
            guard !choices.isEmpty, choices.count <= 16, Set(choices.map(\.id)).count == choices.count else {
                throw PluginError.invalid("“\(title)” in “\(brush)” needs 1–16 choices, each with its own id.")
            }
            if let defaultValue, !choices.contains(where: { .string($0.id) == defaultValue }) {
                throw PluginError.invalid("“\(title)” in “\(brush)” defaults to something that isn’t one of its choices.")
            }
        case .pattern:
            if let defaultValue, case .string = defaultValue {} else if defaultValue != nil {
                throw PluginError.invalid("“\(title)” in “\(brush)” should default to a pattern’s id.")
            }
        }
    }
}

/// An option's value, as the manifest, the script and the app's settings hold it.
nonisolated enum PluginValue: Codable, Sendable, Hashable {
    case number(Double)
    case bool(Bool)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
}

nonisolated enum PluginError: LocalizedError, Equatable {
    /// The package itself is wrong: its manifest, or a file it names.
    case invalid(String)
    /// Its script threw, or handed back something that isn't what was asked for.
    case script(String)
    /// Its script took too long and was given up on.
    case notResponding

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        case .script(let reason): reason
        case .notResponding: "Its script stopped responding. Quit and reopen Compositor to try it again."
        }
    }

    static func describe(_ error: Error) -> String {
        if case DecodingError.keyNotFound(let key, _) = error { return "“\(key.stringValue)” is missing." }
        if case DecodingError.typeMismatch(_, let context) = error { return "“\(context.codingPath.last?.stringValue ?? "?")” has the wrong kind of value." }
        if case DecodingError.dataCorrupted = error { return "it isn’t valid JSON." }
        return error.localizedDescription
    }
}
