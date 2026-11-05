import AVFoundation
import Foundation
import OSLog
import VoiceAudio

/// Everything the app keeps: one WAV per recording, a JSON sidecar beside it, and `history.json`.
///
/// A dictation is safe from the moment it starts. Audio is recorded directly into `recordings/`, and it's
/// entered in the history before transcription begins, so `recoverInterrupted` can always finish the job
/// after a crash. The sidecars double as a backup that `history.json` can be rebuilt from.
public actor TranscriptStore {
    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let recordingsDirectory: URL
    private let historyFileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let filenameFormatter: DateFormatter
    private let logger = Logger(subsystem: "com.cooper.VoiceTranscriber", category: "TranscriptStore")

    private var cachedHistory: [TranscriptRecord]?
    private var cachedHistoryDate: Date?

    /// Interrupted audio younger than this may still be in use by another running copy of the app.
    private static let recoveryMinimumAge: TimeInterval = 5

    public static var defaultBaseDirectory: URL {
        let applicationSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport.appendingPathComponent("Voice Transcriber", isDirectory: true)
    }

    public init(baseDirectory: URL = TranscriptStore.defaultBaseDirectory) {
        self.baseDirectory = baseDirectory
        self.recordingsDirectory = baseDirectory.appendingPathComponent("recordings", isDirectory: true)
        self.historyFileURL = baseDirectory.appendingPathComponent("history.json", isDirectory: false)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        let filenameFormatter = DateFormatter()
        filenameFormatter.calendar = Calendar(identifier: .gregorian)
        filenameFormatter.locale = Locale(identifier: "en_US_POSIX")
        filenameFormatter.timeZone = .current
        filenameFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
        self.filenameFormatter = filenameFormatter
    }

    // MARK: - Recording lifecycle

    /// Reserves the file a new recording will be written to.
    public func newRecordingURL(startedAt: Date) throws -> URL {
        try ensureStorageDirectoriesExist()

        let baseName = filenameFormatter.string(from: startedAt)
        var candidate = baseName
        var suffix = 2

        while fileManager.fileExists(atPath: recordingURL(named: candidate).path) {
            candidate = "\(baseName)-\(suffix)"
            suffix += 1
        }

        return recordingURL(named: candidate)
    }

    /// Enters a finished recording in the history, awaiting its transcript.
    @discardableResult
    public func addRecording(
        at audioFileURL: URL,
        recordedAt: Date,
        model: String,
        capture: CaptureReport?
    ) throws -> TranscriptRecord {
        var history = try loadHistory()

        let record = TranscriptRecord(
            id: UUID().uuidString.lowercased(),
            timestamp: recordedAt,
            text: nil,
            audioFile: audioFileURL.lastPathComponent,
            durationSeconds: try audioDurationSeconds(for: audioFileURL),
            model: model,
            isPending: true,
            failureReason: nil,
            capture: capture
        )

        history.append(record)
        try writeHistory(history)
        writeSidecarIfPossible(for: record)
        return record
    }

    /// Saves a transcript. Returns nil if the record has since been deleted.
    @discardableResult
    public func completeTranscript(recordID: String, text: String, model: String) throws -> TranscriptRecord? {
        try updateRecord(recordID) { record in
            record.text = text
            record.model = model
            record.isPending = nil
            record.failureReason = nil
        }
    }

    /// Records why a transcript couldn't be produced. Any earlier transcript is left alone.
    @discardableResult
    public func markFailed(recordID: String, reason: String) throws -> TranscriptRecord? {
        try updateRecord(recordID) { record in
            record.isPending = nil
            record.failureReason = reason
        }
    }

    /// Finishes off anything a crash or power loss interrupted, and returns what still needs transcribing.
    public func recoverInterrupted(model: String) throws -> [TranscriptRecord] {
        try ensureStorageDirectoriesExist()

        var history = try loadHistory()
        let known = Set(history.map(\.audioFile))
        var didAddRecords = false

        for url in try unreferencedRecordings(excluding: known) {
            do {
                // A sidecar means the transcript already exists, and only the history lost track of it.
                if let existing = sidecarRecord(forAudioAt: url) {
                    history.append(existing)
                    didAddRecords = true
                    continue
                }

                // Read first, because repairing the file updates this date.
                let recordedAt = modificationDate(of: url) ?? Date()

                guard try WAVFileWriter.repair(at: url) > 0 else {
                    try fileManager.removeItem(at: url)
                    continue
                }

                let record = TranscriptRecord(
                    id: UUID().uuidString.lowercased(),
                    timestamp: recordedAt,
                    text: nil,
                    audioFile: url.lastPathComponent,
                    durationSeconds: try audioDurationSeconds(for: url),
                    model: model,
                    isPending: true,
                    failureReason: nil,
                    capture: nil
                )

                history.append(record)
                writeSidecarIfPossible(for: record)
                didAddRecords = true
                logger.notice("Recovered an interrupted recording: \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Couldn't recover \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if didAddRecords {
            history.sort { $0.timestamp < $1.timestamp }
            try writeHistory(history)
        }

        return history.filter(\.needsTranscription)
    }

    // MARK: - Reading

    public func recentRecordings(limit: Int) throws -> [TranscriptRecord] {
        Array(try loadHistory().reversed().prefix(limit))
    }

    public func record(withID id: String) throws -> TranscriptRecord? {
        try loadHistory().last(where: { $0.id == id })
    }

    public func latestTranscriptText() throws -> String? {
        try loadHistory().reversed().lazy.compactMap(\.usableText).first
    }

    public func audioFileURL(for record: TranscriptRecord) -> URL {
        recordingsDirectory.appendingPathComponent(record.audioFile, isDirectory: false)
    }

    public func storageDirectoryURL() throws -> URL {
        try ensureStorageDirectoriesExist()
        return baseDirectory
    }

    public func revealableFileURLs(for record: TranscriptRecord, includeMetadata: Bool) -> [URL] {
        var urls: [URL] = []

        let audioURL = audioFileURL(for: record)
        if fileManager.fileExists(atPath: audioURL.path) {
            urls.append(audioURL)
        }

        if includeMetadata {
            let sidecarURL = sidecarFileURL(for: record)

            if !fileManager.fileExists(atPath: sidecarURL.path) {
                writeSidecarIfPossible(for: record)
            }

            if fileManager.fileExists(atPath: sidecarURL.path) {
                urls.append(sidecarURL)
            }
        }

        return urls
    }

    // MARK: - Deleting

    public func deleteRecord(withID id: String) throws -> Bool {
        var history = try loadHistory()

        guard let index = history.lastIndex(where: { $0.id == id }) else {
            return false
        }

        // Files first: audio left behind by a failed delete would be "recovered" at the next launch.
        let record = history[index]

        for url in [audioFileURL(for: record), sidecarFileURL(for: record)]
        where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        history.remove(at: index)
        try writeHistory(history)
        return true
    }

    /// Removes audio that never made it into the history.
    public func discardAudio(at url: URL) {
        do {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            logger.error("Couldn't remove \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - History file

    private func updateRecord(
        _ id: String,
        _ change: (inout TranscriptRecord) -> Void
    ) throws -> TranscriptRecord? {
        var history = try loadHistory()

        guard let index = history.lastIndex(where: { $0.id == id }) else {
            return nil
        }

        change(&history[index])
        try writeHistory(history)
        writeSidecarIfPossible(for: history[index])
        return history[index]
    }

    private func loadHistory() throws -> [TranscriptRecord] {
        guard fileManager.fileExists(atPath: historyFileURL.path) else {
            cachedHistory = nil
            return try rebuildHistoryFromSidecars()
        }

        let fileDate = modificationDate(of: historyFileURL)
        if let cachedHistory, fileDate == cachedHistoryDate {
            return cachedHistory
        }

        let data = try Data(contentsOf: historyFileURL)
        guard !data.isEmpty else { return try rebuildHistoryFromSidecars() }

        do {
            let history = try decoder.decode([TranscriptRecord].self, from: data)
            cachedHistory = history
            cachedHistoryDate = fileDate
            return history
        } catch {
            logger.error("history.json is unreadable, rebuilding it: \(error.localizedDescription, privacy: .public)")
            return try rebuildHistoryFromSidecars()
        }
    }

    /// A damaged or missing history must never block saving new recordings or hide old ones.
    private func rebuildHistoryFromSidecars() throws -> [TranscriptRecord] {
        let contents = (try? fileManager.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)) ?? []
        let history = contents
            .filter { $0.pathExtension == "json" }
            .compactMap(decodeRecord)
            .sorted { $0.timestamp < $1.timestamp }

        if fileManager.fileExists(atPath: historyFileURL.path) {
            let backupName = "history.damaged-\(filenameFormatter.string(from: Date())).json"
            try? fileManager.moveItem(at: historyFileURL, to: baseDirectory.appendingPathComponent(backupName))
        }

        if !history.isEmpty {
            try writeHistory(history)
        }

        return history
    }

    private func decodeRecord(at url: URL) -> TranscriptRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(TranscriptRecord.self, from: data)
    }

    private func sidecarRecord(forAudioAt url: URL) -> TranscriptRecord? {
        decodeRecord(at: url.deletingPathExtension().appendingPathExtension("json"))
    }

    private func writeHistory(_ history: [TranscriptRecord]) throws {
        let data = try encoder.encode(history)
        try data.write(to: historyFileURL, options: .atomic)
        cachedHistory = history
        cachedHistoryDate = modificationDate(of: historyFileURL)
    }

    // MARK: - Files

    private func ensureStorageDirectoriesExist() throws {
        try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
    }

    private func recordingURL(named name: String) -> URL {
        recordingsDirectory.appendingPathComponent(name, isDirectory: false).appendingPathExtension("wav")
    }

    private func unreferencedRecordings(excluding known: Set<String>) throws -> [URL] {
        let cutoff = Date().addingTimeInterval(-Self.recoveryMinimumAge)

        return try fileManager
            .contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { url in
                url.pathExtension == "wav"
                    && !known.contains(url.lastPathComponent)
                    && (modificationDate(of: url) ?? .distantPast) < cutoff
            }
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func audioDurationSeconds(for url: URL) throws -> Double {
        let audioFile = try AVAudioFile(forReading: url)
        return Double(audioFile.length) / audioFile.processingFormat.sampleRate
    }

    private func sidecarFileURL(for record: TranscriptRecord) -> URL {
        audioFileURL(for: record).deletingPathExtension().appendingPathExtension("json")
    }

    private func writeSidecarIfPossible(for record: TranscriptRecord) {
        do {
            try encoder.encode(record).write(to: sidecarFileURL(for: record), options: .atomic)
        } catch {
            logger.error("Couldn't write the sidecar for \(record.audioFile, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}

public struct TranscriptRecord: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public var text: String?
    public let audioFile: String
    public let durationSeconds: Double
    public var model: String
    /// True from the moment recording ends until a transcript or failure is saved.
    public var isPending: Bool?
    public var failureReason: String?
    public var capture: CaptureReport?

    /// The transcript, if there's anything in it.
    public var usableText: String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    public var needsTranscription: Bool {
        isPending == true
    }

    public var isFailure: Bool {
        usableText == nil && !needsTranscription
    }
}
