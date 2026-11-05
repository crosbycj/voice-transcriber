import AppKit
import Combine
import Foundation
import VoiceAudio
import VoiceCore

@MainActor
final class VoiceMenuBarController: NSObject, NSMenuDelegate {
    private enum Layout {
        static let transcriptPreviewLimit = 420
        static let transcriptPreviewWidth: CGFloat = 300
    }

    private let coordinator: AppCoordinator
    private let soundManager: SoundManager
    private let statusItem: NSStatusItem
    private let menu = NSMenu(title: "Voice Transcriber")
    private let calendar = Calendar.current
    private let timeFormatter: DateFormatter
    private let shortDateFormatter: DateFormatter
    private var cancellables: Set<AnyCancellable> = []

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.soundManager = .shared

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        self.timeFormatter = timeFormatter

        let shortDateFormatter = DateFormatter()
        shortDateFormatter.setLocalizedDateFormatFromTemplate("MMM d")
        self.shortDateFormatter = shortDateFormatter

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        super.init()

        configureStatusItem()
        configureMenu()
        observeCoordinator()
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        coordinator.prepareMenuState()
        rebuildMenu()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }

        button.imagePosition = .imageOnly
        updateStatusItemAppearance()
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    private func observeCoordinator() {
        coordinator.$recentTranscripts
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        coordinator.$availableMicrophones
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        coordinator.$selectedMicrophoneUID
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        coordinator.$launchAtLoginStatus
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        coordinator.$hotkeyPermissionStatus
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        coordinator.$recordingBarAnimationPreset
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        soundManager.$isEnabled
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        let image = NSImage(named: "MenuBarIconTemplate")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voice Transcriber")
        image?.isTemplate = true
        button.image = image
        button.alphaValue = 1
        button.toolTip = "Voice Transcriber"
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        addRecentTranscriptGroup()
        menu.addItem(NSMenuItem.separator())
        addUtilitiesGroup()
        menu.addItem(NSMenuItem.separator())
        addFooterGroup()
    }

    private func addFooterGroup() {
        let quitItem = NSMenuItem(
            title: "Quit Voice Transcriber",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.keyEquivalentModifierMask = [.command]
        menu.addItem(quitItem)
    }

    private func addRecentTranscriptGroup() {
        if coordinator.recentTranscripts.isEmpty {
            let emptyItem = NSMenuItem(title: "No recent transcripts", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for record in coordinator.recentTranscripts {
                let transcriptItem = NSMenuItem(
                    title: transcriptMenuTitle(for: record),
                    action: nil,
                    keyEquivalent: ""
                )
                transcriptItem.submenu = makeTranscriptSubmenu(for: record)
                menu.addItem(transcriptItem)
            }
        }
    }

    private func addUtilitiesGroup() {
        let showInFinderItem = NSMenuItem(
            title: "Show in Finder",
            action: #selector(showStorageInFinder(_:)),
            keyEquivalent: ""
        )
        showInFinderItem.target = self
        menu.addItem(showInFinderItem)

        menu.addItem(NSMenuItem.separator())

        let pushToTalkInfoItem = NSMenuItem(title: "Push to Talk", action: nil, keyEquivalent: "")
        pushToTalkInfoItem.isEnabled = false
        menu.addItem(pushToTalkInfoItem)

        let recordItem = NSMenuItem(
            title: coordinator.isRecording ? "Stop Recording" : "Lock Recording",
            action: #selector(record(_:)),
            keyEquivalent: " "
        )
        recordItem.target = self
        recordItem.keyEquivalentModifierMask = [.function]
        menu.addItem(recordItem)

        let pasteLastTranscriptItem = NSMenuItem(
            title: "Paste Last Transcript",
            action: #selector(pasteLastTranscript(_:)),
            keyEquivalent: "v"
        )
        pasteLastTranscriptItem.target = self
        pasteLastTranscriptItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(pasteLastTranscriptItem)

        let useAnywhereItem = NSMenuItem(
            title: coordinator.hotkeyPermissionStatus.canMonitorHotkeys
                ? "Use Anywhere Enabled"
                : "Enable Use Anywhere...",
            action: coordinator.hotkeyPermissionStatus.canMonitorHotkeys
                ? nil
                : #selector(enableUseAnywhere(_:)),
            keyEquivalent: ""
        )
        useAnywhereItem.target = self
        useAnywhereItem.state = coordinator.hotkeyPermissionStatus.canMonitorHotkeys ? .on : .off
        menu.addItem(useAnywhereItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.submenu = makeSettingsSubmenu()
        menu.addItem(settingsItem)
    }

    private func makeTranscriptSubmenu(for record: TranscriptRecord) -> NSMenu {
        let submenu = NSMenu(title: record.isFailure ? "Transcription failed" : "Transcript")
        submenu.autoenablesItems = false

        if let text = record.usableText {
            submenu.addItem(makeTranscriptPreviewItem(for: text))
            submenu.addItem(NSMenuItem.separator())

            let copyItem = NSMenuItem(title: "Copy", action: #selector(copyTranscript(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = record.id as NSString
            submenu.addItem(copyItem)

            let openInFinderItem = NSMenuItem(
                title: "Open in Finder",
                action: #selector(openTranscriptInFinder(_:)),
                keyEquivalent: ""
            )
            openInFinderItem.target = self
            openInFinderItem.representedObject = record.id as NSString
            submenu.addItem(openInFinderItem)

            let retranscribeItem = NSMenuItem(
                title: "Retranscribe",
                action: #selector(retranscribe(_:)),
                keyEquivalent: ""
            )
            retranscribeItem.target = self
            retranscribeItem.representedObject = record.id as NSString
            retranscribeItem.isEnabled = !coordinator.isRetranscribing(recordID: record.id)
            submenu.addItem(retranscribeItem)
        } else {
            if let reason = record.failureReason {
                let reasonItem = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
                reasonItem.isEnabled = false
                submenu.addItem(reasonItem)
                submenu.addItem(NSMenuItem.separator())
            }

            let retryItem = NSMenuItem(title: "Retry", action: #selector(retranscribe(_:)), keyEquivalent: "")
            retryItem.target = self
            retryItem.representedObject = record.id as NSString
            retryItem.isEnabled = !coordinator.isRetranscribing(recordID: record.id)
            submenu.addItem(retryItem)

            let openAudioItem = NSMenuItem(
                title: "Open Audio in Finder",
                action: #selector(openAudioInFinder(_:)),
                keyEquivalent: ""
            )
            openAudioItem.target = self
            openAudioItem.representedObject = record.id as NSString
            submenu.addItem(openAudioItem)
        }

        let deleteItem = NSMenuItem(title: "Delete", action: #selector(deleteTranscript(_:)), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.representedObject = record.id as NSString
        submenu.addItem(deleteItem)

        submenu.addItem(NSMenuItem.separator())

        let metadataItem = NSMenuItem(title: metadataTitle(for: record), action: nil, keyEquivalent: "")
        metadataItem.isEnabled = false
        submenu.addItem(metadataItem)

        if let deviceName = record.capture?.deviceName {
            let deviceItem = NSMenuItem(title: deviceName, action: nil, keyEquivalent: "")
            deviceItem.isEnabled = false
            submenu.addItem(deviceItem)
        }

        return submenu
    }

    private func makeSettingsSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Settings")
        submenu.autoenablesItems = false

        let microphoneItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        microphoneItem.submenu = makeMicrophoneSubmenu()
        submenu.addItem(microphoneItem)

        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = makeModelSubmenu()
        submenu.addItem(modelItem)

        let animationItem = NSMenuItem(title: "Animation Feel", action: nil, keyEquivalent: "")
        animationItem.submenu = makeAnimationPresetSubmenu()
        submenu.addItem(animationItem)

        submenu.addItem(NSMenuItem.separator())

        let soundsItem = NSMenuItem(
            title: "Play Sounds",
            action: #selector(toggleSounds(_:)),
            keyEquivalent: ""
        )
        soundsItem.target = self
        soundsItem.state = soundManager.isEnabled ? .on : .off
        submenu.addItem(soundsItem)

        let soundSettingsItem = NSMenuItem(
            title: "Sound Settings...",
            action: #selector(openSoundSettings(_:)),
            keyEquivalent: ""
        )
        soundSettingsItem.target = self
        submenu.addItem(soundSettingsItem)

        submenu.addItem(NSMenuItem.separator())

        let launchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchItem.target = self
        launchItem.state = coordinator.isLaunchAtLoginEnabled ? .on : .off
        submenu.addItem(launchItem)

        return submenu
    }

    private func makeAnimationPresetSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Animation Feel")
        submenu.autoenablesItems = false

        for preset in RecordingBarAnimationPreset.allCases {
            let item = NSMenuItem(
                title: preset.displayName,
                action: #selector(selectAnimationPreset(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = preset.rawValue
            item.state = coordinator.recordingBarAnimationPreset == preset ? .on : .off
            submenu.addItem(item)
        }

        return submenu
    }

    private func makeMicrophoneSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Microphone")
        submenu.autoenablesItems = false

        let systemDefaultItem = NSMenuItem(
            title: "System Default",
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        systemDefaultItem.target = self
        systemDefaultItem.representedObject = NSNull()
        systemDefaultItem.state = coordinator.selectedMicrophoneUID == nil ? .on : .off
        submenu.addItem(systemDefaultItem)

        if let selectedMicrophoneUID = coordinator.selectedMicrophoneUID,
           !coordinator.availableMicrophones.contains(where: { $0.uid == selectedMicrophoneUID }) {
            submenu.addItem(NSMenuItem.separator())

            let unavailableItem = NSMenuItem(title: "Selected Microphone Unavailable", action: nil, keyEquivalent: "")
            unavailableItem.isEnabled = false
            unavailableItem.state = .on
            submenu.addItem(unavailableItem)
        }

        if coordinator.availableMicrophones.isEmpty {
            submenu.addItem(NSMenuItem.separator())

            let unavailableItem = NSMenuItem(title: "No audio input devices available", action: nil, keyEquivalent: "")
            unavailableItem.isEnabled = false
            submenu.addItem(unavailableItem)
            return submenu
        }

        submenu.addItem(NSMenuItem.separator())

        for microphone in coordinator.availableMicrophones {
            let microphoneItem = NSMenuItem(
                title: microphone.name,
                action: #selector(selectMicrophone(_:)),
                keyEquivalent: ""
            )
            microphoneItem.target = self
            microphoneItem.representedObject = microphone.uid as NSString
            microphoneItem.state = coordinator.selectedMicrophoneUID == microphone.uid ? .on : .off
            submenu.addItem(microphoneItem)
        }

        return submenu
    }

    private func makeModelSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Model")
        submenu.autoenablesItems = false

        let currentModelItem = NSMenuItem(title: "Parakeet TDT 0.6B v3", action: nil, keyEquivalent: "")
        currentModelItem.state = .on
        submenu.addItem(currentModelItem)

        let metadataItem = NSMenuItem(title: "25 Languages · 600MB", action: nil, keyEquivalent: "")
        metadataItem.isEnabled = false
        submenu.addItem(metadataItem)

        return submenu
    }

    private func transcriptMenuTitle(for record: TranscriptRecord) -> String {
        let timestamp = formattedTimestamp(for: record.timestamp, includeTodayLabel: false)

        if record.needsTranscription {
            return "\(timestamp) — transcribing"
        }

        return record.isFailure ? "\(timestamp) — failed" : timestamp
    }

    private func makeTranscriptPreviewItem(for text: String) -> NSMenuItem {
        let previewText = truncate(condensed(text), limit: Layout.transcriptPreviewLimit)
        let previewItem = NSMenuItem(title: previewText, action: nil, keyEquivalent: "")
        previewItem.isEnabled = false
        previewItem.attributedTitle = makePreviewAttributedTitle(for: previewText)
        return previewItem
    }

    private func condensed(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }

        let prefix = String(text.prefix(max(0, limit - 3)))
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(trimmedPrefix)..."
    }

    private func makePreviewAttributedTitle(for text: String) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: NSFont.systemFontSize)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.lineBreakStrategy = .standard
        paragraphStyle.hyphenationFactor = 0
        paragraphStyle.tighteningFactorForTruncation = 0

        let wrappedText = wrapText(text, font: font, maxWidth: Layout.transcriptPreviewWidth)
        return NSAttributedString(
            string: wrappedText,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
    }

    private func wrapText(_ text: String, font: NSFont, maxWidth: CGFloat) -> String {
        guard !text.isEmpty else {
            return text
        }

        var lines: [String] = []
        var currentLine = ""

        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            appendWord(String(word), to: &currentLine, lines: &lines, font: font, maxWidth: maxWidth)
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
        }

        return lines.joined(separator: "\n")
    }

    private func appendWord(
        _ word: String,
        to currentLine: inout String,
        lines: inout [String],
        font: NSFont,
        maxWidth: CGFloat
    ) {
        let candidateLine = currentLine.isEmpty ? word : "\(currentLine) \(word)"
        if renderedWidth(of: candidateLine, font: font) <= maxWidth {
            currentLine = candidateLine
            return
        }

        if !currentLine.isEmpty {
            lines.append(currentLine)
            currentLine = ""
        }

        if renderedWidth(of: word, font: font) <= maxWidth {
            currentLine = word
            return
        }

        var currentChunk = ""
        for character in word {
            let candidateChunk = currentChunk + String(character)
            if !currentChunk.isEmpty, renderedWidth(of: candidateChunk, font: font) > maxWidth {
                lines.append(currentChunk)
                currentChunk = String(character)
            } else {
                currentChunk = candidateChunk
            }
        }

        currentLine = currentChunk
    }

    private func renderedWidth(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func metadataTitle(for record: TranscriptRecord) -> String {
        "\(formattedTimestamp(for: record.timestamp, includeTodayLabel: true)) · \(formattedDuration(record.durationSeconds))"
    }

    private func formattedTimestamp(for date: Date, includeTodayLabel: Bool) -> String {
        if calendar.isDateInToday(date) {
            let time = timeFormatter.string(from: date)
            return includeTodayLabel ? "Today, \(time)" : time
        }

        if calendar.isDateInYesterday(date) {
            return "Yesterday, \(timeFormatter.string(from: date))"
        }

        return "\(shortDateFormatter.string(from: date)), \(timeFormatter.string(from: date))"
    }

    private func formattedDuration(_ durationSeconds: Double) -> String {
        let roundedSeconds = max(1, Int(durationSeconds.rounded()))

        if roundedSeconds < 60 {
            return "\(roundedSeconds)s"
        }

        let minutes = roundedSeconds / 60
        let seconds = roundedSeconds % 60

        if seconds == 0 {
            return "\(minutes)m"
        }

        return "\(minutes)m \(seconds)s"
    }

    private func recordID(from sender: Any?) -> String? {
        guard let menuItem = sender as? NSMenuItem else {
            return nil
        }

        return menuItem.representedObject as? String
    }

    @objc
    private func copyTranscript(_ sender: Any?) {
        guard let recordID = recordID(from: sender) else { return }
        coordinator.copyTranscript(recordID: recordID)
    }

    @objc
    private func openTranscriptInFinder(_ sender: Any?) {
        guard let recordID = recordID(from: sender) else { return }
        coordinator.revealTranscriptFiles(recordID: recordID, audioOnly: false)
    }

    @objc
    private func openAudioInFinder(_ sender: Any?) {
        guard let recordID = recordID(from: sender) else { return }
        coordinator.revealTranscriptFiles(recordID: recordID, audioOnly: true)
    }

    @objc
    private func retranscribe(_ sender: Any?) {
        guard let recordID = recordID(from: sender) else { return }
        coordinator.retranscribe(recordID: recordID)
    }

    @objc
    private func deleteTranscript(_ sender: Any?) {
        guard let recordID = recordID(from: sender) else { return }
        coordinator.deleteTranscript(recordID: recordID)
    }

    @objc
    private func selectMicrophone(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }

        let selectedUID: String?
        if menuItem.representedObject is NSNull {
            selectedUID = nil
        } else {
            selectedUID = menuItem.representedObject as? String
        }

        coordinator.updateSelectedMicrophone(selectedUID)
    }

    @objc
    private func selectAnimationPreset(_ sender: Any?) {
        guard
            let menuItem = sender as? NSMenuItem,
            let rawValue = menuItem.representedObject as? String,
            let preset = RecordingBarAnimationPreset(rawValue: rawValue)
        else {
            return
        }

        coordinator.updateRecordingBarAnimationPreset(preset)
    }

    @objc
    private func showStorageInFinder(_ sender: Any?) {
        coordinator.showStorageInFinder()
    }

    @objc
    private func record(_ sender: Any?) {
        coordinator.performRecordMenuAction()
    }

    @objc
    private func pasteLastTranscript(_ sender: Any?) {
        coordinator.pasteLastTranscript()
    }

    @objc
    private func enableUseAnywhere(_ sender: Any?) {
        coordinator.requestHotkeyPermissions()
    }

    @objc
    private func toggleLaunchAtLogin(_ sender: Any?) {
        coordinator.toggleLaunchAtLogin()
    }

    @objc
    private func toggleSounds(_ sender: Any?) {
        soundManager.setEnabled(!soundManager.isEnabled)
    }

    @objc
    private func openSoundSettings(_ sender: Any?) {
        SoundSettingsWindowController.shared.show()
    }

    @objc
    private func quit(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }
}
