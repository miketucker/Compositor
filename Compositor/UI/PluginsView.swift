import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Plugins…: the plugins Compositor has, built in and added, what each adds, and a switch to turn it off.
final class PluginsPanel {
    static let shared = PluginsPanel()
    private let panel = FloatingPanelController(name: "plugins")
    private init() {}

    func show() { panel.show(title: "Plugins", content: PluginsView(close: { [weak self] in self?.panel.close() })) }
}

struct PluginsView: View {
    let close: () -> Void
    private var registry: PluginRegistry { .shared }
    @State private var importing = false
    @State private var message: String?
    @State private var removing: PluginRegistry.Plugin?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plugins add brushes and dither patterns to the Brush tool.")
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(registry.plugins) { plugin in
                        row(plugin).padding(.vertical, 10)
                        Divider()
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(height: 340)
            Text(folderHint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message {
                Text(message).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Install Plugin…") { importing = true }
                    .accessibilityIdentifier("installPlugin")
                #if os(macOS)
                Button("Show Plugins Folder") {
                    try? FileManager.default.createDirectory(at: registry.userFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(registry.userFolder)
                }
                #endif
                Button("Reload") { message = nil; Task { await registry.reload() } }
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 560)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.compositorPlugin, .folder]) { result in
            guard case .success(let url) = result else { return }
            Task {
                do { message = "Installed “\(try await registry.install(from: url))”." }
                catch { message = "That plugin couldn’t be installed. \(error.localizedDescription)" }
            }
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let plugin = removing else { return }
                Task {
                    do { try await registry.remove(plugin) }
                    catch { message = "“\(plugin.name)” couldn’t be removed. \(error.localizedDescription)" }
                }
            }
        } message: {
            Text("Its folder is moved to the Trash.")
        }
    }

    private var folderHint: String {
        #if os(macOS)
        "Install a plugin, or put its .compositorplugin folder in the Plugins folder and choose Reload."
        #else
        "Install a plugin, or put its .compositorplugin folder in Files, in On My iPad › Compositor › Plugins."
        #endif
    }

    private func row(_ plugin: PluginRegistry.Plugin) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 20)).foregroundStyle(plugin.problem == nil ? Color.accentColor : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(plugin.name).font(.headline)
                    if let version = plugin.manifest?.version { Text(version).foregroundStyle(.secondary) }
                    if plugin.isBuiltIn {
                        Text("Built In").font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                    }
                }
                if let author = plugin.manifest?.author { Text("By \(author)").font(.callout).foregroundStyle(.secondary) }
                if let description = plugin.manifest?.description {
                    Text(description).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let problem = plugin.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if registry.isEnabled(plugin), let added = contributions(plugin) {
                    Text(added).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !plugin.isBuiltIn {
                Button { removing = plugin } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Remove")
                    .accessibilityLabel("Remove \(plugin.name)")
            }
            if plugin.manifest != nil {
                Toggle(isOn: Binding(get: { registry.isEnabled(plugin) }, set: { on in Task { await registry.setEnabled(on, for: plugin) } })) {
                    Text(plugin.name)
                }
                .labelsHidden()
                #if os(macOS)
                .toggleStyle(.switch).controlSize(.small)
                #endif
            }
        }
    }

    /// What a plugin adds, in a line: “Adds the Dither brush and 10 patterns.”
    private func contributions(_ plugin: PluginRegistry.Plugin) -> String? {
        var parts: [String] = []
        switch plugin.brushes.count {
        case 0: break
        case 1: parts.append("the \(plugin.brushes[0].name) brush")
        default: parts.append("\(plugin.brushes.count) brushes")
        }
        switch plugin.patterns.count {
        case 0: break
        case 1: parts.append("a pattern")
        default: parts.append("\(plugin.patterns.count) patterns")
        }
        return parts.isEmpty ? nil : "Adds " + parts.joined(separator: " and ") + "."
    }
}
