@preconcurrency import AVFoundation
import Foundation
import os

@MainActor
public final class AmplitudeService: ObservableObject {
    @Published public private(set) var amplitudes: [CGFloat]

    nonisolated private static let slotCount = 8
    nonisolated private static let tickInterval: TimeInterval = 1.0 / 20.0
    nonisolated private static let smoothingAlphaNew: Float = 0.85
    nonisolated private static let minDb: Float = -50
    nonisolated private static let maxDb: Float = -16
    nonisolated private static let minNormalizedHeight: CGFloat = 0.10
    nonisolated private static let maxNormalizedHeight: CGFloat = 0.95

    nonisolated private let smoothedAmplitude = OSAllocatedUnfairLock(initialState: Float(0))
    private var timer: Timer?

    public init() {
        self.amplitudes = Array(repeating: Self.minNormalizedHeight, count: Self.slotCount)
    }

    nonisolated public func process(buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(buffer: buffer)
        smoothedAmplitude.withLock { current in
            current = current * (1 - Self.smoothingAlphaNew) + rms * Self.smoothingAlphaNew
        }
    }

    public func start() {
        amplitudes = Array(repeating: Self.minNormalizedHeight, count: Self.slotCount)
        smoothedAmplitude.withLock { $0 = 0 }

        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        smoothedAmplitude.withLock { $0 = 0 }
        amplitudes = Array(repeating: Self.minNormalizedHeight, count: Self.slotCount)
    }

    private func tick() {
        let raw = smoothedAmplitude.withLock { $0 }
        let db = 20 * log10(max(raw, 1e-5))
        let unit = (db - Self.minDb) / (Self.maxDb - Self.minDb)
        let clampedUnit = CGFloat(min(max(unit, 0), 1))
        let range = Self.maxNormalizedHeight - Self.minNormalizedHeight
        let normalized = Self.minNormalizedHeight + clampedUnit * range
        let clamped = min(max(normalized, Self.minNormalizedHeight), Self.maxNormalizedHeight)

        var next = amplitudes
        next.removeFirst()
        next.append(clamped)
        amplitudes = next
    }

    nonisolated private static func rms(buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        if let floatData = buffer.floatChannelData {
            let channel = floatData[0]
            var sum: Float = 0
            for i in 0..<frameCount {
                let v = channel[i]
                sum += v * v
            }
            return (sum / Float(frameCount)).squareRoot()
        }

        if let int16Data = buffer.int16ChannelData {
            let channel = int16Data[0]
            var sum: Float = 0
            for i in 0..<frameCount {
                let v = Float(channel[i]) / 32_768.0
                sum += v * v
            }
            return (sum / Float(frameCount)).squareRoot()
        }

        if let int32Data = buffer.int32ChannelData {
            let channel = int32Data[0]
            var sum: Float = 0
            let scale: Float = 1.0 / 2_147_483_648.0
            for i in 0..<frameCount {
                let v = Float(channel[i]) * scale
                sum += v * v
            }
            return (sum / Float(frameCount)).squareRoot()
        }

        return 0
    }
}
