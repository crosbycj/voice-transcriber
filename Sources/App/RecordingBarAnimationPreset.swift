import SwiftUI

enum RecordingBarAnimationPreset: String, CaseIterable, Identifiable {
    case snappy
    case quickGooey = "quick-gooey"
    case gooeySnap = "gooey-snap"
    case gooey

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .snappy: return "Crisp"
        case .quickGooey: return "Elastic"
        case .gooeySnap: return "Gooey Snap"
        case .gooey: return "Mellow"
        }
    }

    var pillAnimation: Animation {
        switch self {
        case .snappy:
            return .spring(response: 0.16, dampingFraction: 0.66, blendDuration: 0.02)
        case .quickGooey:
            return .spring(response: 0.22, dampingFraction: 0.52, blendDuration: 0.03)
        case .gooeySnap:
            return .spring(response: 0.19, dampingFraction: 0.46, blendDuration: 0.03)
        case .gooey:
            return .spring(response: 0.34, dampingFraction: 0.52, blendDuration: 0.05)
        }
    }

    var waveformAnimation: Animation {
        switch self {
        case .snappy:
            return .spring(response: 0.15, dampingFraction: 0.76, blendDuration: 0.01)
        case .quickGooey:
            return .spring(response: 0.19, dampingFraction: 0.70, blendDuration: 0.02)
        case .gooeySnap:
            return .spring(response: 0.17, dampingFraction: 0.64, blendDuration: 0.02)
        case .gooey:
            return .spring(response: 0.24, dampingFraction: 0.72, blendDuration: 0.02)
        }
    }

    init(storedValue: String?) {
        switch storedValue {
        case "very-snappy":
            self = .snappy
        case "balanced":
            self = .quickGooey
        case "bouncy":
            self = .gooey
        default:
            self = storedValue.flatMap(Self.init(rawValue:)) ?? .gooeySnap
        }
    }
}
