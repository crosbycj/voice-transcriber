import AppKit
import Foundation
import OSLog
import ServiceManagement
import VoiceAudio
import VoiceCore
import VoiceInput
import VoiceTranscription

/// Wires the app together and owns what the menu shows: preferences, permissions, and recent transcripts.
/// The dictation flow itself lives in `DictationController`.
@MainActor
final class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    @Published private(set) var availableMicrophones: [AudioInputDevice] = []
    @Published private(set) var hotkeyPermissionStatus = HotkeyPermissionStatus()
    @Published private(set) var recentTranscripts: [TranscriptRecord] = []
    @Published private(set) var launchAtLoginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var recordingBarAnimationPreset: RecordingBarAnimationPreset = .gooeySnap
    @Published private(set) var selectedMicrophoneUID: String?

    private let deviceManager: AudioDeviceManager
    private let engine: ParakeetTranscriptionEngine
    private let hotkeyMonitor: HotkeyMonitor
    private let pasteboardService: PasteboardService
    private let transcriptStore: TranscriptStore
    private let dictation: DictationController
    private let logger = Logger(subsystem: "com.cooper.VoiceTranscriber", category: "AppCoordinator")
    private let launchAtLoginService = SMAppService.mainApp
    private let defaults = UserDefaults.standard

    private var hasStarted = false

    private static let selectedMicrophoneDefaultsKey = "voiceTranscriber.selectedMicrophoneUID"
    private static let animationPresetDefaultsKey = "voiceTranscriber.recordingBarAnimationPreset"
    private static let recentTranscriptLimit = 5

    private init() {
        let deviceManager = AudioDeviceManager()
        let engine = ParakeetTranscriptionEngine()
        let pasteboardService = PasteboardService()
        let transcriptStore = TranscriptStore()

        self.deviceManager = deviceManager
        self.engine = engine
        self.hotkeyMonitor = HotkeyMonitor()
        self.pasteboardService = pasteboardService
        self.transcriptStore = transcriptStore
        self.dictation = DictationController(
            recorder: AudioRecorder(deviceManager: deviceManager),
            engine: engine,
            store: transcriptStore,
            pasteboard: pasteboardService
        )

        self.selectedMicrophoneUID = defaults.string(forKey: Self.selectedMicrophoneDefaultsKey)
        self.recordingBarAnimationPreset = RecordingBarAnimationPreset(
            storedValue: defaults.string(forKey: Self.animationPresetDefaultsKey)
        )
        self.dictation.animationPreset = recordingBarAnimationPreset

        self.dictation.microphoneUID = { [weak self] in self?.selectedMicrophoneUID }
        self.dictation.onHistoryChanged = { [weak self] in
            Task { await self?.reloadRecentTranscripts() }
        }
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true

        refreshAudioInputs()
        refreshLaunchAtLoginStatus()
        configureHotkeys()
        dictation.prepare()

        Task { [weak self] in
            await self?.finishLaunching()
        }
    }

    private func finishLaunching() async {
        await reloadRecentTranscripts()

        guard await ensureModelIsDownloaded() else {
            NSApp.terminate(nil)
            return
        }

        let interrupted = await dictation.findInterruptedRecordings()

        dictation.isModelReady = true
        hotkeyPermissionStatus = hotkeyMonitor.permissionStatus()
        if hotkeyPermissionStatus.canMonitorHotkeys {
            hotkeyMonitor.start(promptForPermissions: false)
        }

        do {
            try await engine.prepare()
        } catch {
            // Not fatal: the first transcription tries again, and any recording stays safe meanwhile.
            logger.error("Couldn't preload the speech model: \(error.localizedDescription, privacy: .public)")
        }

        await dictation.finishInterruptedRecordings(interrupted)
        await reloadRecentTranscripts()
    }

    private func ensureModelIsDownloaded() async -> Bool {
        guard await !engine.modelFilesExistOnDisk() else { return true }

        let dialog = ModelDownloadDialogController()
        return await dialog.runDownloadModal { [engine] progressHandler in
            try await engine.prepare(progressHandler: progressHandler)
        }
    }

    // MARK: - Microphones

    func refreshAudioInputs() {
        do {
            availableMicrophones = try deviceManager.availableInputDevices()
        } catch {
            availableMicrophones = []
            logger.error("Failed to enumerate microphones: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A chosen microphone stays chosen while it's unplugged. Recording falls back to the system default
    /// until it returns, rather than forgetting the choice.
    func updateSelectedMicrophone(_ uid: String?) {
        selectedMicrophoneUID = uid

        if let uid {
            defaults.set(uid, forKey: Self.selectedMicrophoneDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.selectedMicrophoneDefaultsKey)
        }
    }

    // MARK: - Preferences

    func updateRecordingBarAnimationPreset(_ preset: RecordingBarAnimationPreset) {
        guard recordingBarAnimationPreset != preset else { return }

        recordingBarAnimationPreset = preset
        dictation.animationPreset = preset
        defaults.set(preset.rawValue, forKey: Self.animationPresetDefaultsKey)
    }

    func prepareMenuState() {
        refreshAudioInputs()
        refreshLaunchAtLoginStatus()

        Task { [weak self] in
            await self?.reloadRecentTranscripts()
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginStatus = launchAtLoginService.status
    }

    var isLaunchAtLoginEnabled: Bool {
        launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
    }

    func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try launchAtLoginService.unregister()
            } else {
                try launchAtLoginService.register()
            }

            refreshLaunchAtLoginStatus()
        } catch {
            logger.error("Couldn't update launch at login: \(error.localizedDescription, privacy: .public)")
            dictation.showFailure("Couldn't update launch at login.")
        }
    }

    // MARK: - Hotkeys

    private func configureHotkeys() {
        hotkeyMonitor.sessionStateProvider = { [weak self] in
            self?.dictation.state ?? .idle
        }

        hotkeyMonitor.permissionStatusHandler = { [weak self] status in
            self?.hotkeyPermissionStatus = status
        }

        hotkeyMonitor.actionHandler = { [weak self] action in
            if action == .pasteVoiceClipboard {
                self?.pasteLastTranscript()
            } else {
                self?.dictation.handle(action)
            }
        }
    }

    func requestHotkeyPermissions() {
        hotkeyPermissionStatus = hotkeyMonitor.permissionStatus(prompt: true)

        if dictation.isModelReady {
            hotkeyMonitor.start(promptForPermissions: false)
        }
    }

    // MARK: - Menu actions

    var isRecording: Bool {
        dictation.state == .recordingHold || dictation.state == .recordingLocked
    }

    func performRecordMenuAction() {
        dictation.toggleFromMenu()
    }

    func isRetranscribing(recordID: String) -> Bool {
        dictation.isRetranscribing(recordID: recordID)
    }

    func retranscribe(recordID: String) {
        dictation.retranscribe(recordID: recordID)
    }

    func copyTranscript(recordID: String) {
        run(failureMessage: "Couldn't copy the transcript.") { [self] in
            guard let text = try await transcriptStore.record(withID: recordID)?.usableText else {
                throw AppCoordinatorError.transcriptUnavailable
            }

            try pasteboardService.copyText(text)
        }
    }

    func pasteLastTranscript() {
        run(failureMessage: "Couldn't paste the last transcript.") { [self] in
            guard let text = try await transcriptStore.latestTranscriptText() else { return }
            _ = try pasteboardService.paste(text)
        }
    }

    func deleteTranscript(recordID: String) {
        run(failureMessage: "Couldn't delete the transcript.") { [self] in
            guard try await transcriptStore.deleteRecord(withID: recordID) else {
                throw AppCoordinatorError.transcriptUnavailable
            }

            await reloadRecentTranscripts()
        }
    }

    func showStorageInFinder() {
        run(failureMessage: "Couldn't open the Voice Transcriber folder.") { [self] in
            NSWorkspace.shared.open(try await transcriptStore.storageDirectoryURL())
        }
    }

    func revealTranscriptFiles(recordID: String, audioOnly: Bool) {
        run(failureMessage: "Couldn't reveal the saved files.") { [self] in
            guard let record = try await transcriptStore.record(withID: recordID) else {
                throw AppCoordinatorError.transcriptUnavailable
            }

            let urls = await transcriptStore.revealableFileURLs(for: record, includeMetadata: !audioOnly)

            if urls.isEmpty {
                NSWorkspace.shared.open(try await transcriptStore.storageDirectoryURL())
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(urls)
            }
        }
    }

    private func run(failureMessage: String, _ work: @escaping @MainActor () async throws -> Void) {
        Task { [weak self] in
            do {
                try await work()
            } catch {
                self?.logger.error("\(failureMessage, privacy: .public) \(error.localizedDescription, privacy: .public)")
                self?.dictation.showFailure((error as? AppCoordinatorError)?.errorDescription ?? failureMessage)
            }
        }
    }

    private func reloadRecentTranscripts() async {
        do {
            recentTranscripts = try await transcriptStore.recentRecordings(limit: Self.recentTranscriptLimit)
        } catch {
            recentTranscripts = []
            logger.error("Failed to load transcript history: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum AppCoordinatorError: LocalizedError {
    case transcriptUnavailable

    var errorDescription: String? {
        "That transcript is no longer available."
    }
}
