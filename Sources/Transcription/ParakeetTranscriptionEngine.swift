@preconcurrency import AVFoundation
import FluidAudio
import Foundation
import OSLog

public actor ParakeetTranscriptionEngine: TranscriptionEngine {
    private enum Tuning {
        static let sampleRate = 16_000
        /// The longest stretch that fits one model window with no padding.
        static let windowSamples = 238_080
        /// FluidAudio refuses anything shorter.
        static let minimumSamples = sampleRate
        /// A healthy connection lists the model's files in about two seconds and then streams bytes
        /// constantly, so this much silence means nothing is coming back.
        static let networkSilenceLimit: Duration = .seconds(30)
        /// Times to resume a download that froze partway, as long as each try gets further.
        static let downloadAttempts = 5
    }

    public nonisolated let modelIdentifier = "parakeet-tdt-0.6b-v3"

    private let modelVersion = AsrModelVersion.v3
    private let modelDirectory: URL
    private let logger = Logger(subsystem: "com.cooper.VoiceTranscriber", category: "ParakeetTranscriptionEngine")
    private var loadTask: Task<AsrManager, Error>?
    private var lastJob: Task<Void, Never>?

    /// - Parameter modelDirectory: Where the model lives. Defaults to FluidAudio's shared cache.
    public init(modelDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory ?? AsrModels.defaultCacheDirectory(for: modelVersion)
    }

    public func prepare() async throws {
        try await prepare(progressHandler: nil)
    }

    public func prepare(progressHandler: TranscriptionModelPreparationProgressHandler?) async throws {
        _ = try await loadManager(progressHandler: progressHandler)
    }

    public func modelFilesExistOnDisk() -> Bool {
        AsrModels.modelsExist(at: modelDirectory, version: modelVersion)
    }

    public func transcribe(audioFile: URL) async throws -> Transcription {
        try await serialized { try await self.decode(audioFile) }
    }

    public func containsSpeech(audioFile: URL) async throws -> Bool {
        try await serialized { try await self.detectSpeech(in: audioFile) }
    }

    /// Runs jobs strictly one at a time. Actor isolation alone isn't enough here: the model's decoder
    /// state is shared, and an actor can interleave two callers at every `await`, which is what
    /// retranscribing while a dictation finishes would otherwise do.
    private func serialized<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = lastJob
        let job = Task {
            await previous?.value
            try Task.checkCancellation()
            return try await work()
        }

        lastJob = Task { _ = try? await job.value }

        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: {
            job.cancel()
        }
    }

    private func detectSpeech(in audioFile: URL) async throws -> Bool {
        let manager = try await loadManager()
        let ending = try AudioEnding(file: audioFile, maximumSamples: Tuning.windowSamples)

        guard ending.totalSamples >= Tuning.minimumSamples else { return false }

        var decoderState = freshDecoderState()
        let result = try await manager.transcribe(ending.samples, decoderState: &decoderState)
        return !cleanEnding(of: Self.words(from: result, offset: ending.startTime), in: ending).isEmpty
    }

    /// Every decode starts clean, so nothing from one recording can leak into the next.
    private func freshDecoderState() -> TdtDecoderState {
        TdtDecoderState.make(decoderLayers: modelVersion.decoderLayers)
    }

    private func cleanEnding(of words: [TranscriptWord], in ending: AudioEnding) -> [TranscriptWord] {
        let levels = AudioLevels(samples: ending.samples, startTime: ending.startTime, sampleRate: Double(Tuning.sampleRate))
        return TranscriptRepair.removeTrailingArtifacts(
            from: words,
            audioDuration: ending.duration,
            level: levels.relativeLevel
        )
    }

    private func decode(_ audioFile: URL) async throws -> Transcription {
        let manager = try await loadManager()

        do {
            let ending = try AudioEnding(file: audioFile, maximumSamples: Tuning.windowSamples)

            guard ending.totalSamples > 0 else {
                return Transcription(text: "")
            }

            var decoderState = freshDecoderState()
            let primary: ASRResult
            if ending.totalSamples < Tuning.minimumSamples {
                let padding = [Float](repeating: 0, count: Tuning.minimumSamples - ending.totalSamples)
                primary = try await manager.transcribe(ending.samples + padding, decoderState: &decoderState)
            } else {
                primary = try await manager.transcribe(audioFile, decoderState: &decoderState)
            }

            let primaryWords = Self.words(from: primary)
            var words = primaryWords

            // Shorter recordings are a single window already, so only longer ones can lose their end.
            if ending.totalSamples > Tuning.windowSamples {
                try Task.checkCancellation()
                var tailState = freshDecoderState()
                let tail = try await manager.transcribe(ending.samples, decoderState: &tailState)
                words = TranscriptRepair.mergeTail(
                    primary: primaryWords,
                    tail: Self.words(from: tail, offset: ending.startTime)
                )
            }

            let mergedCount = words.count
            words = cleanEnding(of: words, in: ending)

            let recovered = max(mergedCount - primaryWords.count, 0)
            let removed = mergedCount - words.count

            if recovered > 0 || removed > 0 {
                logger.info("Repaired transcript ending: recovered=\(recovered, privacy: .public) removed=\(removed, privacy: .public)")
            }

            let text = words == primaryWords
                ? primary.text
                : words.map(\.text).joined(separator: " ")

            return Transcription(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                recoveredWordCount: recovered,
                removedWordCount: removed
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ParakeetTranscriptionEngineError.transcriptionFailed(underlying: error)
        }
    }

    private static func words(from result: ASRResult, offset: TimeInterval = 0) -> [TranscriptWord] {
        var words: [TranscriptWord] = []

        for timing in result.tokenTimings ?? [] {
            let text = timing.token.replacingOccurrences(of: "▁", with: " ")
            let startsWord = text.hasPrefix(" ") || words.isEmpty
            let trimmed = text.trimmingCharacters(in: .whitespaces)

            if startsWord {
                words.append(TranscriptWord(
                    text: trimmed,
                    start: timing.startTime + offset,
                    end: timing.endTime + offset,
                    confidence: timing.confidence
                ))
            } else {
                words[words.count - 1].text += trimmed
                words[words.count - 1].end = timing.endTime + offset
                words[words.count - 1].confidence = min(words[words.count - 1].confidence, timing.confidence)
            }
        }

        return words
    }

    /// Loads the model, downloading it first if it isn't on disk.
    ///
    /// Callers share one load. Cancelling the caller that started it cancels it, download included, which
    /// is how the download dialog's Quit stops it. Later callers only wait on it.
    private func loadManager(
        progressHandler: TranscriptionModelPreparationProgressHandler? = nil
    ) async throws -> AsrManager {
        let task: Task<AsrManager, Error>
        let startedHere: Bool

        if let loadTask {
            task = loadTask
            startedHere = false
        } else {
            task = Task { [modelVersion, modelDirectory] in
                try await Self.loadModels(version: modelVersion, directory: modelDirectory, progressHandler: progressHandler)
            }
            loadTask = task
            startedHere = true
        }

        do {
            let manager = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                if startedHere { task.cancel() }
            }

            if startedHere {
                logger.info("Parakeet ASR models are ready")
            }
            return manager
        } catch {
            // Leave the next attempt free to try again.
            if loadTask == task {
                loadTask = nil
            }

            if Task.isCancelled {
                throw CancellationError()
            }
            if error is NetworkWatchdog.Silence || Self.isNetworkFailure(error) {
                logger.error("Couldn't reach the model server: \(String(describing: error), privacy: .public)")
                throw ParakeetTranscriptionEngineError.modelServerUnreachable
            }
            throw ParakeetTranscriptionEngineError.modelLoadingFailed(underlying: error)
        }
    }

    private static func loadModels(
        version: AsrModelVersion,
        directory: URL,
        progressHandler: TranscriptionModelPreparationProgressHandler?
    ) async throws -> AsrManager {
        try await NetworkWatchdog.run(limit: Tuning.networkSilenceLimit, attempts: Tuning.downloadAttempts) { report in
            let handler: ProgressHandler = { progress in
                switch progress.phase {
                case .listing, .downloading:
                    report(.network(progress: progress.fractionCompleted))
                case .compiling:
                    report(.local)
                }
                progressHandler?(preparationProgress(from: progress))
            }

            let models = AsrModels.modelsExist(at: directory, version: version)
                ? try await AsrModels.load(from: directory, version: version, progressHandler: handler)
                : try await AsrModels.downloadAndLoad(to: directory, version: version, progressHandler: handler)
            report(.local)

            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
    }

    /// Whether `error`, or anything it wraps, is the network failing rather than the model.
    static func isNetworkFailure(_ error: Error) -> Bool {
        let networkCodes: Set<URLError.Code> = [
            .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
            .timedOut, .networkConnectionLost, .secureConnectionFailed, .internationalRoamingOff,
            .dataNotAllowed, .cannotLoadFromNetwork,
        ]

        if case DownloadError.downloadFailed(_, let underlying) = error {
            return isNetworkFailure(underlying)
        }
        if case DownloadError.stalled = error {
            return true
        }

        var current: NSError? = error as NSError
        var depth = 0
        while let nsError = current, depth < 8 {
            if nsError.domain == NSURLErrorDomain, networkCodes.contains(URLError.Code(rawValue: nsError.code)) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }

    private static func preparationProgress(from downloadProgress: DownloadProgress) -> TranscriptionModelPreparationProgress {
        let phase: TranscriptionModelPreparationPhase

        switch downloadProgress.phase {
        case .listing:
            phase = .listingFiles
        case .downloading(let completedFiles, let totalFiles):
            phase = .downloading(completedFiles: completedFiles, totalFiles: totalFiles)
        case .compiling(let modelName):
            phase = .compiling(modelName: modelName)
        }

        return TranscriptionModelPreparationProgress(
            fractionCompleted: downloadProgress.fractionCompleted,
            phase: phase
        )
    }
}

/// The last stretch of a recording, as samples.
private struct AudioEnding {
    let samples: [Float]
    let totalSamples: Int
    let startTime: TimeInterval
    let duration: TimeInterval

    init(file url: URL, maximumSamples: Int) throws {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let total = Int(file.length)
        let count = min(total, maximumSamples)

        file.framePosition = AVAudioFramePosition(total - count)

        guard
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(max(count, 1)))
        else {
            throw ParakeetTranscriptionEngineError.unreadableAudio
        }

        if count > 0 {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(count))
        }

        guard let channel = buffer.floatChannelData?[0] else {
            throw ParakeetTranscriptionEngineError.unreadableAudio
        }

        samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        totalSamples = total
        startTime = Double(total - count) / sampleRate
        duration = Double(total) / sampleRate
    }
}

public enum ParakeetTranscriptionEngineError: LocalizedError {
    case modelLoadingFailed(underlying: Error)
    case modelServerUnreachable
    case transcriptionFailed(underlying: Error)
    case unreadableAudio

    public var errorDescription: String? {
        switch self {
        case .modelLoadingFailed(let underlying):
            return "Couldn't load the speech model: \(underlying.localizedDescription)"
        case .modelServerUnreachable:
            return "Couldn't reach the speech model server. If you're on a VPN, proxy or work network, try turning it off or switching networks, then try again."
        case .transcriptionFailed(let underlying):
            return "Couldn't transcribe the audio: \(underlying.localizedDescription)"
        case .unreadableAudio:
            return "The recording couldn't be read."
        }
    }
}
