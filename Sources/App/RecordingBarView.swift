import SwiftUI
import VoiceAudio

struct RecordingBarView: View {
    @ObservedObject var model: RecordingBarModel
    @ObservedObject var amplitudeService: AmplitudeService
    let onCancel: () -> Void
    let onStop: () -> Void
    let onDismissError: () -> Void

    var body: some View {
        ZStack {
            if let pillState = model.state.asMainPillState {
                MainPill(
                    state: pillState,
                    amplitudeService: amplitudeService,
                    animationPreset: model.animationPreset,
                    onCancel: onCancel,
                    onStop: onStop
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.72)),
                        removal: .opacity
                    ))
            }

            if let message = model.state.message {
                MessagePill(message: message, isError: model.state.isFailure, onDismiss: onDismissError)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92)),
                        removal: .opacity
                    ))
            }
        }
        .frame(width: BarMetrics.panelWidth, height: BarMetrics.panelHeight)
        .animation(model.animationPreset.pillAnimation, value: model.state)
    }
}

private enum MainPillVisualState: Equatable {
    case preparing
    case recordingHold(warning: String?)
    case recordingLocked(warning: String?)
    case transcribing

    var warning: String? {
        switch self {
        case .recordingHold(let warning), .recordingLocked(let warning): return warning
        case .preparing, .transcribing: return nil
        }
    }

    var isLocked: Bool {
        if case .recordingLocked = self { return true }
        return false
    }

    var isRecording: Bool {
        switch self {
        case .recordingHold, .recordingLocked: return true
        case .preparing, .transcribing: return false
        }
    }
}

private extension RecordingBarState {
    var asMainPillState: MainPillVisualState? {
        switch self {
        case .preparing: return .preparing
        case .recording(false, let warning): return .recordingHold(warning: warning)
        case .recording(true, let warning): return .recordingLocked(warning: warning)
        case .transcribing: return .transcribing
        case .hidden, .notice, .failed: return nil
        }
    }

    var message: String? {
        switch self {
        case .notice(let message), .failed(let message): return message
        case .hidden, .preparing, .recording, .transcribing: return nil
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

private enum BarPalette {
    static let black = Color(.displayP3, red: 0, green: 0, blue: 0, opacity: 1)
    static let red = Color(.displayP3, red: 1, green: 0.039, blue: 0, opacity: 1)
    static let amber = Color(.displayP3, red: 1, green: 0.611, blue: 0, opacity: 1)
    static let mutedOnRed = Color(.displayP3, red: 1, green: 0.636, blue: 0.568, opacity: 1)
    static let mutedOnAmber = Color(.displayP3, red: 1, green: 0.810, blue: 0.611, opacity: 1)
    static let shadow = Color.black.opacity(0.22)
}

enum BarMetrics {
    static let panelWidth: CGFloat = 300
    static let panelHeight: CGFloat = 60
    static let bottomInset: CGFloat = 24
    static let innerPadding: CGFloat = 2
    static let cellGap: CGFloat = 2
    static let cellSize: CGFloat = 20
    static let waveformWidth: CGFloat = 45
    static let warningMaxWidth: CGFloat = 118
}

// MARK: - Main pill (preparing / recording / transcribing)

private struct MainPill: View {
    let state: MainPillVisualState
    @ObservedObject var amplitudeService: AmplitudeService
    let animationPreset: RecordingBarAnimationPreset
    let onCancel: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: BarMetrics.cellGap) {
            StatusDot(visualState: state)

            if let warning = state.warning {
                Text(warning)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: BarMetrics.warningMaxWidth, alignment: .leading)
                    .transition(.opacity)
            }

            if showsWaveform {
                WaveformView(service: amplitudeService, animationPreset: animationPreset)
                    .padding(.trailing, showsButtons ? 0 : 8)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if showsButtons {
                HoverButton(symbol: "xmark", tint: buttonTint, action: onCancel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                HoverButton(symbol: "checkmark", tint: buttonTint, action: onStop)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(BarMetrics.innerPadding)
        .background(Capsule().fill(pillColor))
        .clipShape(Capsule())
        .shadow(color: BarPalette.shadow, radius: 10, y: 4)
        .contentShape(Capsule())
        .fixedSize()
    }

    private var pillColor: Color {
        if state.warning != nil { return BarPalette.amber }
        return state.isLocked ? BarPalette.red : BarPalette.black
    }

    private var showsWaveform: Bool {
        state.isRecording
    }

    private var showsButtons: Bool {
        state.isLocked
    }

    private var buttonTint: Color {
        state.warning == nil ? BarPalette.mutedOnRed : BarPalette.mutedOnAmber
    }
}

// MARK: - Status dot (spinner or filled, morphs across states)

private struct StatusDot: View {
    let visualState: MainPillVisualState

    var body: some View {
        ZStack {
            SpinnerArc()
                .opacity(isSpinner ? 1 : 0)
                .scaleEffect(isSpinner ? 1 : 0.8)

            Circle()
                .fill(filledDotColor)
                .frame(width: 12, height: 12)
                .opacity(isSpinner ? 0 : 1)
                .scaleEffect(isSpinner ? 0.8 : 1)
        }
        .frame(width: BarMetrics.cellSize, height: BarMetrics.cellSize)
    }

    private var isSpinner: Bool {
        !visualState.isRecording
    }

    private var filledDotColor: Color {
        visualState.isLocked || visualState.warning != nil ? Color.white : BarPalette.red
    }
}

private struct SpinnerArc: View {
    @State private var isSpinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isSpinning)
            .onAppear { isSpinning = true }
    }
}

private struct WaveformView: View {
    @ObservedObject var service: AmplitudeService
    let animationPreset: RecordingBarAnimationPreset

    private let barCount = 8
    private let barWidth: CGFloat = 3
    private let barSpacing: CGFloat = 3
    private let cornerRadius: CGFloat = 1.5
    private let maxBarHeight: CGFloat = 14

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white)
                    .frame(width: barWidth, height: height(at: index))
                    .animation(animationPreset.waveformAnimation, value: amplitude(at: index))
            }
        }
        .frame(width: BarMetrics.waveformWidth, height: BarMetrics.cellSize)
    }

    private func amplitude(at index: Int) -> CGFloat {
        guard service.amplitudes.indices.contains(index) else { return 0 }
        return service.amplitudes[index]
    }

    private func height(at index: Int) -> CGFloat {
        max(2, amplitude(at: index) * maxBarHeight)
    }
}

