@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import OSLog

/// What happened during a recording, kept with the transcript so failures can be diagnosed afterward.
public struct CaptureReport: Codable, Hashable, Sendable {
    public var deviceName: String
    public var inputSampleRate: Double
    public var audioSeconds: Double
    public var wallClockSeconds: Double
    /// How many times the input had to be restarted mid-recording.
    public var restarts: Int
    public var worstHealth: InputHealth
    /// The disk stopped accepting audio, so the recording ends early.
    public var didFailWriting: Bool

    public init(
        deviceName: String,
        inputSampleRate: Double,
        audioSeconds: Double,
        wallClockSeconds: Double,
        restarts: Int,
        worstHealth: InputHealth,
        didFailWriting: Bool = false
    ) {
        self.deviceName = deviceName
        self.inputSampleRate = inputSampleRate
        self.audioSeconds = audioSeconds
        self.wallClockSeconds = wallClockSeconds
        self.restarts = restarts
        self.worstHealth = worstHealth
        self.didFailWriting = didFailWriting
    }
}

/// Records one microphone to a WAV at a caller-chosen location.
///
/// A recording's job is to survive. Audio goes to its final file as it arrives, the input is rebuilt
/// whenever it reconfigures or stalls, and `onEvent` reports trouble while it can still be acted on.
/// Everything here runs on a private queue, so callers on the main thread never wait on Core Audio.
public final class AudioRecorder: @unchecked Sendable {
    public enum Event: Sendable {
        case healthChanged(InputHealth)
        case writeFailed(String)
    }

    private enum Tuning {
        static let targetSampleRate = 16_000
        static let stallThreshold: TimeInterval = 2.5
        static let watchdogInterval: TimeInterval = 0.5
        static let restartDelay: TimeInterval = 0.05
        static let restartRetryDelay: TimeInterval = 0.5
        static let startAttempts = 3
        static let startRetryDelay: TimeInterval = 0.2
        static let firstAudioTimeout: TimeInterval = 3
        /// A canceled recording at least this long goes to the Trash, in case the ✕ was a misclick.
        static let trashCanceledSeconds = 5.0
    }

    /// Only touched on `queue`.
    private final class Session: @unchecked Sendable {
        let writer: WAVFileWriter
        let requestedDeviceUID: String?
        let startedAt = Date()
        var device: InputDevice
        var inputSampleRate: Double = 0
        var lastBufferAt = Date()
        var generation = 0
        var restarts = 0
        var isRestarting = false
        var isStopping = false
        var didFailWriting = false
        var didRestartForSilence = false
        var converter: AVAudioConverter?
        var monitor = SignalMonitor()
        var health = InputHealth.good
        var worstHealth = InputHealth.good
        var watchdog: DispatchSourceTimer?
        /// Held until audio is really arriving.
        var pendingStart: CheckedContinuation<String, Error>?

        init(writer: WAVFileWriter, requestedDeviceUID: String?, device: InputDevice) {
            self.writer = writer
            self.requestedDeviceUID = requestedDeviceUID
            self.device = device
        }
    }

    /// Set both of these before the first recording.
    public var onEvent: (@Sendable (Event) -> Void)?
    public var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

    private let source: CaptureSource
    private let resolveDevice: @Sendable (String?) throws -> InputDevice
    private let targetFormat: AVAudioFormat
    private let queue = DispatchQueue(label: "com.cooper.VoiceTranscriber.audio-recorder")
    private let logger = Logger(subsystem: "com.cooper.VoiceTranscriber", category: "AudioRecorder")
    private var session: Session?

    public convenience init(deviceManager: AudioDeviceManager) {
        self.init(source: EngineCaptureSource()) { uid in
            try deviceManager.resolveInput(uid: uid)
        }
    }

