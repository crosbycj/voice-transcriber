import Foundation

enum RecordingBarState: Equatable {
    case hidden
    case preparing
    /// `warning` is shown while recording continues, so a dead microphone is noticed within seconds.
    case recording(isLocked: Bool, warning: String?)
    case transcribing
    case notice(String)
    case failed(String)
}
