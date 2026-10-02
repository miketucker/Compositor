import CoreGraphics
import Foundation

extension EditorSession {
    /// An explicitly empty selection leaves nothing paintable, so painting never starts.
    var canPaint: Bool {
        // A folder has no pixels of its own, so only its mask can be painted.
        canEditLayers && selectedLayerIDs.count == 1 && (activeLayer?.isGroup == false || isMaskSelected) && selection?.isEmpty != true
            && activeLayerID.map { document?.effectiveVisibleIDs.contains($0) == true } == true
            && (!isMaskSelected || activeLayer?.mask?.isEnabled == true)
            && (isMaskSelected || activeLayer?.adjustment == nil)
    }
    /// Why a stroke can't start on the target, for the alert, as Photoshop explains a brush it refuses. Nil when
    /// nothing about the target is in the way; while the editor is busy (a transform, a dialog) a press just waits.
    var paintRefusal: String? {
        guard canEditLayers, let layer = activeLayer, !canPaint else { return nil }
        if selectedLayerIDs.count > 1 { return "Several layers are selected. Select just one to paint on it." }
        if layer.isGroup, !isMaskSelected {
            return "“\(layer.name)” is a folder, which has no pixels of its own. Paint on a layer inside it, or on the folder’s mask."
        }
        if document?.effectiveVisibleIDs.contains(layer.id) != true {
            return "“\(layer.name)” is hidden, or inside a hidden folder. Show it to paint on it."
        }
        if isMaskSelected, layer.mask?.isEnabled != true {
            return "The layer mask is turned off. Shift-click its thumbnail to turn it on, then paint."
        }
        if !isMaskSelected, layer.adjustment != nil {
            return "“\(layer.name)” is an adjustment layer, with no pixels to paint. Paint on its mask instead."
        }
        if selection?.isEmpty == true {
            return "Nothing is selected, so there’s nowhere to paint. Choose Select › Deselect (⌘D) to paint anywhere."
        }
        return nil
    }
    /// Tiled raster edit of the active layer's pixels or mask, within the shared pixel budgets.
    func makeRasterEdit(for layer: ImageLayer, settings: BrushSettings = BrushSettings(), growsMask: Bool = false) throws -> BrushStroke {
        guard let document else { throw ProjectError.tooLarge }
        let stroke = try BrushStroke(layer: layer, mask: isMaskSelected, settings: settings, canvas: document.size, growsMask: growsMask)
        let used = document.layers.filter { $0.id != layer.id }.reduce(0) { total, layer in
            let image = isMaskSelected ? layer.mask?.asset.image : layer.asset?.image
            return total + (image.map { $0.width * $0.height } ?? 0)
        }
        stroke.pixelLimit = DocumentLimits.documentPixelBudget - used
        stroke.selectionClip = try selection?.clip(canvas: document.size)
        if !isMaskSelected, layer.mask != nil {
            let maskPixels = document.layers.filter { $0.id != layer.id }.reduce(0) { $0 + ($1.mask.map { $0.asset.image.width * $0.asset.image.height } ?? 0) }
            stroke.pixelLimit = min(stroke.pixelLimit, DocumentLimits.documentPixelBudget - maskPixels)
        }
        return stroke
    }
    func beginBrush(at point: CGPoint, pressure: CGFloat = 1, estimate: Int? = nil) {
        // Spot Healing and Clone Stamp rework image pixels; they have nothing to do on a mask.
        if tool == .blur, blurMode != .blur { beginWarp(at: point); return }
        guard tool == .brush || tool == .blur || (tool.isBrushTool && !isMaskSelected) else { return }
        guard canPaint, let layer = activeLayer, let document else { brushError = paintRefusal; return }
        var sourceOffset: CGSize?
        if tool == .cloneStamp {
            guard let offset = cloneStrokeOffset(at: point) else {
                brushError = "Option-click where Clone Stamp should copy from first."
                return
            }
            sourceOffset = offset
        }
        finishOpacityEdit()
        do {
            var settings = brushSettings
            settings.healing = tool == .spotHealing
            settings.erasing = tool == .brush && brushMode == .erase && !isMaskSelected
            settings.healingMode = spotHealingMode
            settings.pressure = tool == .brush ? brushPressure : []
            #if os(macOS)
            // The Mac's bar has no Pressure setting for the round brush: a tablet's pressure is for plugin brushes,
            // which say among their options what it does.
            settings.pressure = []
            #endif
            if isMaskSelected { settings.red = maskPaintWhite ? 1 : 0; settings.green = settings.red; settings.blue = settings.red }
            // A plugin's brush paints in its pattern, and its own settings say what pressure does.
            if tool == .brush, let brush = pluginBrush, var ink = PluginRegistry.shared.ink(for: brush) {
                let background = isMaskSelected ? (maskPaintWhite ? PaletteColor.black : .white) : backgroundColor
                ink.background = (background.red, background.green, background.blue)
                settings.ink = .pattern(ink)
                settings.pressure = []
            }
            let stroke = try makeRasterEdit(for: layer, settings: settings, growsMask: tool == .brush)
            if let offset = sourceOffset {
                guard let sample = cloneSample(document, for: stroke, offset: offset) else { return }
                cloneOffset = offset
                stroke.clone = sample
            }
            // Blur paints a softened copy of the layer, in place, through the brush tip.
            if tool == .blur {
                guard let blur = blurSample(for: stroke) else { return }
                stroke.clone = blur.sample
                stroke.cloneRender = blur.render
            }
            stroke.isBlur = tool == .blur
            brushStroke = stroke
            try stroke.append(point, pressure: pressure)
            brushStabilizer = tool == .brush && brushSettings.smoothing > 0
                ? BrushStabilizer(start: BrushSample(point: point, pressure: pressure), smoothing: brushSettings.smoothing,
                                  zoom: viewport.zoom) : nil
            // Where the stroke's look follows the Pencil's pressure, samples whose force is still UIKit's estimate are
            // only shown, held for the measured one UIKit sends back (see `HeldBrushSamples`).
            heldBrush = stroke.followsPressure
                ? HeldBrushSamples(start: BrushSample(point: point, pressure: pressure, estimate: estimate)) : nil
            brushPredicted = []
            lastBrushPoint = (point, layer.id, isMaskSelected)
            brushRevision += 1
        } catch { cancelBrush(); brushError = error.localizedDescription }
    }
    func continueBrush(at point: CGPoint, pressure: CGFloat = 1, estimate: Int? = nil) {
        if let warpStroke { warpStroke.append(point); lastBrushPoint?.point = point; brushRevision += 1; return }
        guard brushStroke != nil else { return }
        continueBrush(at: [BrushSample(point: point, pressure: pressure, estimate: estimate)])
    }
    /// Several samples of the stroke at once (see `BrushStroke.append`), in the order they were taken, and where the
    /// stroke is expected to go next, drawn until the samples that follow replace it.
    func continueBrush(at samples: [BrushSample], predicted: [BrushSample] = []) {
        if heldBrush != nil, warpStroke == nil, brushStroke != nil {
            // Shown but not yet the stroke's for good: what's certain is drawn; what's still estimated stays held and
            // goes on as the provisional tail, on to where the stroke is predicted to be.
            heldBrush?.hold(samples)
            brushPredicted = predicted
            draw(heldBrush?.release() ?? [], predicted: (heldBrush?.samples ?? []) + predicted)
            if let last = samples.last { lastBrushPoint?.point = last.point }
            return
        }
        guard warpStroke == nil, brushStroke != nil, samples.count > 1 || !predicted.isEmpty else {
            // One by one, as they ever were.
            for sample in samples {
                if warpStroke != nil {
                    warpStroke?.append(sample.point)
                    lastBrushPoint?.point = sample.point
                    brushRevision += 1
                } else {
                    draw([sample], predicted: [])
                }
            }
            return
        }
        draw(samples, predicted: predicted)
    }
    /// Draws the samples the stroke takes for good, on through the provisional ones to where the Pencil is predicted
    /// to be: down Smoothing's line when it's on, straight to the stroke otherwise.
    private func draw(_ samples: [BrushSample], predicted: [BrushSample]) {
        if brushStabilizer != nil { continueSmoothed(samples, predicted: predicted); return }
        guard let brushStroke else { return }
        do {
            try brushStroke.append(samples, predicted: predicted)
            if let last = samples.last { lastBrushPoint?.point = last.point }
            brushRevision += 1
        } catch { cancelBrush(); brushError = error.localizedDescription }
    }
    /// The measured forces UIKit sent back for samples the stroke shows at their estimates (see `HeldBrushSamples`).
    /// With `redraw` the stretch they make certain is drawn at once; without, the samples about to arrive draw it, so
    /// a frame renders once.
    func correctBrush(_ corrections: [(estimate: Int, pressure: CGFloat)], redraw: Bool = true) {
        guard brushStroke != nil, heldBrush != nil, warpStroke == nil else { return }
        do {
            for correction in corrections where heldBrush?.correct(correction.estimate, pressure: correction.pressure) == true {
                try brushStroke?.correctStart(pressure: correction.pressure)
                brushStabilizer?.correctStart(pressure: correction.pressure)
            }
        } catch { cancelBrush(); brushError = error.localizedDescription; return }
        guard redraw else { return }
        draw(heldBrush?.release() ?? [], predicted: (heldBrush?.samples ?? []) + brushPredicted)
    }
    /// With Smoothing: the line goes on to the samples, what's settled behind them is kept, and the rest, through to the
    /// Pencil and on to where it's predicted to be, is drawn until the next samples redraw it smoother.
    private func continueSmoothed(_ samples: [BrushSample], predicted: [BrushSample] = []) {
        guard let brushStroke, let brushStabilizer else { return }
        for sample in samples { brushStabilizer.add(sample) }
        let line = brushStabilizer.take()
        do {
            try brushStroke.append(line.settled, predicted: line.provisional + predicted)
            if let last = samples.last { lastBrushPoint?.point = last.point }
            brushRevision += 1
        } catch { cancelBrush(); brushError = error.localizedDescription }
    }
    /// Where a Shift-click paints a line from: the end of the last stroke, while the same layer (or mask) is the target.
    func shiftLineStart() -> CGPoint? {
        guard let last = lastBrushPoint, last.layerID == activeLayerID, last.mask == isMaskSelected else { return nil }
        return last.point
    }
    func cancelBrush() {
        warpStroke = nil
        brushStroke = nil
        brushStabilizer = nil
        heldBrush = nil
        brushPredicted = []
        brushRevision += 1
    }
    /// Called directly by mouse-up, before the next input event can be handled.
    @discardableResult
    func finishBrushImmediately() -> Bool {
        if warpStroke != nil {
            guard !isProjectBusy else { return false }
            finishWarp()
            return true
        }
        guard let stroke = brushStroke else { return true }
        guard !isProjectBusy else { return false }
        defer { cancelBrush() }
        do {
            // What was still held for corrections is the stroke's now: measured samples released, the rest fading
            // out along the way the Pencil actually lifted (see `HeldBrushSamples`).
            if let released = heldBrush?.releaseAll(), !released.isEmpty { draw(released, predicted: []) }
            heldBrush = nil
            // Smoothing settles the rest of the line as it's shown, out to where the Pencil lifted.
            if let line = brushStabilizer?.take(finishing: true), !line.settled.isEmpty { try stroke.append(line.settled) }
            try stroke.flush()
            if stroke.settings.healing { try stroke.heal() }
            if !stroke.patches.isEmpty { try commitPaintSnapshot(stroke) }
        } catch { brushError = error.localizedDescription }
        return true
    }