    public init(
        source: CaptureSource,
        resolveDevice: @escaping @Sendable (String?) throws -> InputDevice
    ) {
        self.source = source
        self.resolveDevice = resolveDevice
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(Tuning.targetSampleRate),
            channels: 1,
            interleaved: true
        )!
    }

    /// Starts recording to `url` and returns the name of the microphone in use.
    ///
    /// Returns once audio is actually arriving, not when the input claims to have started. A freshly
    /// started engine sometimes dies before delivering anything, and whatever cue the caller gives
    /// should mean the microphone is really listening.
    public func start(deviceUID: String?, to url: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    let session = try beginSession(deviceUID: deviceUID, url: url)
                    session.pendingStart = continuation

                    queue.asyncAfter(deadline: .now() + Tuning.firstAudioTimeout) { [self] in
                        guard session.pendingStart != nil else { return }

                        // Carry on regardless. The recording keeps trying, and `onEvent` has the caller warn.
                        update(.noBuffers, for: session)
                        resolveStart(of: session)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func beginSession(deviceUID: String?, url: URL) throws -> Session {
        guard session == nil else {
            throw AudioRecorderError.alreadyRecording
        }

        let device = try resolveDevice(deviceUID)
        let writer = try WAVFileWriter(url: url, sampleRate: Tuning.targetSampleRate)
        let session = Session(writer: writer, requestedDeviceUID: deviceUID, device: device)

        do {
            self.session = session
            try startSourceRetrying(for: session)
        } catch {
            self.session = nil
            writer.abandon()
            try? FileManager.default.removeItem(at: url)
            throw AudioRecorderError.failedToStart(error.localizedDescription)
        }

        startWatchdog(for: session)
        logger.info("Recording from \(device.name, privacy: .public) at \(session.inputSampleRate, privacy: .public) Hz")
        return session
    }

    private func resolveStart(of session: Session) {
        session.pendingStart?.resume(returning: session.device.name)
        session.pendingStart = nil
    }

    /// Keeps capturing for `tail`, then finalizes the file. Speech often runs right up to the moment
    /// a key is released, and the last buffers are still in flight when it happens.
    public func stop(tail: Duration = .milliseconds(200)) async throws -> CaptureReport {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let session, !session.isStopping else {
                    continuation.resume(throwing: AudioRecorderError.notRecording)
                    return
                }

                session.isStopping = true
                session.watchdog?.cancel()

                queue.asyncAfter(deadline: .now() + tail.timeInterval) { [self] in
                    source.stop()

                    // Queued behind any buffers the tap has already handed over.
                    queue.async { [self] in
                        continuation.resume(with: Result { try finish(session) })
                    }
                }
            }
        }
    }

    /// Stops and discards the recording. Anything long enough to regret goes to the Trash.
    public func cancel() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                defer { continuation.resume() }

                guard let session else { return }

                self.session = nil
                session.watchdog?.cancel()
                source.stop()
                session.pendingStart?.resume(throwing: CancellationError())
                session.pendingStart = nil

                let seconds = Double(session.writer.frameCount) / Double(Tuning.targetSampleRate)

                do {
                    if seconds >= Tuning.trashCanceledSeconds {
                        try session.writer.finish()
                        try FileManager.default.trashItem(at: session.writer.url, resultingItemURL: nil)
                    } else {
                        session.writer.abandon()
                        try FileManager.default.removeItem(at: session.writer.url)
                    }
                } catch {
                    logger.error("Couldn't delete the canceled recording: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Input lifecycle (on queue)

    /// A device that's just waking up can briefly report no format, so give it a moment.
    private func startSourceRetrying(for session: Session) throws {
        for attempt in 1...Tuning.startAttempts {
            do {
                try startSource(for: session)
                return
            } catch where attempt < Tuning.startAttempts {
                logger.notice("Input wasn't ready: \(error.localizedDescription, privacy: .public)")
                Thread.sleep(forTimeInterval: Tuning.startRetryDelay)
            }
        }
    }

    private func startSource(for session: Session) throws {
        session.generation += 1
        let generation = session.generation

        try source.start(
            deviceID: session.device.id,
            onBuffer: { [weak self] buffer in
                guard let self else { return }
                self.onBuffer?(buffer)
                self.queue.async { self.write(buffer) }
            },
            onInterruption: { [weak self] in
                guard let self else { return }
                self.queue.async { self.handleInterruption(generation: generation) }
            }
        )

        session.inputSampleRate = source.inputSampleRate
        session.lastBufferAt = Date()
    }

    private func handleInterruption(generation: Int) {
        guard let session, session.generation == generation, !session.isStopping, !source.isDelivering else {
            return
        }

        logger.notice("Audio input stopped mid-recording; restarting it")
        restartInput(for: session)
    }

    private func restartInput(for session: Session) {
        guard !session.isRestarting else { return }

        session.isRestarting = true
        source.stop()
        scheduleRestartAttempt(for: session, after: Tuning.restartDelay)
    }

    private func scheduleRestartAttempt(for session: Session, after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            guard self.session === session, !session.isStopping else { return }

            do {
                // The device may be gone, or have a new ID, so resolve it again every time.
                session.device = try resolveDevice(session.requestedDeviceUID)
                try startSource(for: session)
                session.isRestarting = false
                session.restarts += 1
                logger.notice("Audio input restarted on \(session.device.name, privacy: .public) (restart \(session.restarts, privacy: .public))")
            } catch {
                logger.error("Audio input restart failed: \(error.localizedDescription, privacy: .public)")
                update(.noBuffers, for: session)
                scheduleRestartAttempt(for: session, after: Tuning.restartRetryDelay)
            }
        }
    }

    private func startWatchdog(for session: Session) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Tuning.watchdogInterval, repeating: Tuning.watchdogInterval)
        timer.setEventHandler { [weak self, weak session] in
            guard let self, let session else { return }
            self.checkForStall(in: session)
        }
        timer.resume()
        session.watchdog = timer
    }

    private func checkForStall(in session: Session) {
        guard
            self.session === session,
            !session.isStopping,
            !session.isRestarting,
            Date().timeIntervalSince(session.lastBufferAt) > Tuning.stallThreshold
        else {
            return
        }

        logger.notice("Audio input stalled; restarting it")
        update(.noBuffers, for: session)
        restartInput(for: session)
    }

    private func update(_ health: InputHealth, for session: Session) {
        guard health != session.health else { return }

        let previous = session.health
        session.health = health
        session.worstHealth = max(session.worstHealth, health)
        onEvent?(.healthChanged(health))

        // Exact zeros can mean the input is wedged, so try a restart. Once is enough: a noise-gated
        // input goes silent at every pause, and a restart there would cost real audio.
        if health == .silent, previous != .noBuffers, !session.isStopping, !session.didRestartForSilence {
            session.didRestartForSilence = true
            restartInput(for: session)
        }
    }

    // MARK: - Writing (on queue)

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let session else { return }

        // Before anything else: buffers arriving means the input is fine, even if the disk isn't.
        session.lastBufferAt = Date()

        guard !session.didFailWriting, let converted = convert(buffer, in: session) else { return }
        append(converted, in: session)
    }

    /// Returns 16 kHz mono audio. A conversion failure loses this one buffer, never the recording.
    private func convert(_ buffer: AVAudioPCMBuffer, in session: Session) -> AVAudioPCMBuffer? {
        if let existing = session.converter, !existing.inputFormat.isEqual(buffer.format) {
            drainConverter(in: session)
        }

        if session.converter == nil {
            session.converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            session.converter?.downmix = buffer.format.channelCount > 1
        }

        guard
            let converter = session.converter,
            let output = makeOutputBuffer(for: buffer.frameLength, from: buffer.format.sampleRate)
        else {
            logger.error("Couldn't convert audio from \(buffer.format.description, privacy: .public)")
            return nil
        }

        let input = PendingInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            guard let buffer = input.take() else {
                inputStatus.pointee = .noDataNow
                return nil
            }

            inputStatus.pointee = .haveData
            return buffer
        }

        guard status != .error, conversionError == nil else {
            logger.error("Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
            session.converter = nil
            return nil
        }

        return output
    }

    /// Writes out what the resampler is still holding, so the very end of the audio isn't lost.
    private func drainConverter(in session: Session) {
        guard
            let converter = session.converter,
            let output = makeOutputBuffer(for: 4_096, from: converter.inputFormat.sampleRate)
        else {
            session.converter = nil
            return
        }

        session.converter = nil

        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }

        if status != .error, conversionError == nil {
            append(output, in: session)
        }
    }

    private func makeOutputBuffer(for inputFrames: AVAudioFrameCount, from sampleRate: Double) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / sampleRate
        let capacity = AVAudioFrameCount(Double(inputFrames) * ratio) + 64
        return AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
    }

    private func append(_ buffer: AVAudioPCMBuffer, in session: Session) {
        guard buffer.frameLength > 0, let channel = buffer.int16ChannelData?[0] else { return }

        let samples = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))

        do {
            try session.writer.append(samples)
        } catch {
            // The disk is the one failure a retry can't help. Everything written so far stays intact.
            logger.error("Couldn't write audio: \(error.localizedDescription, privacy: .public)")
            session.didFailWriting = true
            onEvent?(.writeFailed(error.localizedDescription))
            return
        }

        resolveStart(of: session)

        let change = session.monitor.process(samples)

        // Buffers arriving at all clears a stall, even when the signal itself hasn't changed.
        if change != nil || session.health == .noBuffers {
            update(session.monitor.health, for: session)
        }
    }

    private func finish(_ session: Session) throws -> CaptureReport {
        guard self.session === session else {
            throw AudioRecorderError.notRecording
        }

        self.session = nil

        if !session.didFailWriting {
            drainConverter(in: session)
        }

        try session.writer.finish()

        return CaptureReport(
            deviceName: session.device.name,
            inputSampleRate: session.inputSampleRate,
            audioSeconds: Double(session.writer.frameCount) / Double(Tuning.targetSampleRate),
            wallClockSeconds: Date().timeIntervalSince(session.startedAt),
            restarts: session.restarts,
            worstHealth: session.worstHealth,
            didFailWriting: session.didFailWriting
        )
    }
}

public enum AudioRecorderError: LocalizedError {
    case alreadyRecording
    case notRecording
    case failedToStart(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "Recording is already in progress."
        case .notRecording:
            return "Recording is not in progress."
        case .failedToStart(let message):
            return "Couldn't start the microphone: \(message)"
        }
    }
}

/// Hands the converter one buffer, once. The converter calls back synchronously on the same thread.
private final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
