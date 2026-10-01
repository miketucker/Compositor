import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Layers panel's list on iPad: tap a row to select its layer (with Shift or Command held, to add it or take it
/// out), its thumbnails to choose the pixels or the mask, and its eye to show or hide it; double-tap the name to rename
/// it, and touch and hold for the rest. Drag a row to reorder it, or onto a folder to put it inside; with Option held
/// the drag copies it. Rows are the same as the Mac's (see NativeLayerList there), from the session's `layerRows`.
struct NativeLayerList: View {
    let session: EditorSession

    var body: some View {
        let entries = session.layerRows
        let byID = Dictionary(uniqueKeysWithValues: (session.document?.layers ?? []).map { ($0.id, $0) })
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(entries.enumerated()), id: \.element.layer.id) { index, entry in
                        if let layer = byID[entry.layer.id] {
                            LayerRow(session: session, layer: layer, depth: entry.depth, visible: entry.visible, index: index)
                                .id(layer.id)
                        }
                    }
                    // Dropping below the last row puts the layer at the very bottom.
                    Color.clear.frame(height: 44)
                        .dropDestination(for: LayerRowItem.self) { items, _ in
                            LayerRowDrop(session: session).place(items.map(\.id), at: entries.count, intoFolder: false)
                        }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: session.renamingLayerID) { _, id in
                if let id { withAnimation { scroll.scrollTo(id) } }
            }
        }
        .accessibilityIdentifier("layersList")
    }
}

/// A layer being dragged within the list, or to another project's tab: its id, as the Mac's list writes it. Dragged
/// out of the app (into Files, Photos or another app beside it), it's the layer's own pixels, as a PNG named after it.
struct LayerRowItem: Transferable {
    let id: UUID
    var image: CGImage?
    var name = "Layer"
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(contentType: UTType(exportedAs: ProjectWorkspace.layerType)) { item in
            Data(item.id.uuidString.utf8)
        } importing: { data in
            guard let id = UUID(uuidString: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            else { throw CocoaError(.coderReadCorrupt) }
            return LayerRowItem(id: id)
        }
        DataRepresentation(exportedContentType: .png) { item in
            guard let image = item.image, let png = Clipboard.pngData(image) else { throw CocoaError(.fileWriteUnknown) }
            return png
        }
        .exportingCondition { $0.image != nil }
        .suggestedFileName { $0.name }
    }
}

/// Where dropped rows go, worked out as the Mac's list does (see `place` there).
@MainActor private struct LayerRowDrop {
    let session: EditorSession

    @discardableResult
    func place(_ dropped: [UUID], at row: Int, intoFolder: Bool) -> Bool {
        guard session.canEditLayers else { return false }
        let current = session.layerRows
        // Anything inside a dropped folder comes with the folder.
        let dragged = Set(dropped)
        let carried = dragged.reduce(into: Set<UUID>()) { $0.formUnion(session.descendantIDs(of: $1)) }
        let ids = current.map(\.layer.id).filter { dragged.contains($0) && !carried.contains($0) }
        guard !ids.isEmpty else { return false }
        let copying = KeyModifiers.current.contains(.option)
        let parent: UUID?, above: UUID?, atBottom: Bool
        if intoFolder, current.indices.contains(row) {
            parent = current[row].layer.id; above = nil; atBottom = false
        } else if row >= current.count {
            parent = nil; above = nil; atBottom = true
        } else {
            let target = current[row].layer
            parent = target.parentID; above = target.id; atBottom = false
        }
        guard ids.allSatisfy({ session.canPlaceLayer($0, in: parent) }), !(above.map(dragged.contains) ?? false) else { return false }
        let order = intoFolder ? Array(ids.reversed()) : ids
        session.beginEdit(copying ? (ids.count > 1 ? "Duplicate Layers" : "Duplicate Layer")
                                  : (ids.count > 1 ? "Move Layers" : "Move Layer"))
        var placed = false
        for id in order {
            let done = copying ? session.duplicateLayer(id, in: parent, above: above, atBottom: atBottom)
                               : session.placeLayer(id, in: parent, above: above, atBottom: atBottom)
            placed = done || placed
        }
        if placed, !copying { session.selectLayers(Set(ids), primary: ids.first) }
        session.endEdit()
        return placed
    }
}