    func finishBrush() async { finishBrushImmediately() }

    /// Install immutable tiles immediately, including the undo entry. The next
    /// stroke and other tools can start without awaiting full-image assembly.
    func commitPaintSnapshot(_ stroke: BrushStroke) throws {
        let result = try stroke.paintSnapshot()
        guard result.transform.isValid,
              let index = document?.layers.firstIndex(where: { $0.id == stroke.layer.id }),
              let current = document?.layers[index], current.asset?.image === stroke.layer.asset?.image,
              current.transform == stroke.layer.transform else { return }
        var mask = current.mask
        if !stroke.isMask, let original = mask, original.placement == nil, result.bounds != stroke.sourceRect {
            let raster = RasterSnapshot.replacing(source: original.asset, sourceRect: stroke.sourceRect,
                patches: [], crop: result.bounds, isMask: true)
            mask = original.replacing(ImportedImage(image: try raster.makeImage(), thumbnail: try raster.thumbnail(),
                name: original.asset.name, raster: raster))
        }
        beginEdit(stroke.editName ?? (stroke.isMask ? "Paint Mask" : stroke.settings.erasing ? "Erase" : stroke.isBlur ? "Blur" : stroke.clone != nil ? "Clone Stamp" : stroke.settings.healing ? "Spot Healing" : "Brush Stroke"))
        if stroke.isMask {
            document?.layers[index].mask = current.mask.map { mask in
                var painted = mask.replacing(result.asset)
                // Grown past its layer, or already placed on its own: the mask keeps its place on the document. A linked
                // one still moves with its layer.
                if mask.placement != nil || result.bounds != stroke.sourceRect { painted.placement = result.transform }
                return painted
            } ?? LayerMask(asset: result.asset)
        } else {
            document?.layers[index] = ImageLayer(id: current.id, asset: result.asset, name: current.name,
                isVisible: current.isVisible, transform: result.transform, parentID: current.parentID, isGroup: false,
                opacity: current.opacity, blendMode: current.blendMode, mask: mask, maskSourceID: current.maskSourceID, effects: current.effects)
        }
        endEdit()
    }

