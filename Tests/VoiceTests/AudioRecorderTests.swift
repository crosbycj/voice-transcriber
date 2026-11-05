@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import VoiceAudio

/// Stands in for the microphone, so tests can make it misbehave the way real inputs do.
private final class FakeSource: CaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var bufferHandler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var interruptionHandler: (@Sendable () -> Void)?
    private var starts = 0
    private var failuresRemaining = 0

    var inputSampleRate: Double { 48_000 }

    var isDelivering: Bool {
        isRunning
    }

    var startCount: Int {
        lock.withLock { starts }
    }

    var isRunning: Bool {
        lock.withLock { bufferHandler != nil }
    }

    func failNextStarts(_ count: Int) {
        lock.withLock { failuresRemaining = count }
    }

    func start(
        deviceID: AudioDeviceID,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onInterruption: @escaping @Sendable () -> Void
    ) throws {
        try lock.withLock {
            starts += 1

            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw CaptureSourceError.inputNotReady
            }

            bufferHandler = onBuffer
            interruptionHandler = onInterruption
        }
    }

    func stop() {
        lock.withLock {
            bufferHandler = nil
            interruptionHandler = nil
        }
    }

    func emit(seconds: Double, sampleRate: Double = 48_000, channels: AVAudioChannelCount = 1, silent: Bool = false) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames

        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = silent ? 0 : sinf(Float(frame) * 0.05) * 0.2
            }
        }

        lock.withLock { bufferHandler }?(buffer)
    }

    /// Core Audio reporting a configuration change on an input that carries on working.
    func reportHarmlessChange() {
        lock.withLock { interruptionHandler }?()
    }

    /// What `AVAudioEngineConfigurationChange` does when it matters: the engine stops and nothing more arrives.
    func interrupt() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            bufferHandler = nil
            return interruptionHandler
        }
        handler?()
    }
}

private func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout

    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            return
        }

        try await Task.sleep(for: .milliseconds(20))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var healths: [InputHealth] = []

    func add(_ event: AudioRecorder.Event) {
        if case .healthChanged(let health) = event {
            lock.withLock { healths.append(health) }
        }
    }

    var all: [InputHealth] {
        lock.withLock { healths }
    }
}

@Suite struct AudioRecorderTests {
    private func makeRecorder() -> (AudioRecorder, FakeSource, URL) {
        let source = FakeSource()
        let recorder = AudioRecorder(source: source) { _ in InputDevice(id: 1, name: "Test Mic") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-\(UUID().uuidString).wav")
        return (recorder, source, url)
    }

    private func frames(in url: URL) throws -> Int64 {
        try AVAudioFile(forReading: url).length
    }

    /// Starts recording and supplies the first audio, without which `start` doesn't return.
    private func begin(_ recorder: AudioRecorder, _ source: FakeSource, to url: URL) async throws -> String {
        async let name = recorder.start(deviceUID: nil, to: url)
        try await waitUntil { source.isRunning }
        source.emit(seconds: 0.02)
        return try await name
    }

    @Test func recordsConvertedAudioToTheRequestedFile() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        let name = try await begin(recorder, source, to: url)
        #expect(name == "Test Mic")

        source.emit(seconds: 1)
        let report = try await recorder.stop(tail: .zero)

        #expect(abs(report.audioSeconds - 1) < 0.05)
        #expect(abs(Double(try frames(in: url)) - 16_000) < 800)
        #expect(report.deviceName == "Test Mic")
        #expect(report.restarts == 0)
        #expect(!source.isRunning)
    }

    @Test func audioArrivingDuringTheTailIsKept() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await begin(recorder, source, to: url)
        source.emit(seconds: 0.5)

        async let report = recorder.stop(tail: .milliseconds(300))
        try await Task.sleep(for: .milliseconds(100))
        source.emit(seconds: 0.5)

