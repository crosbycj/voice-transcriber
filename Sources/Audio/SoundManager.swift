import AVFoundation
import Foundation

public enum SoundEvent: String, CaseIterable, Sendable {
    case recordingStart
    case toggleLock
    case recordingEnd
    case error

    public var displayName: String {
        switch self {
        case .recordingStart: return "Recording Start"
        case .toggleLock: return "Toggle Lock"
        case .recordingEnd: return "Recording End"
        case .error: return "Error"
        }
    }

    public var defaultsKey: String { "voiceTranscriber.sound.\(rawValue)" }

    public static let defaultAssignments: [SoundEvent: String] = [
        .recordingStart: "system/begin_record",
        .toggleLock: "ink/InkSoundBecomeMouse",
        .recordingEnd: "system/end_record",
        .error: "system/head_gestures_double_nod",
    ]
}

@MainActor
public final class SoundManager: ObservableObject {
    public static let shared = SoundManager()

    private static let enabledDefaultsKey = "voiceTranscriber.soundsEnabled"
    private static let noneSentinel = ""

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var assignments: [SoundEvent: SystemSound?] = [:]
    @Published public private(set) var eventEnabled: [SoundEvent: Bool] = [:]
    public private(set) var library: [SystemSound]

    private let defaults: UserDefaults
    private var players: [SoundEvent: AVAudioPlayer] = [:]
    private var previewPlayer: AVAudioPlayer?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.library = SoundLibrary.discover()

        if let stored = defaults.object(forKey: Self.enabledDefaultsKey) as? Bool {
            self.isEnabled = stored
        } else {
            self.isEnabled = true
        }

        loadEventEnabled()
        loadAssignments()
        rebuildPlayerCache()
    }

    // MARK: - Playback

    public func play(_ event: SoundEvent) {
        guard isEnabled else { return }
        guard eventEnabled[event] == true else { return }
        guard let player = players[event] else { return }
        player.currentTime = 0
        player.play()
    }

    public func preview(_ sound: SystemSound) {
        guard let player = try? AVAudioPlayer(contentsOf: sound.url) else { return }
        player.prepareToPlay()
        previewPlayer = player
        player.play()
    }

    // MARK: - Mutations

    public func setSound(_ sound: SystemSound?, for event: SoundEvent) {
        assignments[event] = sound
        persistAssignment(sound, for: event)
        reloadPlayer(for: event)
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledDefaultsKey)
    }

    public func setEventEnabled(_ enabled: Bool, for event: SoundEvent) {
        guard eventEnabled[event] != enabled else { return }
        eventEnabled[event] = enabled
        defaults.set(enabled, forKey: Self.eventEnabledKey(for: event))
    }

    public func resetToDefaults() {
        for event in SoundEvent.allCases {
            let name = SoundEvent.defaultAssignments[event]
            let sound = name.flatMap { SoundLibrary.findByDisplayName($0, in: library) }
            assignments[event] = sound
            persistAssignment(sound, for: event)

            eventEnabled[event] = true
            defaults.set(true, forKey: Self.eventEnabledKey(for: event))
        }
        rebuildPlayerCache()
    }

    // MARK: - Persistence

    private static func eventEnabledKey(for event: SoundEvent) -> String {
        "voiceTranscriber.soundEnabled.\(event.rawValue)"
    }

    private func loadEventEnabled() {
        var result: [SoundEvent: Bool] = [:]
        for event in SoundEvent.allCases {
            if let stored = defaults.object(forKey: Self.eventEnabledKey(for: event)) as? Bool {
                result[event] = stored
            } else {
                result[event] = true
            }
        }
        eventEnabled = result
    }

    private func loadAssignments() {
        var result: [SoundEvent: SystemSound?] = [:]
        for event in SoundEvent.allCases {
            if let stored = defaults.object(forKey: event.defaultsKey) as? String {
                if stored == Self.noneSentinel {
                    result[event] = .some(nil)
                } else if let sound = SoundLibrary.findByDisplayName(stored, in: library) {
                    result[event] = .some(sound)
                } else {
                    result[event] = .some(nil)
                }
            } else if let defaultName = SoundEvent.defaultAssignments[event],
                      let sound = SoundLibrary.findByDisplayName(defaultName, in: library) {
                result[event] = .some(sound)
            } else {
                result[event] = .some(nil)
            }
        }
        assignments = result
    }

    private func persistAssignment(_ sound: SystemSound?, for event: SoundEvent) {
        if let sound {
            defaults.set(sound.displayName, forKey: event.defaultsKey)
        } else {
            defaults.set(Self.noneSentinel, forKey: event.defaultsKey)
        }
    }

    // MARK: - Player cache

    private func rebuildPlayerCache() {
        players.removeAll(keepingCapacity: true)
        for event in SoundEvent.allCases {
            reloadPlayer(for: event)
        }
    }

    private func reloadPlayer(for event: SoundEvent) {
        guard let sound = assignments[event] ?? nil else {
            players[event] = nil
            return
        }
        if let player = try? AVAudioPlayer(contentsOf: sound.url) {
            player.prepareToPlay()
            players[event] = player
        } else {
            players[event] = nil
        }
    }
}