    /// Assembles a raster edit off the main thread and replaces the layer's pixels or
    /// mask as one undo step. Other layer properties are read at commit time.
    func commitRasterEdit(_ stroke: BrushStroke, name: String, alsoApply: (() -> Void)? = nil) async throws {
        isProjectBusy = true
        defer { isProjectBusy = false }
        guard stroke.committedTransform.isValid else { throw ProjectError.tooLarge }
        let input = stroke.commitInput()
        let result = try await BrushCommit.shared.render(input)
        let asset = result.asset
        let transform = stroke.transform(for: result.pixelBounds.offsetBy(dx: stroke.committedBounds.minX, dy: stroke.committedBounds.minY))
        guard transform.isValid else { throw ProjectError.tooLarge }
        var mask = stroke.layer.mask
        if !stroke.isMask, let originalMask = mask, originalMask.placement == nil {
            mask = originalMask.replacing(try await BrushCommit.shared.expandMask(originalMask.asset, for: input, croppedTo: result.pixelBounds))
        }
        // The raster was built from this layer's pixels, transform, and mask; never
        // write it over content that changed underneath it.
        guard let index = document?.layers.firstIndex(where: { $0.id == stroke.layer.id }),
              let current = document?.layers[index], current.asset?.image === stroke.layer.asset?.image,
              current.transform == stroke.layer.transform,
              current.mask?.asset.image === stroke.layer.mask?.asset.image else { return }
        beginEdit(name)
        if stroke.isMask {
            let bounds = result.pixelBounds.offsetBy(dx: stroke.committedBounds.minX, dy: stroke.committedBounds.minY)
            document?.layers[index].mask = current.mask.map { mask in
                var edited = mask.replacing(asset)
                // Grown past its layer, or already placed on its own: the mask keeps its place on the document.
                if mask.placement != nil || bounds != stroke.sourceRect { edited.placement = transform }
                return edited
            } ?? LayerMask(asset: asset)
        } else {
            document?.layers[index] = ImageLayer(id: current.id, asset: asset, name: current.name,
                isVisible: current.isVisible, transform: transform, parentID: current.parentID, isGroup: false,
                opacity: current.opacity, blendMode: current.blendMode,
                mask: mask.map { mask -> LayerMask in
                    var kept = mask
                    kept.isEnabled = current.mask?.isEnabled ?? mask.isEnabled
                    return kept
                }, maskSourceID: current.maskSourceID, effects: current.effects)
        }
        alsoApply?()
        endEdit()
    }
    /// Tools where number keys set opacity: the brush or gradient opacity, or with
    /// Move/Transform the opacity of the selected layers.
    var usesOpacityKeys: Bool { tool.isBrushTool || tool == .gradient || tool == .move }

