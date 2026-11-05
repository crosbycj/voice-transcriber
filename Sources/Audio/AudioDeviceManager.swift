import CoreAudio
import Foundation

public final class AudioDeviceManager: Sendable {
    public init() {}

    public func availableInputDevices() throws -> [AudioInputDevice] {
        let defaultInputDeviceID = try defaultInputDeviceID()

        return try allAudioDeviceIDs()
            .filter(hasInputChannels(deviceID:))
            .compactMap { deviceID in
                guard
                    let name = try audioDeviceName(deviceID: deviceID),
                    let uid = try audioDeviceUID(deviceID: deviceID)
                else {
                    return nil
                }

                return AudioInputDevice(
                    uid: uid,
                    name: name,
                    deviceID: deviceID,
                    isDefault: deviceID == defaultInputDeviceID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }

                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    /// Finds the microphone to record from: the requested one if it's connected, otherwise the system default.
    public func resolveInput(uid: String?) throws -> InputDevice {
        if let uid {
            for deviceID in try allAudioDeviceIDs() where hasInputChannels(deviceID: deviceID) {
                if (try? audioDeviceUID(deviceID: deviceID)) == uid {
                    return InputDevice(id: deviceID, name: (try? audioDeviceName(deviceID: deviceID)) ?? "Microphone")
                }
            }
        }

        let defaultDeviceID = try defaultInputDeviceID()
        guard defaultDeviceID != kAudioObjectUnknown, hasInputChannels(deviceID: defaultDeviceID) else {
            throw AudioDeviceManagerError.noInputDevice
        }

        return InputDevice(id: defaultDeviceID, name: (try? audioDeviceName(deviceID: defaultDeviceID)) ?? "Microphone")
    }

    private func allAudioDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ))

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var deviceIDs = Array(repeating: AudioDeviceID(0), count: count)

        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ))

        return deviceIDs
    }

    private func defaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ))

        return deviceID
    }

    private func audioDeviceName(deviceID: AudioDeviceID) throws -> String? {
        try copyStringProperty(
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        )
    }

    private func audioDeviceUID(deviceID: AudioDeviceID) throws -> String? {
        try copyStringProperty(
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        )
    }

    private func copyStringProperty(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioDeviceID
    ) throws -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        try check(AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ))

        return value?.takeUnretainedValue() as String?
    }

    private func hasInputChannels(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawPointer.deallocate()
        }

        let audioBufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, audioBufferList) == noErr else {
            return false
        }

        let bufferListPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return bufferListPointer.reduce(into: 0) { partialResult, buffer in
            partialResult += Int(buffer.mNumberChannels)
        } > 0
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else {
            throw AudioDeviceManagerError.coreAudio(status)
        }
    }
}

public enum AudioDeviceManagerError: LocalizedError {
    case noInputDevice
    case coreAudio(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noInputDevice:
            return "No microphone is available."
        case .coreAudio(let status):
            return "Core Audio returned status \(status)."
        }
    }
}
