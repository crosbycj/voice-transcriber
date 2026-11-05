import Foundation

@MainActor
final class RecordingBarModel: ObservableObject {
    @Published var state: RecordingBarState = .hidden
    @Published var animationPreset: RecordingBarAnimationPreset = .gooeySnap
}
