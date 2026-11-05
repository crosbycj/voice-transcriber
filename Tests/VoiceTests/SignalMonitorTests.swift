import Foundation
import Testing
@testable import VoiceAudio

@Suite struct SignalMonitorTests {
    private let sampleRate = 16_000

    private func feed(_ samples: [Int16], to monitor: inout SignalMonitor) {
        samples.withUnsafeBufferPointer { _ = monitor.process($0) }
    }

    /// Modulated tone with pauses, standing in for speech at a typical dictation level.
    private func speech(seconds: Double) -> [Int16] {
        (0..<Int(seconds * Double(sampleRate))).map { index in
            let time = Double(index) / Double(sampleRate)
            let envelope = max(0, sin(2 * .pi * 3 * time))
            return Int16(2_000 * envelope * sin(2 * .pi * 180 * time))
        }
    }

    private func whiteNoise(seconds: Double, amplitude: Int16 = 4_000) -> [Int16] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * Double(sampleRate))).map { _ in
            Int16.random(in: -amplitude...amplitude, using: &generator)
        }
    }

    private func roomTone(seconds: Double) -> [Int16] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * Double(sampleRate))).map { _ in
            Int16.random(in: -40...40, using: &generator)
        }
    }

    @Test func speechIsHealthy() {
        var monitor = SignalMonitor()
        feed(speech(seconds: 15), to: &monitor)
        #expect(monitor.health == .good)
    }

    @Test func staticIsCaughtWithinSeconds() {
        var monitor = SignalMonitor()
        feed(whiteNoise(seconds: 3), to: &monitor)
        #expect(monitor.health == .noise)
    }

    @Test func bluetoothStyleOpeningSilenceIsNotAProblem() {
        var monitor = SignalMonitor()
        feed([Int16](repeating: 0, count: Int(1.2 * Double(sampleRate))), to: &monitor)
        feed(speech(seconds: 3), to: &monitor)
        #expect(monitor.health == .good)
    }

    @Test func sustainedDigitalSilenceIsCaught() {
        var monitor = SignalMonitor()
        feed([Int16](repeating: 0, count: 3 * sampleRate), to: &monitor)
        #expect(monitor.health == .silent)
    }

    @Test func aQuietRoomIsNotABrokenSignal() {
        var monitor = SignalMonitor()
        feed(roomTone(seconds: 11), to: &monitor)
        #expect(monitor.health == .good)
    }

    @Test func recoversOnceTheStaticStops() {
        var monitor = SignalMonitor()
        feed(whiteNoise(seconds: 3), to: &monitor)
        #expect(monitor.health == .noise)
        feed(speech(seconds: 2), to: &monitor)
        #expect(monitor.health == .good)
    }

    @Test func reportsOnlyChanges() {
        var monitor = SignalMonitor()
        let noise = whiteNoise(seconds: 3)
        #expect(noise.withUnsafeBufferPointer { monitor.process($0) } == .noise)
        #expect(noise.withUnsafeBufferPointer { monitor.process($0) } == nil)
    }

    @Test func severityOrdering() {
        #expect(InputHealth.good < .noise)
        #expect(InputHealth.noise < .silent)
        #expect(InputHealth.silent < .noBuffers)
    }
}