        #expect(abs(try await report.audioSeconds - 1) < 0.05)
    }

    @Test func recordingSurvivesTheInputReconfiguring() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await begin(recorder, source, to: url)
        source.emit(seconds: 1)

        source.interrupt()
        try await waitUntil { source.startCount == 2 && source.isRunning }

        source.emit(seconds: 1)
        let report = try await recorder.stop(tail: .zero)

        #expect(report.restarts == 1)
        #expect(abs(report.audioSeconds - 2) < 0.1)
    }

    @Test func aHarmlessConfigurationChangeDoesNotInterruptRecording() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await begin(recorder, source, to: url)
        source.emit(seconds: 0.5)
        source.reportHarmlessChange()
        try await Task.sleep(for: .milliseconds(400))
        source.emit(seconds: 0.5)
        let report = try await recorder.stop(tail: .zero)

        #expect(source.startCount == 1)
        #expect(report.restarts == 0)
    }

    @Test func aSlowToWakeInputIsGivenAFewChancesToStart() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        source.failNextStarts(2)
        _ = try await begin(recorder, source, to: url)
        source.emit(seconds: 0.5)
        let report = try await recorder.stop(tail: .zero)

        #expect(source.startCount == 3)
        #expect(report.audioSeconds > 0.4)
    }

    @Test func anInputThatNeverStartsFailsAndLeavesNothingBehind() async throws {
        let (recorder, source, url) = makeRecorder()

        source.failNextStarts(10)

        await #expect(throws: AudioRecorderError.self) {
            _ = try await recorder.start(deviceUID: nil, to: url)
        }

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func recordingSurvivesASampleRateChangeBetweenBuffers() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await begin(recorder, source, to: url)
        source.emit(seconds: 1, sampleRate: 48_000)
        source.emit(seconds: 1, sampleRate: 24_000)
        source.emit(seconds: 1, sampleRate: 44_100, channels: 2)
        let report = try await recorder.stop(tail: .zero)

        #expect(abs(report.audioSeconds - 3) < 0.1)
    }

    @Test func keepsRetryingWhileTheInputIsUnavailable() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await begin(recorder, source, to: url)
        source.emit(seconds: 0.5)

        source.failNextStarts(2)
        source.interrupt()
        try await waitUntil { source.isRunning }

        source.emit(seconds: 0.5)
        let report = try await recorder.stop(tail: .zero)

        #expect(source.startCount == 4)
        #expect(report.restarts == 1)
        #expect(abs(report.audioSeconds - 1) < 0.1)
    }

    @Test func aStalledInputIsRestartedAndReported() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = EventLog()
        recorder.onEvent = { log.add($0) }

        _ = try await begin(recorder, source, to: url)
        source.emit(seconds: 0.2)

        // Running, but nothing arrives: no interruption is ever signaled.
        try await waitUntil(timeout: .seconds(6)) { source.startCount >= 2 }
        #expect(log.all.contains(.noBuffers))

        source.emit(seconds: 0.2)
        try await waitUntil { log.all.last == .good }

        let report = try await recorder.stop(tail: .zero)
        #expect(report.worstHealth == .noBuffers)
    }

    @Test func startWaitsForRealAudio() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        let returned = Flag()
        let start = Task {
            let name = try await recorder.start(deviceUID: nil, to: url)
            returned.set()
            return name
        }

        try await waitUntil { source.isRunning }
        try await Task.sleep(for: .milliseconds(150))
        #expect(!returned.isSet)

        source.emit(seconds: 0.1)
        #expect(try await start.value == "Test Mic")
        _ = try await recorder.stop(tail: .zero)
    }

    @Test func anEngineThatDiesBeforeDeliveringAnythingIsRestartedDuringStart() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        let start = Task { try await recorder.start(deviceUID: nil, to: url) }

        // The real failure: start reports success, then the engine stops with nothing delivered.
        try await waitUntil { source.isRunning }
        source.interrupt()
        try await waitUntil { source.startCount == 2 && source.isRunning }
        source.emit(seconds: 0.5)

        #expect(try await start.value == "Test Mic")
        let report = try await recorder.stop(tail: .zero)
        #expect(report.restarts == 1)
    }

    @Test func startGivesUpWaitingEventuallySoTheCallerCanWarn() async throws {
        let (recorder, _, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        let log = EventLog()
        recorder.onEvent = { log.add($0) }

        // Nothing ever arrives.
        _ = try await recorder.start(deviceUID: nil, to: url)
        #expect(log.all.contains(.noBuffers))

        let report = try await recorder.stop(tail: .zero)
        #expect(report.audioSeconds == 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancelingWhileWaitingForAudioEndsTheStart() async throws {
        let (recorder, source, url) = makeRecorder()

        let start = Task { try await recorder.start(deviceUID: nil, to: url) }
        try await waitUntil { source.isRunning }
        await recorder.cancel()

        await #expect(throws: CancellationError.self) { _ = try await start.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func cancelDeletesTheFile() async throws {
        let (recorder, source, url) = makeRecorder()

        _ = try await begin(recorder, source, to: url)
        source.emit(seconds: 0.5)
        await recorder.cancel()

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!source.isRunning)
    }

    @Test func aSilentInputIsRestartedOnlyOnce() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await begin(recorder, source, to: url)

        // A noise-gated input: exact zeros between bursts of sound.
        for _ in 0..<3 {
            source.emit(seconds: 3, silent: true)
            try await waitUntil { source.isRunning }
            try await Task.sleep(for: .milliseconds(150))
            source.emit(seconds: 1)
        }

        let report = try await recorder.stop(tail: .zero)
        #expect(report.restarts == 1)
    }

    @Test func audioIsOnDiskBeforeStopIsEverCalled() async throws {
        let (recorder, source, url) = makeRecorder()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await begin(recorder, source, to: url)
        source.emit(seconds: 2)

        try await waitUntil {
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0) > 60_000
        }

        // Simulates a crash: no stop, and the file is repaired on the next launch.
        #expect(try WAVFileWriter.repair(at: url) > 30_000)
        await recorder.cancel()
    }

    @Test func aSecondStartIsRefusedAndTheFirstRecordingContinues() async throws {
        let (recorder, source, url) = makeRecorder()
        let otherURL = FileManager.default.temporaryDirectory.appendingPathComponent("other-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await begin(recorder, source, to: url)

        await #expect(throws: AudioRecorderError.self) {
            _ = try await recorder.start(deviceUID: nil, to: otherURL)
        }

        source.emit(seconds: 0.5)
        let report = try await recorder.stop(tail: .zero)
        #expect(report.audioSeconds > 0.4)
    }
}
