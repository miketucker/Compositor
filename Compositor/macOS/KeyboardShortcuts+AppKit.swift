import AppKit
import SwiftUI

extension ShortcutChord {
    init(_ event: NSEvent) { self.init(CanvasKey(event)) }
    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & 1 != 0 { flags.insert(.command) }
        if modifiers & 2 != 0 { flags.insert(.option) }
        if modifiers & 4 != 0 { flags.insert(.control) }
        if modifiers & 8 != 0 { flags.insert(.shift) }
        return flags
    }
    func event(like event: NSEvent) -> NSEvent? {
        let key = key(like: CanvasKey(event))
        return NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: cocoaModifiers,
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: shiftedCharacters, charactersIgnoringModifiers: shiftedCharacters, isARepeat: event.isARepeat,
            keyCode: key.keyCode)
    }
}

extension ShortcutSettings {
    func canvasEvent(_ event: NSEvent) -> NSEvent? {
        switch canvasRemap(ShortcutChord(event)) {
        case .keep: event
        case .drop: nil
        case .replace(let chord): chord.event(like: event)
        }
    }

    func textEvent(_ event: NSEvent) -> NSEvent? {
        switch textRemap(ShortcutChord(event)) {
        case .keep: event
        case .drop: nil
        case .replace(let chord): chord.event(like: event)
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let chord: ShortcutChord
    let recording: Bool
    let start: () -> Void
    let finish: (ShortcutChord?) -> Void
    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.start = start; button.finish = finish; button.recording = recording
        button.title = recording ? "Press keys…" : chord.label
        button.setAccessibilityLabel(recording ? "Press a shortcut" : chord.label)
        if recording, button.window?.firstResponder !== button { button.window?.makeFirstResponder(button) }
    }
    final class RecorderButton: NSButton {
        var start: (() -> Void)?
        var finish: ((ShortcutChord?) -> Void)?
        var recording = false
        override var acceptsFirstResponder: Bool { true }
        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded; target = self; action = #selector(beginRecording)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func beginRecording() { window?.makeFirstResponder(self); recording = true; start?() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event); return true
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            let chord = ShortcutChord(event)
            guard chord.key.count == 1 else { NSSound.beep(); return }
            recording = false
            finish?(chord)
            window?.makeFirstResponder(nil)
        }
    }
}
