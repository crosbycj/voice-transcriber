import AppKit
import SwiftUI
import VoiceAudio

@MainActor
final class RecordingBarPanelController {
    private let model: RecordingBarModel
    private let panel: NSPanel

    init(
        model: RecordingBarModel,
        amplitudeService: AmplitudeService,
        onCancel: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onDismissError: @escaping () -> Void
    ) {
        self.model = model

        let hostingView = NSHostingView(
            rootView: RecordingBarView(
                model: model,
                amplitudeService: amplitudeService,
                onCancel: onCancel,
                onStop: onStop,
                onDismissError: onDismissError
            )
        )
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(width: BarMetrics.panelWidth, height: BarMetrics.panelHeight)
        )
        hostingView.autoresizingMask = [.width, .height]

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: BarMetrics.panelWidth, height: BarMetrics.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
        panel.ignoresMouseEvents = false
        panel.setContentSize(hostingView.frame.size)

        self.panel = panel

        // Re-position when the Dock shows/hides or displays change. visibleFrame
        // excludes the Dock, so anchoring to its minY keeps the bar above it.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func prepare() {
        updatePanelFrame(animated: false)
    }

    func present(state: RecordingBarState) {
        model.state = state
        updatePanelFrame(animated: panel.isVisible)
        panel.orderFrontRegardless()
    }

    func dismiss() {
        panel.orderOut(nil)
        model.state = .hidden
    }

    private func updatePanelFrame(animated: Bool) {
        guard let screen = preferredScreen() else { return }

        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: max(frame.minX, min(frame.midX - BarMetrics.panelWidth / 2, frame.maxX - BarMetrics.panelWidth)),
            // Pill is vertically centered in a 60-tall panel, so the visible
            // bar lands ~18px above this y-origin.
            y: frame.minY + 6
        )

        if animated {
            panel.animator().setFrameOrigin(origin)
        } else {
            panel.setFrameOrigin(origin)
        }
    }

    private func preferredScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
    }

    @objc
    private func handleScreenParametersChange() {
        updatePanelFrame(animated: true)
    }
}