private struct LayerRow: View {
    let session: EditorSession
    let layer: ImageLayer
    let depth: Int
    let visible: Bool
    let index: Int
    @State private var draftName = ""
    @State private var dropTarget: DropSpot?
    @FocusState private var nameFocused: Bool

    private enum DropSpot { case above, into }

    private var enabled: Bool { session.canEditLayers }
    private var selected: Bool { session.selectedEffect == nil && session.selectedLayerIDs.contains(layer.id) }
    private var targetsMask: Bool { selected && session.activeLayerID == layer.id && session.isMaskSelected }
    private var canvas: CGSize { session.document?.size ?? CGSize(width: 1, height: 1) }
    /// A folder steps its contents in by the same distance a clipping mask does; the two add up.
    private var indent: CGFloat { CGFloat(min(depth, 8)) * 20 + (layer.maskSourceID == nil ? 0 : 20) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { session.toggleLayerVisibility(layer.id) } label: {
                    Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointerHighlight().foregroundStyle(visible ? .primary : .tertiary).disabled(!enabled)
                .accessibilityLabel("\(layer.isVisible ? "Hide" : "Show") \(layer.name)")
                HStack(spacing: 6) {
                    Color.clear.frame(width: indent, height: 1)
                    if layer.isGroup {
                        Button { session.toggleGroupExpansion(layer.id) } label: {
                            Image(systemName: session.collapsedGroupIDs.contains(layer.id) ? "chevron.right" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).pointerHighlight().accessibilityLabel("Expand or collapse folder")
                    }
                    thumbnail
                    if let mask = layer.mask { maskThumbnail(mask) }
                    nameColumn
                    Spacer(minLength: 0)
                }
            }
            .padding(.trailing, 8)
            .frame(minHeight: 52)
            .background(selected ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: dropTarget == .above ? .top : .center) {
                if dropTarget == .above {
                    Rectangle().fill(Color.accentColor).frame(height: 2).offset(y: -2)
                } else if dropTarget == .into {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { rename() }
            .onTapGesture { select() }
            .contextMenu { menu }
            .draggable(LayerRowItem(id: layer.id, image: layer.asset?.image, name: layer.name)) {
                Text(layer.name).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .dropDestination(for: LayerRowItem.self) { items, location in
                let into = layer.isGroup && location.y > 14
                dropTarget = nil
                return LayerRowDrop(session: session).place(items.map(\.id), at: index, intoFolder: into)
            } isTargeted: { targeted in
                dropTarget = targeted ? (layer.isGroup ? .into : .above) : nil
            }
            ForEach(layer.effects?.kinds ?? [], id: \.self) { kind in effectRow(kind) }
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(layer.name)
    }

    @ViewBuilder private var thumbnail: some View {
        let editableText = layer.liveText != nil
        Group {
            if let adjustment = layer.adjustment {
                icon(adjustment.kind.symbol).rotationEffect(.degrees(adjustment.kind == .curves ? 90 : 0))
            } else if layer.isGroup {
                icon("folder")
            } else if editableText {
                icon("textformat")
            } else {
                Image(uiImage: LayerThumbnails.shared.layer(layer, canvas: canvas))
                    .resizable().interpolation(.medium)
                    .frame(width: CanvasThumbnail.fittedSize(canvas: canvas, box: 36).width,
                           height: CanvasThumbnail.fittedSize(canvas: canvas, box: 36).height)
            }
        }
        .overlay {
            if selected, !targetsMask, layer.mask != nil {
                RoundedRectangle(cornerRadius: 3).strokeBorder(.white, lineWidth: 1.5)
            }
        }
        .onTapGesture(count: 2) {
            session.activeLayerID = layer.id
            if editableText { session.editActiveText() }
            else if layer.adjustment?.kind.isEditable == true { session.adjustmentEditingID = layer.id }
            else { rename() }
        }
        .onTapGesture {
            session.commitTransform()
            session.selectLayerTarget(layer.id, mask: false)
        }
        .accessibilityLabel("Select \(editableText ? "text" : "image"): \(layer.name)")
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 17))
            .frame(width: 36, height: 36)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
    }

    private func maskThumbnail(_ mask: LayerMask) -> some View {
        let size = CanvasThumbnail.fittedSize(canvas: canvas, box: 30)
        return Image(uiImage: LayerThumbnails.shared.mask(layer, canvas: canvas))
            .resizable().interpolation(.medium)
            .frame(width: size.width, height: size.height)
            .overlay {
                if targetsMask { RoundedRectangle(cornerRadius: 2).strokeBorder(.white, lineWidth: 1.5) }
            }
            .overlay {
                // A disabled mask is crossed through, as Photoshop marks it.
                if !mask.isEnabled {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: 0)); path.addLine(to: CGPoint(x: size.width, y: size.height))
                        path.move(to: CGPoint(x: size.width, y: 0)); path.addLine(to: CGPoint(x: 0, y: size.height))
                    }.stroke(Color.red, lineWidth: 2)
                }
            }
            .onTapGesture {
                session.commitTransform()
                session.selectLayerTarget(layer.id, mask: true)
            }
            .accessibilityLabel("Select mask: \(layer.name)")
    }

    @ViewBuilder private var nameColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if session.renamingLayerID == layer.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onAppear { draftName = layer.name; nameFocused = true }
                    .onSubmit { finishRenaming() }
                    .onChange(of: nameFocused) { _, focused in if !focused { finishRenaming() } }
            } else {
                Text((layer.maskSourceID == nil ? "" : "↳ ") + layer.name)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var detail: String {
        if let source = layer.maskSourceID {
            return "Clipped to " + (session.document?.layers.first { $0.id == source }?.name ?? "Missing source")
        }
        return layer.liveText != nil ? "Text" : layer.adjustment != nil ? "Adjustment" : layer.isGroup ? "Folder" : layer.sizeLabel
    }

    private func effectRow(_ kind: LayerEffectKind) -> some View {
        let isOn = layer.effects?.isEnabled(kind) == true
        let chosen = session.selectedEffect == LayerEffectSelection(layerID: layer.id, kind: kind)
        return HStack(spacing: 8) {
            Button { session.toggleEffect(kind, on: layer.id) } label: {
                Image(systemName: isOn ? "eye" : "eye.slash").font(.system(size: 11))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointerHighlight().foregroundStyle(.secondary)
            .accessibilityLabel("\(isOn ? "Hide" : "Show") \(kind.rawValue)")
            Color.clear.frame(width: indent + 6, height: 1)
            Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(kind.rawValue).font(.system(size: 12)).foregroundStyle(isOn ? .primary : .secondary)
            Spacer()
        }
        .frame(height: 44)
        .background(chosen ? Color.accentColor.opacity(0.28) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { session.selectEffect(kind, on: layer.id, editing: true) }
        .onTapGesture { session.selectEffect(kind, on: layer.id) }
        .accessibilityLabel(kind.rawValue + " effect")
    }

    @ViewBuilder private var menu: some View {
        Button("Duplicate Layer", systemImage: "plus.square.on.square") {
            select(); session.duplicateActiveLayer()
        }.disabled(!enabled)
        Button("Rename…", systemImage: "pencil") { rename() }.disabled(!enabled)
        Button(layer.isVisible ? "Hide Layer" : "Show Layer", systemImage: layer.isVisible ? "eye.slash" : "eye") {
            session.toggleLayerVisibility(layer.id)
        }.disabled(!enabled)
        if layer.liveText != nil {
            Button("Edit Text", systemImage: "textformat") { session.activeLayerID = layer.id; session.editActiveText() }
        }
        if layer.adjustment?.kind.isEditable == true {
            Button("Edit Adjustment…", systemImage: "slider.horizontal.3") { session.adjustmentEditingID = layer.id }
        }
        Divider()
        Button(layer.maskSourceID == nil ? "Create Clipping Mask" : "Release Clipping Mask", systemImage: "arrow.turn.left.down") {
            session.toggleClippingMask(layer.id)
        }.disabled(!session.canToggleClippingMask(layer.id))
        Button("Group Selected Layers", systemImage: "folder.badge.plus") {
            if !selected { select() }
            session.groupSelectedLayers()
        }.disabled(!enabled)
        if layer.isGroup {
            Button("Ungroup", systemImage: "folder.badge.minus") { select(); session.ungroupLayers() }.disabled(!session.canUngroupLayers)
        }
        if layer.parentID != nil {
            Button("Move Out of Folder", systemImage: "arrow.up.left") { select(); session.moveActiveLayerOutOfGroup() }
                .disabled(!enabled)
        }
        Button(session.mergeTitle, systemImage: "square.2.layers.3d.bottom.filled") { if !selected { select() }; session.mergeLayers() }
            .disabled(!session.canMergeLayers)
        Divider()
        if layer.asset != nil {
            Button("Load Pixels as Selection", systemImage: "selection.pin.in.out") { session.loadLayerSelection(layerID: layer.id) }
                .disabled(!session.canEditSelection)
        }
        if layer.mask != nil {
            Button("Load Mask as Selection", systemImage: "circle.dashed") { session.loadMaskSelection(layerID: layer.id) }
                .disabled(!session.canEditSelection)
        }
        Divider()
        Button("Delete Layer", systemImage: "trash", role: .destructive) {
            if !selected { select() }
            session.deleteLayerOrMask()
        }.disabled(!enabled)
    }

    private func select() {
        session.commitTransform()
        let keys = KeyModifiers.current
        if keys.contains(.command) || keys.contains(.shift) {
            var ids = session.selectedLayerIDs
            if ids.contains(layer.id), ids.count > 1 { ids.remove(layer.id) } else { ids.insert(layer.id) }
            session.selectLayers(ids, primary: ids.contains(layer.id) ? layer.id : ids.first)
        } else {
            session.selectLayerTarget(layer.id, mask: false)
        }
    }

    private func rename() {
        guard enabled else { return }
        session.activeLayerID = layer.id
        session.renamingLayerID = layer.id
    }

    private func finishRenaming() {
        guard session.renamingLayerID == layer.id else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != layer.name { session.renameLayer(layer.id, to: name) }
        session.renamingLayerID = nil
    }
}

/// Thumbnails for the rows, made again only when what they show changes.
@MainActor private final class LayerThumbnails {
    static let shared = LayerThumbnails()
    private struct Key: Equatable {
        let image: ObjectIdentifier?
        let transform: LayerTransform
        let canvas: CGSize
    }
    private var layers: [UUID: (key: Key, image: UIImage)] = [:]
    private var masks: [UUID: (key: Key, image: UIImage)] = [:]

    func layer(_ layer: ImageLayer, canvas: CGSize) -> UIImage {
        let key = Key(image: layer.asset.map { ObjectIdentifier($0.thumbnail) }, transform: layer.transform, canvas: canvas)
        if let cached = layers[layer.id], cached.key == key { return cached.image }
        let image = CanvasThumbnail.layer(layer.asset?.thumbnail, transform: layer.transform, canvas: canvas, box: 36)
        layers[layer.id] = (key, image)
        return image
    }

    func mask(_ layer: ImageLayer, canvas: CGSize) -> UIImage {
        guard let mask = layer.mask else { return UIImage() }
        let key = Key(image: ObjectIdentifier(mask.asset.thumbnail), transform: layer.maskTransform, canvas: canvas)
        if let cached = masks[layer.id], cached.key == key { return cached.image }
        let image = CanvasThumbnail.mask(mask.asset.thumbnail, transform: layer.maskTransform, canvas: canvas, box: 30)
        masks[layer.id] = (key, image)
        return image
    }
}
