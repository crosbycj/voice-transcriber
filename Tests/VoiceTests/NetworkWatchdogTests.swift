import FluidAudio
import Foundation
import Testing
@testable import VoiceTranscription

@Suite struct NetworkWatchdogTests {
    private let limit: Duration = .milliseconds(200)

    /// Records whether the operation saw its cancellation.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    @Test func aServerThatNeverAnswersFailsWithinTheLimit() async throws {
        let cancelled = Flag()
        let started = ContinuousClock.now

        await #expect(throws: NetworkWatchdog.Silence.self) {
            try await NetworkWatchdog.run(limit: limit) { report in
                report(.network(progress: 0))
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.set()
                    throw error
                }
            }
        }

        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(cancelled.isSet, "the stalled download must be stopped, not left running")
    }

    @Test func aSlowDownloadThatKeepsReportingFinishes() async throws {
        let result = try await NetworkWatchdog.run(limit: limit) { report in
            for _ in 0..<10 {
                report(.network(progress: 0))
                try await Task.sleep(for: .milliseconds(80))
            }
            return "done"
        }

        #expect(result == "done")
    }

    @Test func longLocalWorkIsNotAStall() async throws {
        let result = try await NetworkWatchdog.run(limit: limit) { report in
            report(.network(progress: 0))
            report(.local)
            try await Task.sleep(for: .milliseconds(700))
            return 7
        }

        #expect(result == 7)
    }

    @Test func nothingCountsBeforeTheNetworkIsUsed() async throws {
        let result = try await NetworkWatchdog.run(limit: limit) { _ in
            try await Task.sleep(for: .milliseconds(600))
            return true
        }

        #expect(result)
    }

    @Test func aStallAfterLocalWorkStillCounts() async throws {
        await #expect(throws: NetworkWatchdog.Silence.self) {
            try await NetworkWatchdog.run(limit: limit) { report in
                report(.local)
                try await Task.sleep(for: .milliseconds(300))
                report(.network(progress: 0))
                try await Task.sleep(for: .seconds(30))
            }
        }
    }

    @Test func cancellingTheCallerStopsTheOperation() async throws {
        let cancelled = Flag()
        let started = ContinuousClock.now

        let task = Task {
            try await NetworkWatchdog.run(limit: .seconds(60)) { report in
                report(.network(progress: 0))
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.set()
                    throw error
                }
            }
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(cancelled.isSet)
    }

    /// Counts attempts and reports a different amount of progress on each.
    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func next() -> Int { lock.withLock { count += 1; return count } }
        var total: Int { lock.withLock { count } }
    }

    @Test func aDownloadThatFrozePartwayIsResumed() async throws {
        let attempts = Attempts()

        let result = try await NetworkWatchdog.run(limit: limit, attempts: 5) { report in
            let attempt = attempts.next()
            report(.network(progress: Double(attempt) * 0.2))
            if attempt < 3 {
                try await Task.sleep(for: .seconds(30))
            }
            return attempt
        }

        #expect(result == 3)
    }

    @Test func retryingStopsOnceAnAttemptGetsNowhere() async throws {
        let attempts = Attempts()

        await #expect(throws: NetworkWatchdog.Silence.self) {
            try await NetworkWatchdog.run(limit: limit, attempts: 5) { report in
                // Gets to 30% and freezes, then every try after freezes at the same point.
                _ = attempts.next()
                report(.network(progress: 0.3))
                try await Task.sleep(for: .seconds(30))
            }
        }

        #expect(attempts.total == 2)
    }

    @Test func aServerThatNeverAnswersIsNotRetried() async throws {
        let attempts = Attempts()

        await #expect(throws: NetworkWatchdog.Silence.self) {
            try await NetworkWatchdog.run(limit: limit, attempts: 5) { report in
                _ = attempts.next()
                report(.network(progress: 0))
                try await Task.sleep(for: .seconds(30))
            }
        }

        #expect(attempts.total == 1)
    }

    @Test func retryingIsBounded() async throws {
        let attempts = Attempts()

        await #expect(throws: NetworkWatchdog.Silence.self) {
            try await NetworkWatchdog.run(limit: limit, attempts: 3) { report in
                report(.network(progress: Double(attempts.next()) * 0.1))
                try await Task.sleep(for: .seconds(30))
            }
        }

        #expect(attempts.total == 3)
    }

    @Test func operationErrorsPassThrough() async throws {
        struct Broken: Error {}

        await #expect(throws: Broken.self) {
            try await NetworkWatchdog.run(limit: limit) { _ in throw Broken() }
        }
    }

    // MARK: Network failures

    @Test(arguments: [URLError.Code.notConnectedToInternet, .cannotConnectToHost, .timedOut, .cannotFindHost])
    func networkErrorsAreRecognised(code: URLError.Code) {
        #expect(ParakeetTranscriptionEngine.isNetworkFailure(URLError(code)))
    }

    @Test func networkErrorsWrappedByFluidAudioAreRecognised() {
        let wrapped = DownloadError.downloadFailed(path: "Encoder.mlmodelc", underlying: URLError(.networkConnectionLost))
        #expect(ParakeetTranscriptionEngine.isNetworkFailure(wrapped))
        #expect(ParakeetTranscriptionEngine.isNetworkFailure(DownloadError.stalled(path: "x", window: 120)))
    }

    @Test func otherErrorsAreNotNetworkFailures() {
        #expect(!ParakeetTranscriptionEngine.isNetworkFailure(URLError(.cancelled)))
        #expect(!ParakeetTranscriptionEngine.isNetworkFailure(DownloadError.modelNotFound(path: "x")))
        #expect(!ParakeetTranscriptionEngine.isNetworkFailure(CocoaError(.fileWriteOutOfSpace)))
    }

    // MARK: Progress shown while preparing the model

    private func shown(_ fraction: Double, _ phase: DownloadPhase) -> TranscriptionModelPreparationProgress {
        ParakeetTranscriptionEngine.preparationProgress(from: DownloadProgress(fractionCompleted: fraction, phase: phase))
    }

    @Test func theDownloadFillsTheWholeBar() {
        #expect(shown(0, .listing) == .checking)
        #expect(shown(0.25, .downloading(completedFiles: 6, totalFiles: 23)) == .downloading(fractionCompleted: 0.5))
        #expect(shown(0.5, .downloading(completedFiles: 23, totalFiles: 23)) == .downloading(fractionCompleted: 1))
    }

    /// FluidAudio's raw numbers sat at 50% here, then jumped between 50% and 100% for each part.
    @Test func compilingAndItsCachedPartsAllReadAsPreparing() {
        #expect(shown(0.5, .compiling(modelName: "Encoder.mlmodelc")) == .preparing)
        #expect(shown(1, .compiling(modelName: "")) == .preparing)
        #expect(shown(0.5, .downloading(completedFiles: 0, totalFiles: 0)) == .preparing)
    }
}
