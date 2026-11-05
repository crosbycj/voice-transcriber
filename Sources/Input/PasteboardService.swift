import AppKit
import ApplicationServices
import Foundation
import OSLog

public enum PasteOutcome: Sendable {
    case pasted
    /// The text is on the clipboard, because this app isn't allowed to press ⌘V.
    case copiedOnly
}

/// Delivers text by borrowing the clipboard for a moment and pressing ⌘V.
@MainActor
public final class PasteboardService {
    private enum Tuning {
        /// There's no way to ask whether an app has finished pasting, and a busy one can take a while to
        /// read the clipboard. Restoring too soon pastes the old clipboard instead of the transcript.
        static let minimumRestoreDelay: Duration = .milliseconds(800)
        static let maximumRestoreDelay: Duration = .milliseconds(3_000)
        static let extraDelayPerThousandCharacters: Duration = .milliseconds(100)
    }

    private struct PendingRestore {
        let snapshot: PasteboardSnapshot
        let changeCount: Int
        let task: Task<Void, Never>
    }

    /// Tells clipboard managers to skip this entry. See nspasteboard.org.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let logger = Logger(subsystem: "com.cooper.VoiceTranscriber", category: "PasteboardService")
    private var pendingRestore: PendingRestore?

    public init() {}

    public func copyText(_ text: String) throws {
        cancelPendingRestore()

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard pasteboard.setString(text, forType: .string) else {
            throw PasteboardServiceError.failedToWritePasteboard
        }
    }

    public func paste(_ text: String) throws -> PasteOutcome {
        // Without this permission the posted ⌘V does nothing, and does so without any error.
        guard AXIsProcessTrusted() else {
            try copyText(text)
            return .copiedOnly
        }

        let pasteboard = NSPasteboard.general

        // While a restore is pending the clipboard holds an earlier transcript, so the saved snapshot is
        // still the user's content. Unless they've copied something since, which is newer than either.
        let pending = cancelPendingRestore()
        let snapshot = pending.flatMap { $0.changeCount == pasteboard.changeCount ? $0.snapshot : nil }
            ?? PasteboardSnapshot.capture(from: pasteboard)

        do {
            pasteboard.clearContents()

            guard pasteboard.setString(text, forType: .string) else {
                throw PasteboardServiceError.failedToWritePasteboard
            }

            pasteboard.setData(Data(), forType: Self.transientType)
            try postPasteShortcut()
        } catch {
            try? snapshot.restore(to: pasteboard)
            throw error
        }

        scheduleRestore(of: snapshot, changeCount: pasteboard.changeCount, textLength: text.count)
        return .pasted
    }

    @discardableResult
    private func cancelPendingRestore() -> PendingRestore? {
        guard let pendingRestore else { return nil }

        pendingRestore.task.cancel()
        self.pendingRestore = nil
        return pendingRestore
    }

    private func scheduleRestore(of snapshot: PasteboardSnapshot, changeCount: Int, textLength: Int) {
        let extraDelay = Tuning.extraDelayPerThousandCharacters * (textLength / 1_000)
        let delay = min(Tuning.minimumRestoreDelay + extraDelay, Tuning.maximumRestoreDelay)

        let task = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            self?.restore(snapshot, ifChangeCountIs: changeCount)
        }

        pendingRestore = PendingRestore(snapshot: snapshot, changeCount: changeCount, task: task)
    }

    private func restore(_ snapshot: PasteboardSnapshot, ifChangeCountIs changeCount: Int) {
        pendingRestore = nil

        let pasteboard = NSPasteboard.general

        // Anything copied in the meantime is newer than what we saved, so it stays.
        guard pasteboard.changeCount == changeCount else { return }

        do {
            try snapshot.restore(to: pasteboard)
        } catch {
            logger.error("Couldn't restore the clipboard: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func postPasteShortcut() throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw PasteboardServiceError.eventSourceUnavailable
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else {
            throw PasteboardServiceError.failedToCreatePasteEvents
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

public enum PasteboardServiceError: LocalizedError {
    case failedToWritePasteboard
    case eventSourceUnavailable
    case failedToCreatePasteEvents
    case failedToRestorePasteboard

    public var errorDescription: String? {
        switch self {
        case .failedToWritePasteboard:
            return "Couldn't copy the transcript to the clipboard."
        case .eventSourceUnavailable, .failedToCreatePasteEvents:
            return "Couldn't press ⌘V to paste."
        case .failedToRestorePasteboard:
            return "Couldn't restore the previous clipboard."
        }
    }
}

private struct PasteboardSnapshot {
    private let items: [PasteboardItemSnapshot]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map(PasteboardItemSnapshot.init)
        return PasteboardSnapshot(items: items)
    }

    private init(items: [PasteboardItemSnapshot]) {
        self.items = items
    }

    func restore(to pasteboard: NSPasteboard) throws {
        pasteboard.clearContents()

        guard !items.isEmpty else { return }

        guard pasteboard.writeObjects(items.map(\.item)) else {
            throw PasteboardServiceError.failedToRestorePasteboard
        }
    }
}

private struct PasteboardItemSnapshot {
    let dataByType: [NSPasteboard.PasteboardType: Data]

    init(item: NSPasteboardItem) {
        var captured: [NSPasteboard.PasteboardType: Data] = [:]
        for type in item.types {
            if let data = item.data(forType: type) {
                captured[type] = data
            }
        }
        dataByType = captured
    }

    var item: NSPasteboardItem {
        let pasteboardItem = NSPasteboardItem()
        for (type, data) in dataByType {
            pasteboardItem.setData(data, forType: type)
        }
        return pasteboardItem
    }
}
