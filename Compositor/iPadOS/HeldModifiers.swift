import Observation
import SwiftUI

/// The modifier keys held down right now, for controls that show what a held key temporarily changes, as
/// Photoshop's options bar does: Command flips Auto Select, Shift flips the aspect-ratio lock. On iPad they come from
/// a hardware keyboard, or from the canvas's on-screen modifier keys for working without one.
@MainActor @Observable final class HeldModifiers {
    static let shared = HeldModifiers()
    private(set) var flags: KeyModifiers = []
    /// Held on a hardware keyboard.
    var keyboard: KeyModifiers = [] { didSet { update() } }
    /// Latched on with the canvas's on-screen keys, until they're tapped off.
    var onScreen: KeyModifiers = [] { didSet { update() } }
    /// Turned on with the tool bar's Option button (see `ToolOptionButton`), for the canvas alone: its presses work as
    /// if these were held, but the Layers panel and the menus don't see them.
    private(set) var latched: KeyModifiers = []
    /// The latch is for one press: it lets go when the canvas's next press ends.
    @ObservationIgnored private var latchedOnce = false
    /// What the canvas takes as held: the keys, and the tool bar's latch.
    private(set) var canvasFlags: KeyModifiers = []
    /// Told when what the canvas takes as held changes, so it can follow at once.
    @ObservationIgnored var changed: ((KeyModifiers) -> Void)?

    private init() {}

    func latch(_ keys: KeyModifiers, once: Bool = false) {
        latchedOnce = once
        guard keys != latched else { return }
        latched = keys
        update()
    }

    /// A press on the canvas has ended: a latch for one press lets go.
    func canvasPressEnded() {
        if latchedOnce { latch([]) }
    }

    private func update() {
        let held = keyboard.union(onScreen)
        if held != flags { flags = held }
        let canvas = held.union(latched)
        guard canvas != canvasFlags else { return }
        canvasFlags = canvas
        changed?(canvas)
    }
}

extension KeyModifiers {
    init(_ modifiers: EventModifiers) {
        self = []
        if modifiers.contains(.shift) { insert(.shift) }
        if modifiers.contains(.control) { insert(.control) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.command) { insert(.command) }
    }
}
