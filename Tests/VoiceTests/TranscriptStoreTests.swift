import Foundation
import Testing
import VoiceAudio
@testable import VoiceCore

@Suite struct TranscriptStoreTests {
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("store-test-\(UUID().uuidString)", isDirectory: true)

    private func writeAudio(to url: URL, frames: Int = 16_000, finish: Bool = true) throws {
        let writer = try WAVFileWriter(url: url, sampleRate: 16_000)
        try [Int16](repeating: 100, count: frames).withUnsafeBufferPointer { try writer.append($0) }

        if finish {
            try writer.finish()
        } else {
            writer.abandon()
        }
    }

    private func ageFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-60)],
            ofItemAtPath: url.path
        )
    }

    private func report() -> CaptureReport {
        CaptureReport(
            deviceName: "Mic",
            inputSampleRate: 48_000,
            audioSeconds: 1,
            wallClockSeconds: 1.2,
            restarts: 1,
            worstHealth: .noise
        )
    }

    private var historyURL: URL { directory.appendingPathComponent("history.json") }

    @Test func aRecordingIsDurableBeforeItHasATranscript() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url)

        let record = try await store.addRecording(at: url, recordedAt: Date(), model: "m", capture: report())

        #expect(record.needsTranscription)
        #expect(!record.isFailure)
        #expect(abs(record.durationSeconds - 1) < 0.01)

        // A fresh store, as after a crash, finds it waiting.
        let reopened = TranscriptStore(baseDirectory: directory)
        let pending = try await reopened.recoverInterrupted(model: "m")
        #expect(pending.map(\.id) == [record.id])
        #expect(pending.first?.capture?.deviceName == "Mic")
    }

    @Test func completingATranscriptClearsPending() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url)
        let record = try await store.addRecording(at: url, recordedAt: Date(), model: "m", capture: nil)

        try await store.completeTranscript(recordID: record.id, text: "Hello there.", model: "m")

        #expect(try await store.latestTranscriptText() == "Hello there.")
        #expect(try await store.recoverInterrupted(model: "m").isEmpty)
    }

    @Test func recordingsInterruptedBeforeStopAreRecovered() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())

        // Crashed mid-recording: never finalized, never in the history.
        try writeAudio(to: url, frames: 40_000, finish: false)
        try ageFile(at: url)

        let pending = try await store.recoverInterrupted(model: "m")

        #expect(pending.count == 1)
        #expect(pending.first?.audioFile == url.lastPathComponent)
        #expect(abs((pending.first?.durationSeconds ?? 0) - 2.5) < 0.01)
    }

    @Test func recoveryLeavesARecordingInProgressAlone() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url, finish: false)

        #expect(try await store.recoverInterrupted(model: "m").isEmpty)
    }

    @Test func emptyInterruptedFilesAreCleanedUp() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url, frames: 0, finish: false)
        try ageFile(at: url)

        #expect(try await store.recoverInterrupted(model: "m").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func oldRecordsStillDecode() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = """
        [{"audioFile":"a.wav","durationSeconds":3.5,"id":"one","model":"m","text":"Old text","timestamp":"2026-08-21T10:00:00Z"},
         {"audioFile":"b.wav","durationSeconds":1.5,"id":"two","model":"m","timestamp":"2026-08-21T11:00:00Z"}]
        """
        try Data(legacy.utf8).write(to: historyURL)

        let store = TranscriptStore(baseDirectory: directory)
        let recent = try await store.recentRecordings(limit: 5)

        #expect(recent.map(\.id) == ["two", "one"])
        #expect(recent[0].isFailure)
        #expect(!recent[0].needsTranscription)
        #expect(recent[1].usableText == "Old text")
    }

    @Test func aDamagedHistoryIsRebuiltFromSidecarsAndBackedUp() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url)
        let record = try await store.addRecording(at: url, recordedAt: Date(), model: "m", capture: nil)
        try await store.completeTranscript(recordID: record.id, text: "Saved words.", model: "m")

        try Data("{ not json".utf8).write(to: historyURL)

        let reopened = TranscriptStore(baseDirectory: directory)
        #expect(try await reopened.latestTranscriptText() == "Saved words.")

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(names.contains { $0.hasPrefix("history.damaged-") })
    }

    @Test func aMissingHistoryIsRebuiltFromSidecars() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url)
        let record = try await store.addRecording(at: url, recordedAt: Date(), model: "m", capture: nil)
        try await store.completeTranscript(recordID: record.id, text: "Saved words.", model: "m")

        try FileManager.default.removeItem(at: historyURL)

        let reopened = TranscriptStore(baseDirectory: directory)
        #expect(try await reopened.latestTranscriptText() == "Saved words.")
    }

    @Test func anEmptiedHistoryIsRebuiltFromSidecars() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url)
        let record = try await store.addRecording(at: url, recordedAt: Date(), model: "m", capture: nil)
        try await store.completeTranscript(recordID: record.id, text: "Saved words.", model: "m")

        try Data().write(to: historyURL)

        let reopened = TranscriptStore(baseDirectory: directory)
        #expect(try await reopened.latestTranscriptText() == "Saved words.")
    }

    @Test func recoveryNeverOverwritesASidecarThatAlreadyHasATranscript() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url)
        let record = try await store.addRecording(at: url, recordedAt: Date(), model: "m", capture: report())
        try await store.completeTranscript(recordID: record.id, text: "Saved words.", model: "m")

        // History has a different record, so this recording looks unreferenced.
        let otherURL = try await store.newRecordingURL(startedAt: Date().addingTimeInterval(5))
        try writeAudio(to: otherURL)
        let other = try await store.addRecording(at: otherURL, recordedAt: Date(), model: "m", capture: nil)
        try await store.completeTranscript(recordID: other.id, text: "Other.", model: "m")

        let data = try Data(contentsOf: historyURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let kept = try decoder.decode([TranscriptRecord].self, from: data).filter { $0.id == other.id }
        try encoder.encode(kept).write(to: historyURL)
        try ageFile(at: url)

        let reopened = TranscriptStore(baseDirectory: directory)
        #expect(try await reopened.recoverInterrupted(model: "m").isEmpty)

        let restored = try await reopened.record(withID: record.id)
        #expect(restored?.usableText == "Saved words.")
        #expect(restored?.capture?.deviceName == "Mic")
    }

    @Test func aRecoveredRecordingKeepsItsOriginalDate() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url, finish: false)
        try ageFile(at: url)

        let recovered = try await store.recoverInterrupted(model: "m")
        #expect(try #require(recovered.first).timestamp < Date().addingTimeInterval(-30))
    }

    @Test func failingARetryKeepsTheEarlierTranscript() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url)
        let record = try await store.addRecording(at: url, recordedAt: Date(), model: "m", capture: nil)
        try await store.completeTranscript(recordID: record.id, text: "Good words.", model: "m")

        let updated = try await store.markFailed(recordID: record.id, reason: "No speech")

        #expect(updated?.usableText == "Good words.")
        #expect(updated?.failureReason == "No speech")
    }

    @Test func recordingNamesDoNotCollide() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let date = Date()

        let first = try await store.newRecordingURL(startedAt: date)
        try writeAudio(to: first)
        let second = try await store.newRecordingURL(startedAt: date)

        #expect(first != second)
    }

    @Test func deletingRemovesEverything() async throws {
        let store = TranscriptStore(baseDirectory: directory)
        let url = try await store.newRecordingURL(startedAt: Date())
        try writeAudio(to: url)
        let record = try await store.addRecording(at: url, recordedAt: Date(), model: "m", capture: nil)

        #expect(try await store.deleteRecord(withID: record.id))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await store.record(withID: record.id) == nil)
    }

    @Test func historyWrittenByAnotherCopyOfTheAppIsPickedUp() async throws {
        let first = TranscriptStore(baseDirectory: directory)
        let second = TranscriptStore(baseDirectory: directory)
        #expect(try await first.recentRecordings(limit: 5).isEmpty)

        let url = try await second.newRecordingURL(startedAt: Date())
        try writeAudio(to: url)
        try await second.addRecording(at: url, recordedAt: Date(), model: "m", capture: nil)

        #expect(try await first.recentRecordings(limit: 5).count == 1)
    }
}
