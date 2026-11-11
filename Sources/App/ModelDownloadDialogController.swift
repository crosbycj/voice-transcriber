import AppKit
import VoiceTranscription

/// Asks to download the speech model and shows its progress.
///
/// This is an ordinary window the caller awaits, never `NSApp.runModal`. A modal session started from
/// async code blocks the main actor, and the download reports progress and finishes on the main actor,
/// so under a modal session it never even started: the dialog sat on "Checking available model files"
/// forever.
@MainActor
final class ModelDownloadDialogController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let titleLabel = NSTextField(labelWithString: "Speech Recognition Model Required")
    private let messageLabel = NSTextField(
        wrappingLabelWithString: "Voice Transcriber needs to download the speech recognition model (~600MB). This only happens once."
    )
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private let primaryButton = NSButton(title: "Download", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "Quit", target: nil, action: nil)

    private var completionContinuation: CheckedContinuation<Bool, Never>?
    private var downloadTask: Task<Void, Never>?
    private var startDownloadAction: (() -> Void)?

    override init() {
        let contentRect = NSRect(x: 0, y: 0, width: 440, height: 220)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        self.window = window

        super.init()

        configureWindow()
        configureControls()
        buildLayout()
        configureForPrompt()
    }

    func run(
        startDownload: @escaping @Sendable (@escaping TranscriptionModelPreparationProgressHandler) async throws -> Void
    ) async -> Bool {
        startDownloadAction = { [weak self] in
            guard let self else { return }

            beginDownload()
            let progressStream = AsyncStream(TranscriptionModelPreparationProgress.self) { continuation in
                self.downloadTask = Task { [weak self] in
                    do {
                        try await startDownload { progress in
                            continuation.yield(progress)
                        }

                        continuation.finish()

                        await MainActor.run { [weak self] in
                            self?.finish(with: true)
                        }
                    } catch is CancellationError {
                        // Only Quit cancels, and it has already closed the dialog.
                        continuation.finish()
                    } catch {
                        continuation.finish()

                        await MainActor.run { [weak self] in
                            self?.handleFailure(error)
                        }
                    }
                }
            }

            Task { @MainActor [weak self] in
                for await progress in progressStream {
                    self?.apply(progress)
                }
            }
        }

        configureForPrompt()

        return await withCheckedContinuation { continuation in
            completionContinuation = continuation
            showWindow()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        false
    }

    private func configureWindow() {
        window.delegate = self
        window.title = "Voice Transcriber"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovable = true
        window.level = .modalPanel
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func configureControls() {
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byWordWrapping

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true

        progressIndicator.controlSize = .regular
        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.isIndeterminate = false
        progressIndicator.isHidden = true
        progressIndicator.usesThreadedAnimation = true

        primaryButton.target = self
        primaryButton.action = #selector(handlePrimaryButton)
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"

        secondaryButton.target = self
        secondaryButton.action = #selector(handleSecondaryButton)
        secondaryButton.bezelStyle = .rounded
        secondaryButton.keyEquivalent = "\u{1b}"
    }

    private func buildLayout() {
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let buttonRow = NSStackView(views: [secondaryButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let views: [NSView] = [titleLabel, messageLabel, statusLabel, progressIndicator, buttonRow]
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            messageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            statusLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 14),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            progressIndicator.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            progressIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            progressIndicator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            buttonRow.topAnchor.constraint(greaterThanOrEqualTo: progressIndicator.bottomAnchor, constant: 18),
            buttonRow.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])
    }

    private func configureForPrompt() {
        downloadTask = nil
        statusLabel.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        progressIndicator.isIndeterminate = false
        progressIndicator.doubleValue = 0
        primaryButton.title = "Download"
        primaryButton.isEnabled = true
        secondaryButton.isEnabled = true
    }

    private func beginDownload() {
        statusLabel.isHidden = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Checking available model files..."
        progressIndicator.isHidden = false
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        primaryButton.isEnabled = false
        secondaryButton.isEnabled = true
    }

    private func showWindow() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(primaryButton)
    }

    private func apply(_ progress: TranscriptionModelPreparationProgress) {
        guard completionContinuation != nil else { return }

        statusLabel.isHidden = false
        progressIndicator.isHidden = false
        statusLabel.textColor = .secondaryLabelColor

        switch progress {
        case .checking:
            showWorking("Checking available model files...")
        case .downloading(let fractionCompleted):
            if progressIndicator.isIndeterminate {
                progressIndicator.stopAnimation(nil)
                progressIndicator.isIndeterminate = false
            }
            progressIndicator.doubleValue = fractionCompleted * 100
            statusLabel.stringValue = "Downloading model... \(Self.percentString(fractionCompleted))"
        case .preparing:
            // Nothing reports progress here, so show that it's alive rather than a bar that looks stuck.
            showWorking("Getting the model ready for your Mac. This can take a few minutes the first time.")
        }
    }

    private func showWorking(_ status: String) {
        if !progressIndicator.isIndeterminate {
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
        }
        statusLabel.stringValue = status
    }

    private func handleFailure(_ error: Error) {
        guard completionContinuation != nil else { return }

        downloadTask = nil
        statusLabel.isHidden = false
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = error.localizedDescription
        progressIndicator.stopAnimation(nil)
        primaryButton.title = "Retry Download"
        primaryButton.isEnabled = true
        secondaryButton.isEnabled = true
        window.makeFirstResponder(primaryButton)
    }

    private func finish(with result: Bool) {
        guard let continuation = completionContinuation else { return }

        completionContinuation = nil
        startDownloadAction = nil
        downloadTask = nil
        progressIndicator.stopAnimation(nil)
        window.orderOut(nil)
        continuation.resume(returning: result)
    }

    @objc
    private func handlePrimaryButton() {
        guard downloadTask == nil else { return }
        startDownloadAction?()
    }

    @objc
    private func handleSecondaryButton() {
        downloadTask?.cancel()
        finish(with: false)
    }

    private static func percentString(_ fractionCompleted: Double) -> String {
        let percent = Int((fractionCompleted * 100).rounded())
        return "\(max(0, min(percent, 100)))%"
    }
}
