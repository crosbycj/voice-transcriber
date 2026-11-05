@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import VTExceptionCatcher

/// Somewhere audio buffers come from. `AudioRecorder` calls these serially on its own queue.
public protocol CaptureSource: AnyObject {
    /// Begins delivering audio. `onInterruption` fires when the source stops for reasons of its own,
    /// such as a device reconfiguring or disappearing; the source must then be started again.
    func start(
        deviceID: AudioDeviceID,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onInterruption: @escaping @Sendable () -> Void
    ) throws

    func stop()

    /// Whether audio is still flowing. An interruption is only a hint: Core Audio also reports
    /// configuration changes on perfectly healthy starts, and restarting for those would cut into speech.
    var isDelivering: Bool { get }

    /// The rate buffers are arriving at, for diagnostics.
    var inputSampleRate: Double { get }
}

/// Captures from one Core Audio input through a fresh `AVAudioEngine` on every start.
///
/// A new engine per start is deliberate: after a configuration change the old one is stopped and its
/// formats are stale, and rebuilding is more dependable than trying to revive it.
public final class EngineCaptureSource: CaptureSource {
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    public private(set) var inputSampleRate: Double = 0

    public init() {}

    public func start(
        deviceID: AudioDeviceID,
        onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
        onInterruption: @escaping @Sendable () -> Void
    ) throws {
        stop()

        let engine = AVAudioEngine()
        try select(deviceID, on: engine)

        let inputNode = engine.inputNode
        try alignClientFormat(of: inputNode)

        let format = inputNode.inputFormat(forBus: 0)
        let clientFormat = inputNode.outputFormat(forBus: 0)

        // Tapping a mismatched or empty format raises an Objective-C exception. Check first, and catch
        // it anyway, because the device can change between here and the tap. The caller tries again.
        guard format.sampleRate > 0, format.channelCount > 0, clientFormat.sampleRate == format.sampleRate else {
            throw CaptureSourceError.inputNotReady
        }

        try VTExceptionCatcher.perform {
            inputNode.installTap(onBus: 0, bufferSize: 2_048, format: nil) { buffer, _ in
                onBuffer(buffer)
            }
        }

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in
            onInterruption()
        }

        self.engine = engine
        inputSampleRate = format.sampleRate

        do {
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    public var isDelivering: Bool {
        guard let engine, engine.isRunning else { return false }
        return engine.inputNode.inputFormat(forBus: 0).sampleRate == inputSampleRate
    }

    public func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }

        guard let engine else { return }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
    }

    /// A new engine assumes the system default input's format even after another device is selected.
    /// When the rates differ, the engine either refuses to start or, worse, reports success and then
    /// dies moments later having delivered nothing. Telling it the real rate avoids both.
    private func alignClientFormat(of inputNode: AVAudioInputNode) throws {
        guard inputNode.inputFormat(forBus: 0).sampleRate != inputNode.outputFormat(forBus: 0).sampleRate else {
            return
        }

        guard let audioUnit = inputNode.audioUnit else {
            throw CaptureSourceError.audioUnitUnavailable
        }

        var description = inputNode.inputFormat(forBus: 0).streamDescription.pointee
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &description,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        guard status == noErr else {
            throw CaptureSourceError.cannotSetFormat(status)
        }
    }

    private func select(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw CaptureSourceError.audioUnitUnavailable
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw CaptureSourceError.cannotSelectDevice(status)
        }
    }
}

public enum CaptureSourceError: LocalizedError {
    case audioUnitUnavailable
    case inputNotReady
    case cannotSelectDevice(OSStatus)
    case cannotSetFormat(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .audioUnitUnavailable:
            return "The microphone input couldn't be initialized."
        case .inputNotReady:
            return "The microphone isn't ready yet."
        case .cannotSelectDevice(let status):
            return "Couldn't select the microphone (Core Audio status \(status))."
        case .cannotSetFormat(let status):
            return "Couldn't configure the microphone (Core Audio status \(status))."
        }
    }
}