    /// Photoshop-style opacity keys: 1 = 10% … 9 = 90%, 0 = 100%.
    /// Two digits typed quickly set an exact value (4 then 5 = 45%, 0 then 5 = 5%).
    func typeOpacityDigit(_ digit: Int, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard usesOpacityKeys, brushStroke == nil, !isProjectBusy, (0...9).contains(digit) else { return }
        var percent = digit == 0 ? 100 : digit * 10
        if let pending = pendingOpacityDigit, time - pending.time < 0.6 {
            percent = max(1, pending.digit * 10 + digit)
            pendingOpacityDigit = nil
        } else {
            pendingOpacityDigit = (digit, time)
        }
        let value = CGFloat(percent) / 100
        switch tool {
        case .brush, .spotHealing, .cloneStamp, .blur: brushSettings.opacity = value
        case .gradient: gradientSettings.opacity = value
        default: setSelectedLayersOpacity(Double(value))
        }
    }
    /// Shift-[ / Shift-]: hardness in Photoshop's 25% steps (0, 25, 50, 75, 100%).
    func changeBrushHardness(increase: Bool) {
        guard brushStroke == nil else { return }
        // Snap to the next step up or down, so 80% goes to 100% or 75%.
        let quarter = brushSettings.hardness * 4
        let step = increase ? floor(quarter + 0.001) + 1 : ceil(quarter - 0.001) - 1
        brushSettings.hardness = min(4, max(0, step)) / 4
    }
    func changeBrushSize(increase: Bool) {
        guard brushStroke == nil else { return }
        // A step of a fifth, but always at least one pixel: 2 shrunk by a fifth would otherwise round back to 2,
        // leaving the smallest brushes out of reach.
        let current = brushSettings.diameter
        let stepped = increase ? max(current + 1, (current * 1.2).rounded()) : min(current - 1, (current / 1.2).rounded())
        brushSettings.diameter = min(2000, max(1, stepped))
    }
}
