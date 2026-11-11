import Foundation

public protocol TranscriptionEngine: Sendable {
    var modelIdentifier: String { get }

    /// Loads the model ahead of the first transcription.
    func prepare() async throws

    /// Returns the transcript, which is empty if no speech was found.
    func transcribe(audioFile: URL) async throws -> Transcription

    /// Whether anyone can be heard in the latest stretch of a file, which may still be recording.
    /// Too little audio to judge counts as no: seconds into a recording, that means a dead input.
    func containsSpeech(audioFile: URL) async throws -> Bool
}

public struct Transcription: Equatable, Sendable {
    public let text: String
    /// Words recovered that the main decode dropped from the end.
    public let recoveredWordCount: Int
    /// Words removed as invented by the model at the end.
    public let removedWordCount: Int

    public init(text: String, recoveredWordCount: Int = 0, removedWordCount: Int = 0) {
        self.text = text
        self.recoveredWordCount = recoveredWordCount
        self.removedWordCount = removedWordCount
    }
}

/// Where getting the model ready has got to, in the terms someone waiting on it cares about.
public enum TranscriptionModelPreparationProgress: Sendable, Equatable {
    /// Asking the server which files to fetch.
    case checking
    /// Fetching the model, this far through (0 to 1).
    case downloading(fractionCompleted: Double)
    /// macOS is compiling the model for this Mac's Neural Engine. It reports no progress, and can take
    /// several minutes the first time on a smaller Mac.
    case preparing
}

public typealias TranscriptionModelPreparationProgressHandler = @Sendable (TranscriptionModelPreparationProgress) -> Void
