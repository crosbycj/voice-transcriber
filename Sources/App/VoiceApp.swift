import AppKit
import SwiftUI

@MainActor
final class VoiceTranscriberAppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: VoiceMenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        AppCoordinator.shared.startIfNeeded()
        menuBarController = VoiceMenuBarController(coordinator: .shared)
    }
}

@main
struct VoiceTranscriberMenuBarApp: App {
    @NSApplicationDelegateAdaptor(VoiceTranscriberAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
                .frame(width: 1, height: 1)
        }
    }
}
