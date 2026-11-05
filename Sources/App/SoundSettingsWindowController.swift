import AppKit
import SwiftUI

@MainActor
final class SoundSettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SoundSettingsWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = SoundSettingsView(onDone: { [weak self] in
            self?.window?.performClose(nil)
        })
        let hosting = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hosting)
        window.title = "Sound Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