// MARK: - Message pill

private struct MessagePill: View {
    let message: String
    let isError: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: BarMetrics.cellGap) {
            Text(message)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: BarMetrics.panelWidth - 44, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 6)

            HoverButton(
                symbol: "xmark",
                tint: isError ? BarPalette.mutedOnAmber : Color.white.opacity(0.6),
                action: onDismiss
            )
        }
        .padding(BarMetrics.innerPadding)
        .background(Capsule().fill(isError ? BarPalette.amber : BarPalette.black))
        .clipShape(Capsule())
        .shadow(color: BarPalette.shadow, radius: 10, y: 4)
        .contentShape(Capsule())
    }
}

// MARK: - Hover-aware pill button

private struct HoverButton: View {
    let symbol: String
    let tint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(isHovered ? Color.white : tint)
                .frame(width: BarMetrics.cellSize, height: BarMetrics.cellSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
    }
}

#if DEBUG
@MainActor
struct RecordingBarView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview(name: "Preparing", state: .preparing)
            preview(name: "Hold Recording", state: .recording(isLocked: false, warning: nil))
            preview(name: "Locked Recording", state: .recording(isLocked: true, warning: nil))
            preview(name: "Warning", state: .recording(isLocked: true, warning: "Not hearing you · Studio Display"))
            preview(name: "Transcribing", state: .transcribing)
            preview(name: "Notice", state: .notice("Copied. Press ⌘V to paste."))
            preview(name: "Error", state: .failed("No microphone"))
        }
        .previewLayout(.sizeThatFits)
    }

    private static func preview(name: String, state: RecordingBarState) -> some View {
        let model = RecordingBarModel()
        model.state = state
        let amplitudeService = AmplitudeService()

        return ZStack {
            LinearGradient(
                colors: [
                    Color(.displayP3, red: 0.09, green: 0.11, blue: 0.16, opacity: 1),
                    Color(.displayP3, red: 0.04, green: 0.05, blue: 0.08, opacity: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RecordingBarView(
                model: model,
                amplitudeService: amplitudeService,
                onCancel: {},
                onStop: {},
                onDismissError: {}
            )
        }
        .frame(width: 320, height: 120)
        .previewDisplayName(name)
    }
}
#endif
