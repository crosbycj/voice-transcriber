import CoreAudio
import Foundation

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let uid: String
    public let name: String
    public let deviceID: AudioDeviceID
    public let isDefault: Bool

    public var id: String { uid }

    public init(uid: String, name: String, deviceID: AudioDeviceID, isDefault: Bool) {
        self.uid = uid
        self.name = name
        self.deviceID = deviceID
        self.isDefault = isDefault
    }
}

/// A microphone resolved for recording.
public struct InputDevice: Equatable, Sendable {
    public let id: AudioDeviceID
    public let name: String

    public init(id: AudioDeviceID, name: String) {
        self.id = id
        self.name = name
    }
}
