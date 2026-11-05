import ApplicationServices
import Foundation
import IOKit.hidsystem

public enum VoiceHotkeyAction: Sendable {
    case startHoldRecording
    case stopHoldRecording
    case lockCurrentRecording
    case stopLockedRecording
    /// Another key was pressed with fn held, so this may be a shortcut like fn+Delete rather than dictation.
    case functionKeyCombination
    case pasteVoiceClipboard
}

public enum HotkeySessionState: Sendable {
    case idle
    case preparingHold
    case recordingHold
    case recordingLocked
    case transcribing
}

public enum HotkeyPermissionAccess: Sendable {
    case granted
    case denied
    case unknown
}

public struct HotkeyPermissionStatus: Sendable {
    public let accessibilityGranted: Bool
    public let inputMonitoring: HotkeyPermissionAccess

    public init(
        accessibilityGranted: Bool = false,
        inputMonitoring: HotkeyPermissionAccess = .unknown
    ) {
        self.accessibilityGranted = accessibilityGranted
        self.inputMonitoring = inputMonitoring
    }

    public var canMonitorHotkeys: Bool {
        accessibilityGranted && inputMonitoring == .granted
    }
}

/// Watches the global keyboard through an event tap on the main run loop.
///
/// Actions are delivered synchronously, so the session state this reads for the next event already
/// reflects the last one. Deferring them lets a quick press and release race the state they depend on.
@MainActor
public final class HotkeyMonitor {
    public var actionHandler: ((VoiceHotkeyAction) -> Void)?
    public var sessionStateProvider: (() -> HotkeySessionState)?
    public var permissionStatusHandler: ((HotkeyPermissionStatus) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityRetryTimer: Timer?
    private var isFunctionKeyPressed = false
    private var suppressFunctionKeyRelease = false

    public init() {}

    @discardableResult
    public func start(promptForPermissions: Bool = true) -> Bool {
        guard eventTap == nil else { return true }

        let permissionStatus = permissionStatus(prompt: promptForPermissions)
        guard permissionStatus.canMonitorHotkeys else {
            schedulePermissionRetry()
            return false
        }

        guard let tap = createEventTap() else {
            schedulePermissionRetry()
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        accessibilityRetryTimer?.invalidate()
        accessibilityRetryTimer = nil
        eventTap = tap
        runLoopSource = source
        return true
    }

    public func stop() {
        accessibilityRetryTimer?.invalidate()
        accessibilityRetryTimer = nil

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }

        runLoopSource = nil
        eventTap = nil
        isFunctionKeyPressed = false
        suppressFunctionKeyRelease = false
    }

    @discardableResult
    public func requestAccessibilityPermission(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public func permissionStatus(prompt: Bool = false) -> HotkeyPermissionStatus {
        let status = HotkeyPermissionStatus(
            accessibilityGranted: requestAccessibilityPermission(prompt: prompt),
            inputMonitoring: inputMonitoringPermission(prompt: prompt)
        )
        permissionStatusHandler?(status)
        return status
    }

    private func createEventTap() -> CFMachPort? {
        let events: CGEventMask =
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue) |
            (CGEventMask(1) << CGEventType.keyDown.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let event = UncheckedEvent(event: event)
            let monitorPointer = UncheckedPointer(pointer: userInfo)

            return MainActor.assumeIsolated {
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(monitorPointer.pointer).takeUnretainedValue()
                return monitor.handleEvent(type: type, event: event.event).map(UncheckedResult.init)
            }?.result
        }

        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        return CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: events,
            callback: callback,
            userInfo: userInfo
        )
    }

    private func inputMonitoringPermission(prompt: Bool) -> HotkeyPermissionAccess {
        let currentAccess = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)

        if currentAccess == kIOHIDAccessTypeGranted {
            return .granted
        }

        if prompt {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        default:
            return .unknown
        }
    }

    private func schedulePermissionRetry() {
        guard accessibilityRetryTimer == nil else { return }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retryAfterPermissionChange()
            }
        }

        accessibilityRetryTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func retryAfterPermissionChange() {
        guard eventTap == nil else {
            accessibilityRetryTimer?.invalidate()
            accessibilityRetryTimer = nil
            return
        }

        guard permissionStatus(prompt: false).canMonitorHotkeys else {
            return
        }

        accessibilityRetryTimer?.invalidate()
        accessibilityRetryTimer = nil
        _ = start(promptForPermissions: false)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            resynchronizeFunctionKey()
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            return handleFlagsChanged(event)
        case .keyDown:
            return handleKeyDown(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let functionKeyPressed = event.flags.contains(.maskSecondaryFn)
        guard functionKeyPressed != isFunctionKeyPressed else {
            return Unmanaged.passUnretained(event)
        }

        isFunctionKeyPressed = functionKeyPressed

        if functionKeyPressed {
            handleFunctionKeyPressed()
        } else {
            handleFunctionKeyReleased()
        }

        return nil
    }

    /// Events are lost while the tap is disabled. Catch up, or a hold recording would never see its release.
    private func resynchronizeFunctionKey() {
        let isPressed = CGEventSource.flagsState(.combinedSessionState).contains(.maskSecondaryFn)
        guard isPressed != isFunctionKeyPressed else { return }

        isFunctionKeyPressed = isPressed

        if !isPressed {
            handleFunctionKeyReleased()
        }
    }

    private func handleFunctionKeyPressed() {
        switch sessionStateProvider?() ?? .idle {
        case .idle, .transcribing:
            suppressFunctionKeyRelease = false
            actionHandler?(.startHoldRecording)
        case .recordingLocked:
            suppressFunctionKeyRelease = true
            actionHandler?(.stopLockedRecording)
        case .preparingHold, .recordingHold:
            break
        }
    }

    private func handleFunctionKeyReleased() {
        defer {
            suppressFunctionKeyRelease = false
        }

        guard !suppressFunctionKeyRelease else { return }

        let sessionState = sessionStateProvider?() ?? .idle
        if sessionState == .preparingHold || sessionState == .recordingHold || sessionState == .transcribing {
            actionHandler?(.stopHoldRecording)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        let sessionState = sessionStateProvider?() ?? .idle
        let isHolding = isFunctionKeyPressed && sessionState != .idle && sessionState != .recordingLocked

        // fn+Space has to work while the microphone is still starting. Missing it there would type a
        // space, then cancel on release, while the speaker carries on believing they're locked in.
        if isHolding, keyCode == KeyCode.space {
            suppressFunctionKeyRelease = true
            actionHandler?(.lockCurrentRecording)
            return nil
        }

        if keyCode == KeyCode.v, matchesVoiceClipboardShortcut(flags: event.flags) {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                actionHandler?(.pasteVoiceClipboard)
            }
            return nil
        }

        if isHolding {
            actionHandler?(.functionKeyCombination)
        }

        return Unmanaged.passUnretained(event)
    }

    private func matchesVoiceClipboardShortcut(flags: CGEventFlags) -> Bool {
        let relevant = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        return relevant == [.maskCommand, .maskControl]
    }
}

private enum KeyCode {
    static let space: Int64 = 49
    static let v: Int64 = 9
}

// The event tap callback runs on the main run loop, but its C signature can't say so.
private struct UncheckedEvent: @unchecked Sendable {
    let event: CGEvent
}

private struct UncheckedPointer: @unchecked Sendable {
    let pointer: UnsafeMutableRawPointer
}

private struct UncheckedResult: @unchecked Sendable {
    let result: Unmanaged<CGEvent>
}
