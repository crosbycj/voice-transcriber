import Foundation

/// What the microphone is actually delivering, ordered from healthy to worst.
///
/// Every state but `good` was found in real failed dictations: minutes of speech aimed at an input
/// that was delivering static, digital silence, or nothing at all while the waveform kept moving.
public enum InputHealth: String, Codable, Sendable, Comparable {
    case good
    /// Sustained broadband static. Speech never looks like this for seconds at a time.
    case noise
    /// Exact digital zeros: a muted or stalled input.
    case silent
    /// The input stopped delivering audio altogether.
    case noBuffers

    private var severity: Int {
        switch self {
        case .good: return 0
        case .noise: return 1
        case .silent: return 2
        case .noBuffers: return 3
        }
    }

    public static func < (lhs: InputHealth, rhs: InputHealth) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// Classifies 16 kHz mono audio into `InputHealth`, in 50 ms blocks. This catches a broken signal.
/// Whether a working microphone is actually hearing anyone is a question for the speech model.
public struct SignalMonitor: Sendable {
    private enum Tuning {
        static let sampleRate = 16_000
        static let blockSize = sampleRate / 20

        /// Bluetooth inputs routinely open with about a second of zeros, so this must be longer than that.
        static let silentBlocksRequired = 50
        static let noiseWindowBlocks = 50
        static let noiseFractionRequired = 0.9
        static let noiseZeroCrossingRate = 0.38
        static let noiseMinimumRMS = 500.0
    }

    public private(set) var health: InputHealth = .good

    private var pending: [Int16] = []
    private var consecutiveZeroBlocks = 0
    private var noiseHistory = RollingCount(capacity: Tuning.noiseWindowBlocks)

    public init() {
        pending.reserveCapacity(Tuning.blockSize)
    }

    /// Feeds samples and returns the new health if it changed.
    public mutating func process(_ samples: UnsafeBufferPointer<Int16>) -> InputHealth? {
        let previous = health

        for sample in samples {
            pending.append(sample)

            if pending.count == Tuning.blockSize {
                analyzeBlock()
                pending.removeAll(keepingCapacity: true)
            }
        }

        return health == previous ? nil : health
    }

    private mutating func analyzeBlock() {
        var sumOfSquares = 0.0
        var zeroCrossings = 0
        var peak: Int32 = 0
        var previousIsNegative = pending[0] < 0

        for sample in pending {
            let value = Double(sample)
            sumOfSquares += value * value
            peak = max(peak, abs(Int32(sample)))

            let isNegative = sample < 0
            if isNegative != previousIsNegative {
                zeroCrossings += 1
            }
            previousIsNegative = isNegative
        }

        let rms = (sumOfSquares / Double(pending.count)).squareRoot()
        let zeroCrossingRate = Double(zeroCrossings) / Double(pending.count)

        consecutiveZeroBlocks = peak == 0 ? consecutiveZeroBlocks + 1 : 0
        noiseHistory.record(zeroCrossingRate > Tuning.noiseZeroCrossingRate && rms > Tuning.noiseMinimumRMS)

        health = classify()
    }

    private func classify() -> InputHealth {
        if consecutiveZeroBlocks >= Tuning.silentBlocksRequired {
            return .silent
        }

        if noiseHistory.isFull, noiseHistory.fraction >= Tuning.noiseFractionRequired {
            return .noise
        }

        return .good
    }
}

private struct RollingCount: Sendable {
    private var flags: [Bool]
    private var nextIndex = 0
    private var filled = 0
    private var trueCount = 0

    init(capacity: Int) {
        flags = Array(repeating: false, count: capacity)
    }

    var isFull: Bool { filled == flags.count }
    var fraction: Double { Double(trueCount) / Double(max(filled, 1)) }

    mutating func record(_ value: Bool) {
        if isFull, flags[nextIndex] {
            trueCount -= 1
        }

        flags[nextIndex] = value
        nextIndex = (nextIndex + 1) % flags.count
        filled = min(filled + 1, flags.count)

        if value {
            trueCount += 1
        }
    }
}
