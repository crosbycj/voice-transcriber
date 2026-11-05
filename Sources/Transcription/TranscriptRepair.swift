import Foundation

/// A decoded word with where it sits in the recording.
public struct TranscriptWord: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    fileprivate var matchKey: String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

/// Fixes for the two ways the end of a Parakeet transcript goes wrong.
public enum TranscriptRepair {
    private enum Tuning {
        static let matchTimeTolerance: TimeInterval = 1.0
        static let minimumTailGain: TimeInterval = 0.3

        static let artifactWindow: TimeInterval = 0.6
        static let artifactMaxConfidence: Float = 0.45
        static let artifactMaxRelativeLevel = 0.25
        static let artifactLevelSpan: TimeInterval = 0.45
        static let artifactMaxWords = 2
        static let fillers: Set<String> = [
            "yeah", "yep", "okay", "ok", "oh", "ah", "uh", "um", "mm", "mmhmm", "mhm", "hmm",
        ]
    }

    /// Recovers an ending the main decode dropped.
    ///
    /// The model sees 15 seconds at a time. When the last window is short it's padded with zeros, and
    /// such a window can decode to nothing, silently losing the final words. `tail` is a re-decode of
    /// the last 15 seconds as one full window of real audio. This only ever extends `primary`: where the
    /// two disagree without `tail` reaching later into the audio, `primary` stands.
    public static func mergeTail(primary: [TranscriptWord], tail: [TranscriptWord]) -> [TranscriptWord] {
        guard let tailStart = tail.first?.start else { return primary }
        guard !primary.isEmpty else { return tail }

        guard let run = longestSharedRun(primary: primary, tail: tail, after: tailStart - 0.5) else {
            // Nothing in common. Only safe to use the tail if it's entirely past what we already have.
            let primaryEnd = primary[primary.count - 1].end
            return primary + tail.filter { $0.start >= primaryEnd - 0.1 }
        }

        let primaryRest = primary[(run.primaryIndex + run.length)...]
        let tailRest = tail[(run.tailIndex + run.length)...]
        let primaryEnd = primaryRest.last?.end ?? primary[run.primaryIndex + run.length - 1].end

        guard
            let tailEnd = tailRest.last?.end,
            tailEnd > primaryEnd + Tuning.minimumTailGain,
            tailRest.count > primaryRest.count
        else {
            return primary
        }

        // Take the joining word from the tail too: the primary decode may have ended its sentence there.
        var merged = Array(primary[..<(run.primaryIndex + run.length)])
        merged[merged.count - 1] = tail[run.tailIndex + run.length - 1]
        return merged + tailRest
    }

    /// Removes filler the model invented at the very end of a recording.
    ///
    /// Parakeet tends to emit a stray "Yeah." in the last moments of audio. Measured on real dictations,
    /// these sit within half a second of the end, at noise-floor loudness, with confidence under 0.4,
    /// while spoken "yeah"s have real energy behind them.
    ///
    /// Only filler words are eligible. People trail off at the end of a sentence, so a real last word
    /// like "about" or "this" can look just as quiet and unsure, and cutting those would be worse than
    /// leaving a stray "Yeah."
    ///
    /// - Parameter level: RMS of the audio between two times, relative to the recording's speech level.
    public static func removeTrailingArtifacts(
        from words: [TranscriptWord],
        audioDuration: TimeInterval,
        level: (TimeInterval, TimeInterval) -> Double
    ) -> [TranscriptWord] {
        var result = words

        // On its own, an unsure filler is what a stray tap or a cough decodes to, not dictation.
        if result.count == 1, isUnsureFiller(result[0]) {
            return []
        }

        for _ in 0..<Tuning.artifactMaxWords {
            guard result.count > 1, let last = result.last else { break }

            let isAtEnd = last.start >= audioDuration - Tuning.artifactWindow
            let isInaudible = level(last.start, last.start + Tuning.artifactLevelSpan) < Tuning.artifactMaxRelativeLevel

            guard isAtEnd, isUnsureFiller(last), isInaudible else { break }
            result.removeLast()
        }

        return result
    }

    private static func isUnsureFiller(_ word: TranscriptWord) -> Bool {
        word.confidence < Tuning.artifactMaxConfidence && Tuning.fillers.contains(word.matchKey)
    }

    /// Finds the longest run of matching words, preferring the latest when runs tie.
    private static func longestSharedRun(
        primary: [TranscriptWord],
        tail: [TranscriptWord],
        after startTime: TimeInterval
    ) -> (primaryIndex: Int, tailIndex: Int, length: Int)? {
        var best: (primaryIndex: Int, tailIndex: Int, length: Int)?

        for primaryIndex in primary.indices where primary[primaryIndex].start >= startTime {
            for tailIndex in tail.indices {
                var length = 0

                while primaryIndex + length < primary.count,
                      tailIndex + length < tail.count,
                      matches(primary[primaryIndex + length], tail[tailIndex + length]) {
                    length += 1
                }

                if length > 0, length >= (best?.length ?? 0) {
                    best = (primaryIndex, tailIndex, length)
                }
            }
        }

        return best
    }

    private static func matches(_ lhs: TranscriptWord, _ rhs: TranscriptWord) -> Bool {
        lhs.matchKey == rhs.matchKey && abs(lhs.start - rhs.start) < Tuning.matchTimeTolerance
    }
}

/// Loudness of a stretch of audio, relative to the speech in it.
struct AudioLevels {
    private static let frameSize = 800
    private static let silenceFloor: Float = 1e-5

    private let samples: [Float]
    private let startTime: TimeInterval
    private let sampleRate: Double
    private let speechLevel: Float

    /// - Parameter startTime: Where `samples` begins within the recording.
    init(samples: [Float], startTime: TimeInterval, sampleRate: Double) {
        self.samples = samples
        self.startTime = startTime
        self.sampleRate = sampleRate

        let frameLevels = stride(from: 0, to: max(samples.count - Self.frameSize, 0), by: Self.frameSize)
            .map { Self.rms(samples[$0..<($0 + Self.frameSize)]) }
            .sorted()

        // The 90th percentile tracks speech without being thrown off by one loud click.
        speechLevel = frameLevels.isEmpty ? 0 : frameLevels[Int(Double(frameLevels.count) * 0.9)]
    }

    func relativeLevel(from start: TimeInterval, to end: TimeInterval) -> Double {
        let lower = max(Int((start - startTime) * sampleRate), 0)
        let upper = min(Int((end - startTime) * sampleRate), samples.count)

        guard lower < upper, speechLevel > Self.silenceFloor else { return 0 }
        return Double(Self.rms(samples[lower..<upper]) / speechLevel)
    }

    private static func rms(_ slice: ArraySlice<Float>) -> Float {
        guard !slice.isEmpty else { return 0 }
        return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
    }
}
