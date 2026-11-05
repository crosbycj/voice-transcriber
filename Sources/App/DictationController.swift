import AVFoundation
import AppKit
import Foundation
import OSLog
import VoiceAudio
import VoiceCore
import VoiceInput
import VoiceTranscription

/// The one path a dictation takes: record, save, transcribe, paste.
///
/// The rule throughout is that audio outlives every failure. It's on disk from the first buffer and in
/// the history before transcription starts, and the transcript is saved before it's pasted, so anything
/// that goes wrong leaves a row in the menu to retry rather than losing the dictation.
@MainActor
final class DictationController {
    private enum Tuning {
        /// Keeps the microphone open after the key is released, to catch the end of the last word.
        static let stopTail: Duration = .milliseconds(200)
        /// Shorter than this is a stray tap on fn, not speech.
        static let accidentalTapSeconds = 0.35
        /// A recording this short with no speech in it isn't worth keeping.
        static let keepEmptyRecordingSeconds = 1.5
        /// fn plus another key this soon after pressing fn is a shortcut like fn+Delete.
        static let shortcutWindowSeconds = 1.0
        static let noticeDuration: Duration = .seconds(3)
        /// When to first ask the model whether anyone can be heard, and how often to ask again.
        static let firstSpeechCheck: Duration = .seconds(12)
        static let speechCheckInterval: Duration = .seconds(8)
        /// One empty decode happens on normal speech, so a warning takes this many in a row.
        static let speechMissesBeforeWarning = 2
        /// Long enough for the recorder's own retries, which take about four seconds at worst.
        static let startDeadline: Duration = .seconds(8)

        /// Transcribing runs at around 100x real time, so this only trips if something has hung.
        static func finishDeadline(forRecordingOf seconds: TimeInterval) -> Duration {
            .seconds(60 + seconds / 4)
        }
    }

    private struct ActiveRecording {
        let url: URL
        let startedAt: Date
        let deviceName: String
    }

    /// Called whenever the saved transcripts change.
    var onHistoryChanged: (() -> Void)?
    /// Supplies the microphone chosen in Settings, or nil for the system default.
    var microphoneUID: (() -> String?)?

    var isModelReady = false

    private(set) var state: HotkeySessionState = .idle {
        didSet {
            guard state == .idle, let locked = queuedStart else { return }

            // Deferred so the previous dictation can finish pasting first.
            queuedStart = nil
            Task { [weak self] in
                self?.beginRecording(locked: locked)
            }
        }
    }

    var animationPreset: RecordingBarAnimationPreset {
        get { barModel.animationPreset }
        set { barModel.animationPreset = newValue }
    }

    private let recorder: AudioRecorder
    private let engine: any TranscriptionEngine
    private let store: TranscriptStore
    private let pasteboard: PasteboardService
    private let barModel = RecordingBarModel()
    private let amplitudeService = AmplitudeService()
    private let logger = Logger(subsystem: "com.cooper.VoiceTranscriber", category: "DictationController")

    private lazy var bar = RecordingBarPanelController(
        model: barModel,
        amplitudeService: amplitudeService,
        onCancel: { [weak self] in self?.cancelRecording() },
        onStop: { [weak self] in self?.stopRecording() },
        onDismissError: { [weak self] in self?.dismissBar() }
    )

    private var activeRecording: ActiveRecording?
    private var startTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var speechCheckTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var pressedAt = Date.distantPast
    private var wantsLock = false
    /// fn went down while the last dictation was still transcribing; the value is whether to lock.
    private var queuedStart: Bool?
    /// Identifies the stop in progress, so one that blew its deadline can't take over later.
    private var finishGeneration = 0
    private var finishingRecordID: String?
    private var signalWarning: String?
    private var didWriteFail = false
    private var isMissingSpeech = false
    private var didSoundWarning = false
    private var retranscribingRecordIDs: Set<String> = []

    init(
        recorder: AudioRecorder,
        engine: any TranscriptionEngine,
        store: TranscriptStore,
        pasteboard: PasteboardService
    ) {
        self.recorder = recorder
        self.engine = engine
        self.store = store
        self.pasteboard = pasteboard

        let amplitudeService = self.amplitudeService
        recorder.onBuffer = { buffer in
            amplitudeService.process(buffer: buffer)
        }

        recorder.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
    }

