import XCTest

/// The iPad app driven as a person would: fingers on the canvas, the tool rail, the Layers panel.
final class iPadUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // Each test starts from the welcome screen, not the projects the last one left open, and with the round brush,
        // whatever brush the last one chose.
        app.launchArguments += ["-reopensProjects", "NO", "-tool.brushKind", ""]
        app.launch()
        return app
    }

    @MainActor
    private func keep(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private var canvas: XCUIElement { XCUIApplication().descendants(matching: .any)["editorCanvas"] }

    @MainActor
    func testCreateACanvasAndPaint() throws {
        let app = launch()
        let create = app.buttons["createCanvas"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        keep(app, "Welcome")
        create.tap()
        XCTAssertTrue(app.staticTexts["canvasDimensions"].waitForExistence(timeout: 5))
        keep(app, "New canvas")

        app.buttons["Brush (B) · Eraser (E)"].tap()
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
        keep(app, "After a brush stroke")
        XCTAssertEqual(app.staticTexts["layerCount"].label, "1")

        // Two-finger tap undoes the stroke's layer edit.
        canvas.twoFingerTap()
        keep(app, "After undo")

        canvas.pinch(withScale: 2, velocity: 2)
        keep(app, "After pinch")
    }

    @MainActor
    func testShapeTransformAndLayers() throws {
        let app = launch()
        let create = app.buttons["createCanvas"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        app.buttons["Shape (U) · Shift-U switches Rectangle/Ellipse"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)))
        keep(app, "Shape drawn")
        app.buttons["Move / Transform (V)"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.47))
            .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.4)))
        keep(app, "Shape moved")
        app.buttons["addBlankLayer"].tap()
        // The new canvas's own layer, the shape's, and the blank one.
        keep(app, "Three layers")
        XCTAssertEqual(app.staticTexts["layerCount"].label, "3")
    }

    /// The project's title in the middle of the toolbar, which opens its menu.
    @MainActor
    private func title(_ app: XCUIApplication) -> XCUIElement? {
        let bar = app.navigationBars.firstMatch
        return bar.buttons.allElementsBoundByIndex.first { abs($0.frame.midX - bar.frame.midX) < 150 }
    }

    @MainActor
    private func newCanvas(_ app: XCUIApplication) {
        let create = app.buttons["createCanvas"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        create.tap()
        XCTAssertTrue(app.staticTexts["canvasDimensions"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTitleMenuRenamesAndDuplicates() throws {
        let app = launch()
        newCanvas(app)
        // A new project has its file straight away, so it can be renamed at once.
        let name = "Renamed \(UUID().uuidString.prefix(6))"
        try XCTUnwrap(title(app)).tap()
        app.buttons["Rename…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30) + name)
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(app.buttons["Close \(name)"].waitForExistence(timeout: 5), "The tab follows the file's new name")
        XCTAssertEqual(title(app)?.label, name)

        try XCTUnwrap(title(app)).tap()
        app.buttons["Duplicate"].tap()
        XCTAssertTrue(app.buttons["Close \(name) copy"].waitForExistence(timeout: 10), "The copy opens in a tab of its own")
        keep(app, "Renamed and duplicated")
    }

    @MainActor
    func testShareOffersTheImage() throws {
        let app = launch()
        newCanvas(app)
        let started = Date()
        app.buttons["shareImage"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
        // Handed an image still to be made, the sheet held the app up for seven seconds or more as it opened.
        XCTAssertLessThan(Date().timeIntervalSince(started), 4, "The sheet opens without a wait")
        XCTAssertTrue(app.cells["Save Image"].exists, "A PNG, which Photos can take")
        keep(app, "Share sheet")
    }

    @MainActor
    func testImportFromPhotos() throws {
        let app = launch()
        newCanvas(app)
        app.buttons["File"].tap()
        app.buttons["Import from Photos…"].tap()
        // The simulator's library comes with a few photos.
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 10))
        photo.tap()
        app.buttons["Done"].tap()
        let layers = app.staticTexts["layerCount"]
        expectation(for: NSPredicate(format: "label == '2'"), evaluatedWith: layers)
        waitForExpectations(timeout: 15)
        keep(app, "Imported from Photos")
    }

    @MainActor
    func testToolHeaderValuesAndTyping() throws {
        let app = launch()
        newCanvas(app)
        app.buttons["Brush (B) · Eraser (E)"].tap()
        keep(app, "Brush header")
        // A number in the bar is a button showing its value, which opens a slider rather than the keyboard.
        let size = app.buttons["Size"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertEqual(size.value as? String, "40 px")
        // The Pencil's pressure sets the brush's size until told otherwise.
        XCTAssertEqual(app.buttons["Pencil pressure"].value as? String, "Size")
        size.tap()
        let slider = app.popovers.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        slider.adjust(toNormalizedSliderPosition: 1)
        keep(app, "Size popover")
        // Dragged to the far end (as near as a simulated drag gets): the top of its log scale.
        let shown = Int((size.value as? String)?.split(separator: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(shown, 1000)
        // No field until one is asked for: one there from the start takes focus, and the Pencil writes in it rather
        // than dragging the slider.
        XCTAssertFalse(app.popovers.textFields.firstMatch.exists)
        // Typing an exact figure is still there, and still leaves the editor its size.
        let canvasBefore = canvas.frame
        app.popovers.buttons["Type a value"].tap()
        let field = app.popovers.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.doubleTap()
        keep(app, "Typing a size")
        XCTAssertEqual(canvas.frame, canvasBefore, "The editor keeps its size while a field is typed in")
    }

    @MainActor
    func testFullScreenCanvas() throws {
        let app = launch()
        newCanvas(app)
        app.buttons["Brush (B) · Eraser (E)"].tap()
        let before = canvas.frame
        app.buttons["fullScreenCanvas"].tap()
        let exit = app.buttons["exitFullScreen"]
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        keep(app, "Full screen")
        XCTAssertFalse(app.buttons["Brush (B) · Eraser (E)"].exists, "The tool rail is put away")
        XCTAssertFalse(app.staticTexts["canvasDimensions"].exists, "and the status bar")
        XCTAssertFalse(app.buttons["shareImage"].exists, "and the toolbar")
        XCTAssertGreaterThan(canvas.frame.width, before.width)
        XCTAssertGreaterThan(canvas.frame.height, before.height)

        // The tool's options, in a bar that opens out from the tool (and stays as it was last left).
        let options = app.buttons["fullScreenToolOptions"]
        XCTAssertTrue(options.exists)
        if options.label == "Show tool options" { options.tap() }
        let size = app.sliders["fullScreenSize"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["fullScreenOpacity"].exists)
        let sizeBefore = size.value as? String
        size.adjust(toNormalizedSliderPosition: 0.2)
        XCTAssertNotEqual(size.value as? String, sizeBefore)
        XCTAssertEqual(app.buttons["toolOption"].label, "Sample Color", "The eyedropper, named for VoiceOver")
        // The Brush's colors, which open the picker though the tool rail's swatches are put away.
        app.buttons["Foreground color"].tap()
        let closePicker = app.buttons["Close Color Picker (Foreground Color)"]
        XCTAssertTrue(closePicker.waitForExistence(timeout: 5))
        keep(app, "Full screen tool options and picker")
        closePicker.tap()
        options.tap()
        XCTAssertFalse(size.waitForExistence(timeout: 1), "Closed again")
        exit.tap()
        XCTAssertTrue(app.buttons["Brush (B) · Eraser (E)"].waitForExistence(timeout: 5))
        XCTAssertEqual(canvas.frame, before)
    }

    /// The built-in Dither Brush plugin's brush, chosen from the Brush's brush menu, with its options in the bar and
    /// in Full Screen Canvas's.
    @MainActor
    func testDitherBrush() throws {
        let app = launch()
        newCanvas(app)
        app.buttons["Brush (B) · Eraser (E)"].tap()
        let kind = app.buttons["brushKind"]
        XCTAssertTrue(kind.waitForExistence(timeout: 5), "The plugin's brush gives the Brush a brush menu")
        kind.tap()
        app.buttons["Dither"].tap()
        XCTAssertEqual(kind.value as? String, "Dither")
        let pattern = app.buttons["plugin.pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 5))
        // Whatever pattern it was left on, it takes the one chosen.
        for name in ["Bayer 4 × 4", "Checker"] {
            pattern.tap()
            app.buttons[name].tap()
            XCTAssertEqual(pattern.value as? String, name)
        }
        pattern.tap()
        keep(app, "Patterns")
        app.buttons["Checker"].tap()
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        keep(app, "A dithered stroke")

        // The bar runs past the edge in portrait: it scrolls along to the Pressure button.
        let pressure = app.buttons["pluginPressure"]
        let screen = app.windows.firstMatch.frame
        for _ in 0..<4 where !screen.contains(pressure.frame) { pattern.swipeLeft() }
        pressure.tap()
        XCTAssertTrue(app.switches["plugin.pressureDensity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["plugin.lightest"].exists)
        keep(app, "Pressure")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
        XCTAssertFalse(app.switches["plugin.pressureDensity"].waitForExistence(timeout: 1))

        // Mid-drawing, its pattern and density are in the full-screen bar.
        app.buttons["fullScreenCanvas"].tap()
        let options = app.buttons["fullScreenToolOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        if options.label == "Show tool options" { options.tap() }
        XCTAssertTrue(app.sliders["fullScreenDensity"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plugin.pattern"].exists)
        keep(app, "Full screen dither options")
        app.buttons["exitFullScreen"].tap()

        // Back to the round brush, which leaves the plugin's options out.
        XCTAssertTrue(kind.waitForExistence(timeout: 5))
        for _ in 0..<4 where !screen.contains(kind.frame) { app.buttons["plugin.pattern"].swipeRight() }
        kind.tap()
        app.buttons["Round"].tap()
        XCTAssertFalse(app.buttons["plugin.pattern"].waitForExistence(timeout: 1))
    }

    @MainActor
    func testZoomMenu() throws {
        let app = launch()
        newCanvas(app)
        let zoom = app.staticTexts["zoomStatus"]
        app.buttons["zoomMenu"].tap()
        app.buttons["Actual Pixels (100%)"].tap()
        XCTAssertEqual(zoom.label, "100%")
        app.buttons["zoomMenu"].tap()
        app.buttons["Fit Canvas"].tap()
        XCTAssertNotEqual(zoom.label, "100%", "A new canvas fits at less than its full size")
        let fitted = zoom.label
        app.buttons["zoomMenu"].tap()
        // The canvas holds the keys, and a menu opening over it once brought the on-screen keyboard up with it.
        XCTAssertEqual(app.keyboards.count, 0, "No keyboard for a menu")
        // Zoom In leaves the menu open, to step again.
        app.buttons["Zoom In"].tap()
        app.buttons["Zoom In"].tap()
        keep(app, "Zoom menu")
        XCTAssertNotEqual(zoom.label, fitted)
    }

    @MainActor
    func testToolRailTakesTwoColumnsInLandscape() throws {
        let app = launch()
        newCanvas(app)
        let move = app.buttons["Move / Transform (V)"], marquee = app.buttons["Marquee (M)"]
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        XCTAssertGreaterThan(marquee.frame.minY, move.frame.maxY - 1, "One column: Marquee under Move")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        keep(app, "Landscape")
        XCTAssertEqual(marquee.frame.minY, move.frame.minY, accuracy: 1, "Two columns: Marquee beside Move")
        XCTAssertGreaterThan(marquee.frame.minX, move.frame.maxX - 1)
        XCTAssertTrue(app.buttons["Zoom (Z)"].isHittable, "Every tool fits without scrolling")
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testOptionButton() throws {
        let app = launch()
        newCanvas(app)
        // The Clone Stamp's is for one press: it sets the source, then the tool clones again.
        app.buttons["Clone Stamp (S) · Option-click sets the source"].tap()
        let prompt = app.staticTexts["Set a source to copy from"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5))
        let option = app.buttons["toolOption"]
        XCTAssertEqual(option.label, "Set Source")
        option.tap()
        XCTAssertTrue(option.isSelected)
        keep(app, "Set Source on")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.4)).tap()
        XCTAssertFalse(prompt.waitForExistence(timeout: 2), "The source is set")
        XCTAssertFalse(option.isSelected, "and the button has let go")

        // Zoom Out stays on until it's tapped off.
        app.buttons["Zoom (Z)"].tap()
        XCTAssertEqual(option.label, "Zoom Out")
        func zoom() -> Double { Double(app.staticTexts["zoomStatus"].label.filter { $0.isNumber || $0 == "." }) ?? 0 }
        let start = zoom()
        option.tap()
        XCTAssertTrue(option.isSelected)
        canvas.tap()
        let once = zoom()
        XCTAssertEqual(once, start / 2, accuracy: start * 0.02)
        canvas.tap()
        XCTAssertEqual(zoom(), once / 2, accuracy: start * 0.02)
        XCTAssertTrue(option.isSelected, "Still on")
        option.tap()
        canvas.tap()
        XCTAssertEqual(zoom(), once, accuracy: start * 0.02)
    }
}