    func prepare() {
        bar.prepare()

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stopRecording()
            }
        }
    }

    // MARK: - Hotkeys and menu

    func handle(_ action: VoiceHotkeyAction) {
        switch action {
        case .startHoldRecording:
            beginRecording(locked: false)
        case .stopHoldRecording:
            switch state {
            case .preparingHold:
                abandonStart()
            case .transcribing:
                queuedStart = nil
            case .idle, .recordingHold, .recordingLocked:
                stopRecording()
            }
        case .stopLockedRecording:
            stopRecording()
        case .lockCurrentRecording:
            lockRecording()
        case .functionKeyCombination:
            abandonIfShortcut()
        case .pasteVoiceClipboard:
            break
        }
    }

    func toggleFromMenu() {
        switch state {
        case .idle:
            beginRecording(locked: true)
        case .recordingHold, .preparingHold:
            lockRecording()
        case .recordingLocked:
            stopRecording()
        case .transcribing:
            break
        }
    }

    private func lockRecording() {
        switch state {
        case .preparingHold:
            wantsLock = true
        case .recordingHold:
            state = .recordingLocked
            SoundManager.shared.play(.toggleLock)
            presentRecordingBar()
        case .transcribing:
            if queuedStart != nil {
                queuedStart = true
            }
        case .idle, .recordingLocked:
            break
        }
    }

    // MARK: - Starting

    private func beginRecording(locked: Bool) {
        guard isModelReady else {
            logger.info("Ignoring recording request because the transcription model is not ready")
            return
        }

        if state == .transcribing {
            queuedStart = locked
            return
        }

        guard state == .idle else { return }

        dismissTask?.cancel()
        pressedAt = Date()
        wantsLock = locked
        signalWarning = nil
        didWriteFail = false
        isMissingSpeech = false
        didSoundWarning = false
        state = .preparingHold
        bar.present(state: .preparing)

        startTask = Task { [weak self] in
            await self?.startCapture()
        }

        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Tuning.startDeadline)) != nil else { return }
            self?.abandonStalledStart()
        }
    }

    /// A microphone that never answers mustn't leave the hotkey stuck waiting for it.
    private func abandonStalledStart() {
        guard state == .preparingHold else { return }

        logger.error("Gave up waiting for the microphone to start")
        startTask?.cancel()
        startTask = nil
        state = .idle
        showFailure("Microphone isn't responding.")
        Task { [recorder] in await recorder.cancel() }
    }

    private func startCapture() async {
        do {
            guard await Self.requestMicrophonePermission() else {
                throw DictationError.microphonePermissionDenied
            }

            try Task.checkCancellation()

            let startedAt = Date()
            let url = try await store.newRecordingURL(startedAt: startedAt)
            let deviceName = try await recorder.start(deviceUID: microphoneUID?(), to: url)

            if Task.isCancelled {
                await recorder.cancel()
                throw CancellationError()
            }

            deadlineTask?.cancel()
            startTask = nil
            activeRecording = ActiveRecording(url: url, startedAt: startedAt, deviceName: deviceName)
            state = wantsLock ? .recordingLocked : .recordingHold
            SoundManager.shared.play(.recordingStart)
            presentRecordingBar()
            amplitudeService.start()
            startSpeechCheck(of: url)
        } catch is CancellationError {
            // Already idle if the deadline gave up on this start, and its message is still showing.
            guard state == .preparingHold else { return }

            deadlineTask?.cancel()
            startTask = nil
            state = .idle
            dismissBar()
        } catch {
            logger.error("Recording start failed: \(error.localizedDescription, privacy: .public)")
            guard state == .preparingHold else { return }

            deadlineTask?.cancel()
            startTask = nil
            state = .idle
            showFailure((error as? LocalizedError)?.errorDescription ?? "Couldn't start the microphone.")
        }
    }

    /// fn was released before the microphone came up, so there's nothing to keep.
    private func abandonStart() {
        startTask?.cancel()
        dismissBar()
        Task { [recorder] in await recorder.cancel() }
    }

    private func abandonIfShortcut() {
        if state == .transcribing {
            queuedStart = nil
            return
        }

        guard Date().timeIntervalSince(pressedAt) < Tuning.shortcutWindowSeconds else { return }

        switch state {
        case .preparingHold:
            abandonStart()
        case .recordingHold:
            cancelRecording()
        case .idle, .recordingLocked, .transcribing:
            break
        }
    }

    // MARK: - Stopping

    func cancelRecording() {
        switch state {
        case .preparingHold:
            abandonStart()
        case .recordingHold, .recordingLocked:
            amplitudeService.stop()
            speechCheckTask?.cancel()
            activeRecording = nil
            state = .idle
            dismissBar()
            Task { [recorder] in await recorder.cancel() }
        case .idle, .transcribing:
            break
        }
    }

    func stopRecording() {
        guard state == .recordingHold || state == .recordingLocked else { return }

        let targetApp = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let recordedSeconds = activeRecording.map { Date().timeIntervalSince($0.startedAt) } ?? 0

        state = .transcribing
        amplitudeService.stop()
        speechCheckTask?.cancel()
        bar.present(state: .transcribing)

        finishGeneration += 1
        let generation = finishGeneration

        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            let deadline = Tuning.finishDeadline(forRecordingOf: recordedSeconds)
            guard (try? await Task.sleep(for: deadline)) != nil else { return }
            await self?.abandonFinish(generation)
        }

        finishTask = Task { [weak self] in
            await self?.finishRecording(generation, targetApp: targetApp)
            self?.deadlineTask?.cancel()
        }
    }

    /// Nothing below is allowed to leave the hotkey dead. If a stop hangs, give up on waiting for it.
    /// The audio is on disk, and the work is left running: if it does finish, the transcript is saved.
    private func abandonFinish(_ generation: Int) async {
        guard state == .transcribing, generation == finishGeneration else { return }

        logger.error("Gave up waiting for a dictation to finish")
        finishGeneration += 1
        state = .idle
        showFailure("Taking too long. Audio saved.")

        if let finishingRecordID {
            _ = try? await store.markFailed(recordID: finishingRecordID, reason: "Took too long to transcribe")
            onHistoryChanged?()
        }
    }

    /// Returns to idle unless the deadline already did, and says whether this stop is still in charge.
    private func concludeFinish(_ generation: Int) -> Bool {
        guard generation == finishGeneration else { return false }

        finishingRecordID = nil
        state = .idle
        return true
    }

    private func finishRecording(_ generation: Int, targetApp: pid_t?) async {
        guard let recording = activeRecording else {
            if concludeFinish(generation) {
                dismissBar()
            }
            return
        }

        activeRecording = nil

        let report: CaptureReport
        do {
            report = try await recorder.stop(tail: Tuning.stopTail)
        } catch {
            // The audio is still on disk, and launch recovery will pick it up.
            logger.error("Stopping failed: \(error.localizedDescription, privacy: .public)")
            if concludeFinish(generation) {
                showFailure("Recording interrupted. Audio saved.")
            }
            return
        }

        // After the microphone has closed, so the sound can't end up in the recording.
        SoundManager.shared.play(.recordingEnd)

        logger.info(
            "Recorded \(report.audioSeconds, privacy: .public)s of \(report.wallClockSeconds, privacy: .public)s on \(report.deviceName, privacy: .public), restarts=\(report.restarts, privacy: .public), worst=\(report.worstHealth.rawValue, privacy: .public)"
        )

        if report.audioSeconds < Tuning.accidentalTapSeconds {
            await store.discardAudio(at: recording.url)

            if concludeFinish(generation) {
                if report.wallClockSeconds > 2 {
                    showFailure("No sound from \(recording.deviceName).")
                } else {
                    dismissBar()
                }
            }
            return
        }

        let record: TranscriptRecord?
        do {
            record = try await store.addRecording(
                at: recording.url,
                recordedAt: recording.startedAt,
                model: engine.modelIdentifier,
                capture: report
            )
            finishingRecordID = record?.id
            onHistoryChanged?()
        } catch {
            // Keep going: the words are still worth delivering, and the audio stays on disk for recovery.
            logger.error("Couldn't save the recording: \(error.localizedDescription, privacy: .public)")
            record = nil
        }

        await transcribeAndDeliver(
            audioFile: recording.url,
            record: record,
            report: report,
            generation: generation,
            targetApp: targetApp
        )
    }

    private func transcribeAndDeliver(
        audioFile: URL,
        record: TranscriptRecord?,
        report: CaptureReport,
        generation: Int,
        targetApp: pid_t?
    ) async {
        defer { onHistoryChanged?() }

        let transcription: Transcription
        do {
            transcription = try await engine.transcribe(audioFile: audioFile)
        } catch {
            logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")

            if let record {
                _ = try? await store.markFailed(recordID: record.id, reason: error.localizedDescription)
            }

            if concludeFinish(generation) {
                showFailure("Couldn't transcribe. Audio saved.")
            }
            return
        }

        guard !transcription.text.isEmpty else {
            await handleNoSpeech(record: record, report: report, generation: generation)
            return
        }

        if let record {
            do {
                try await store.completeTranscript(
                    recordID: record.id,
                    text: transcription.text,
                    model: engine.modelIdentifier
                )
            } catch {
                // Saving failed, so delivering is now the only copy of these words.
                logger.error("Couldn't save the transcript: \(error.localizedDescription, privacy: .public)")
            }
        }

        if concludeFinish(generation) {
            deliver(transcription.text, report: report, targetApp: targetApp)
        }
    }

    private func handleNoSpeech(record: TranscriptRecord?, report: CaptureReport, generation: Int) async {
        guard let record else {
            if concludeFinish(generation) {
                dismissBar()
            }
            return
        }

        if record.durationSeconds < Tuning.keepEmptyRecordingSeconds {
            _ = try? await store.deleteRecord(withID: record.id)

            if concludeFinish(generation) {
                dismissBar()
            }
            return
        }

        let reason = "No speech heard from \(report.deviceName)"
        _ = try? await store.markFailed(recordID: record.id, reason: reason)

        if concludeFinish(generation) {
            showFailure("\(reason).")
        }
    }

    private func deliver(_ text: String, report: CaptureReport, targetApp: pid_t?) {
        do {
            // Transcribing a long dictation takes a moment, and pasting into whatever got focus since
            // would put the words in the wrong place.
            let isSameApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp
            let outcome: PasteOutcome

            if isSameApp {
                outcome = try pasteboard.paste(text)
            } else {
                try pasteboard.copyText(text)
                outcome = .copiedOnly
            }

            if report.didFailWriting {
                showFailure("Disk full. Transcript may be cut short.")
            } else if outcome == .copiedOnly {
                showNotice("Copied. Press ⌘V to paste.")
            } else {
                dismissBar()
            }
        } catch {
            logger.error("Paste failed: \(error.localizedDescription, privacy: .public)")
            showFailure("Saved, but couldn't paste. Try ⌃⌘V.")
        }
    }

    // MARK: - Microphone trouble

    private func handle(_ event: AudioRecorder.Event) {
        // Trouble while starting counts too: a dead microphone often shows itself before recording does.
        let isPreparing = state == .preparingHold
        guard isPreparing || state == .recordingHold || state == .recordingLocked else { return }

        let deviceName = activeRecording?.deviceName ?? "mic"

        switch event {
        case .healthChanged(.good):
            signalWarning = nil
        case .healthChanged(.noise):
            signalWarning = "Only static · \(deviceName)"
        case .healthChanged(.silent):
            signalWarning = "No sound · \(deviceName)"
        case .healthChanged(.noBuffers):
            signalWarning = "Reconnecting · \(deviceName)"
        case .writeFailed:
            didWriteFail = true
        }

        if currentWarning != nil {
            soundWarningOnce()
        }

        if !isPreparing {
            presentRecordingBar()
        }
    }

    /// Levels can't tell a voice from music or an empty room, but the speech model can, and it's fast.
    /// So listen to the opening of each recording until someone is heard. Knowing after a few seconds
    /// that the wrong microphone is live beats finding out after ten minutes of talking.
    private func startSpeechCheck(of url: URL) {
        speechCheckTask?.cancel()
        speechCheckTask = Task { [weak self, engine] in
            var delay = Tuning.firstSpeechCheck
            var misses = 0

            while (try? await Task.sleep(for: delay)) != nil {
                delay = Tuning.speechCheckInterval

                // A check that couldn't run says nothing either way, so just ask again.
                guard let isHeard = try? await engine.containsSpeech(audioFile: url) else { continue }
                guard !Task.isCancelled else { return }

                if isHeard {
                    self?.updateSpeechCheck(isMissing: false)
                    return
                }

                misses += 1

                if misses >= Tuning.speechMissesBeforeWarning {
                    self?.updateSpeechCheck(isMissing: true)
                }
            }
        }
    }

    private func updateSpeechCheck(isMissing: Bool) {
        guard state == .recordingHold || state == .recordingLocked else { return }

        isMissingSpeech = isMissing

        if isMissing {
            soundWarningOnce()
        }

        presentRecordingBar()
    }

    /// Someone dictating with a locked recording may not be looking at the screen.
    private func soundWarningOnce() {
        guard !didSoundWarning else { return }

        didSoundWarning = true
        SoundManager.shared.play(.error)
    }

    private var currentWarning: String? {
        if didWriteFail { return "Can't save audio. Disk full?" }
        if let signalWarning { return signalWarning }
        guard isMissingSpeech else { return nil }
        return "Not hearing you · \(activeRecording?.deviceName ?? "mic")"
    }

    // MARK: - Saved recordings

    func isRetranscribing(recordID: String) -> Bool {
        retranscribingRecordIDs.contains(recordID)
    }

    func retranscribe(recordID: String) {
        guard retranscribingRecordIDs.insert(recordID).inserted else { return }

        Task { [weak self] in
            await self?.performRetranscription(of: recordID)
            self?.retranscribingRecordIDs.remove(recordID)
            self?.onHistoryChanged?()
        }
    }

    private func performRetranscription(of recordID: String) async {
        do {
            guard let record = try await store.record(withID: recordID) else {
                showFailure("That transcript is no longer available.")
                return
            }

            if try await !transcribeSaved(record) {
                showFailure("No speech found in that recording.")
            }
        } catch {
            logger.error("Retranscription failed: \(error.localizedDescription, privacy: .public)")
            showFailure("Couldn't transcribe that recording.")
        }
    }

    /// Transcribes saved audio, keeping any earlier transcript if nothing better comes out of it.
    private func transcribeSaved(_ record: TranscriptRecord) async throws -> Bool {
        let audioFile = await store.audioFileURL(for: record)
        let transcription = try await engine.transcribe(audioFile: audioFile)

        guard !transcription.text.isEmpty else {
            try await store.markFailed(recordID: record.id, reason: "No speech found")
            return false
        }

        try await store.completeTranscript(
            recordID: record.id,
            text: transcription.text,
            model: engine.modelIdentifier
        )
        return true
    }

    /// Finds recordings a crash left unfinished. Fast, so it can run before dictation is enabled.
    func findInterruptedRecordings() async -> [TranscriptRecord] {
        do {
            return try await store.recoverInterrupted(model: engine.modelIdentifier)
        } catch {
            logger.error("Recovery failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func finishInterruptedRecordings(_ records: [TranscriptRecord]) async {
        var recovered = 0

        for record in records {
            do {
                // Cleared first, so audio that takes the app down can't do so on every launch.
                try await store.markFailed(recordID: record.id, reason: "Interrupted")

                if try await transcribeSaved(record) {
                    recovered += 1
                }
            } catch {
                logger.error("Couldn't finish \(record.audioFile, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        guard recovered > 0 else { return }

        onHistoryChanged?()
        showNotice(recovered == 1 ? "Recovered 1 dictation. See the menu." : "Recovered \(recovered) dictations. See the menu.")
    }

    // MARK: - Recording bar

    private func presentRecordingBar() {
        bar.present(state: .recording(isLocked: state == .recordingLocked, warning: currentWarning))
    }

    func showFailure(_ message: String) {
        guard state == .idle else {
            logger.error("Not shown while busy: \(message, privacy: .public)")
            return
        }

        SoundManager.shared.play(.error)
        bar.present(state: .failed(message))
        scheduleBarDismiss()
    }

    private func showNotice(_ message: String) {
        guard state == .idle else { return }

        bar.present(state: .notice(message))
        scheduleBarDismiss()
    }

    private func dismissBar() {
        dismissTask?.cancel()
        bar.dismiss()
    }

    private func scheduleBarDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            guard (try? await Task.sleep(for: Tuning.noticeDuration)) != nil else { return }
            self?.bar.dismiss()
        }
    }

    // MARK: - Permission

    private static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}

private enum DictationError: LocalizedError {
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone access is off for Voice Transcriber."
        }
    }
}
