import AppKit
import ApplicationServices
import Foundation
import OSLog
import RemoteKeyboardCore

/// Watches the system-wide keyboard focus through Accessibility and publishes a `FocusSnapshot`.
///
/// Epoch rule: `epoch` increases by one whenever the frontmost PID or the focused UI element changes
/// (including gaining or losing a focused element). Every read error fails closed (`editable == false`).
@MainActor
final class FocusMonitor: ObservableObject {
    static let pollInterval: TimeInterval = 0.25
    /// Upper bound for any single AX call; a hung target app must not stall the Receiver.
    static let axTimeout: Float = 0.25
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "focus")

    /// Roles that take typed text.
    nonisolated static let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    @Published private(set) var snapshot: FocusSnapshot?
    /// Called with each snapshot that differs from the previous one, after `snapshot` is updated.
    var onChange: ((FocusSnapshot) -> Void)?

    private var epoch: UInt64 = 0
    private var lastPID: Int32?
    private var lastElement: AXUIElement?
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    /// The element read by the latest `refreshNow()`; `nil` when untrusted, nothing focused, or Receiver itself is frontmost.
    var focusedElement: AXUIElement? { lastElement }

    /// Pure classification, kept free of AX types so it can be unit tested.
    nonisolated static func isEditable(role: String?, valueSettable: Bool) -> Bool {
        if let role, editableRoles.contains(role) { return true }
        return valueSettable
    }

    /// No AX reads when untrusted, with no frontmost app, or when we are frontmost ourselves: the Receiver's own
    /// windows are never an injection target (and reading them would risk an AX call back into this process).
    nonisolated static func shouldReadFocus(trusted: Bool, pid: Int32, ownPID: Int32) -> Bool {
        trusted && pid != 0 && pid != ownPID
    }

    // MARK: Lifecycle

    func start() {
        guard pollTimer == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refreshNow() }
        }
        pollTimer = CommonModeTimer.make(Self.pollInterval, repeats: true) { [weak self] in
            _ = self?.refreshNow()
        }
        _ = refreshNow()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// Shows the system Accessibility prompt. Only called on explicit user action, never at launch.
    func requestTrustPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Reading

    /// Forces an immediate AX read (bypassing the 250 ms cache) and returns the fresh snapshot.
    @discardableResult
    func refreshNow() -> FocusSnapshot {
        let trusted = AXIsProcessTrusted()
        let app = NSWorkspace.shared.frontmostApplication
        let pid = app?.processIdentifier ?? 0

        var element: AXUIElement?
        var editable = false
        if Self.shouldReadFocus(trusted: trusted, pid: pid, ownPID: ProcessInfo.processInfo.processIdentifier) {
            (element, editable) = Self.readFocus(pid: pid)
        }

        let pidChanged = lastPID != pid
        let elementChanged = !Self.sameElement(lastElement, element)
        if pidChanged || elementChanged {
            epoch += 1
            Self.log.info("focus changed epoch \(self.epoch, privacy: .public) editable \(editable, privacy: .public)")
        }
        lastPID = pid
        lastElement = element

        let next = FocusSnapshot(
            axTrusted: trusted, frontmostPID: pid, appName: app?.localizedName, editable: editable, epoch: epoch
        )
        if next != snapshot {
            snapshot = next
            onChange?(next)
        }
        return next
    }

    private static func sameElement(_ a: AXUIElement?, _ b: AXUIElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): CFEqual(a, b)
        default: false
        }
    }

    /// Any AX error or timeout yields `(nil or element, false)`.
    private static func readFocus(pid: pid_t) -> (AXUIElement?, Bool) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, axTimeout)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return (nil, false) }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, axTimeout)

        var roleRef: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
            ? roleRef as? String : nil

        // A text role already qualifies, so the value (the whole document, for a text area) is never copied for it.
        if let role, editableRoles.contains(role) { return (element, true) }

        // A settable value only counts when it is text; sliders and checkboxes settle numbers, not typed characters.
        var settable: DarwinBoolean = false
        var valueSettable = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            var valueRef: CFTypeRef?
            valueSettable = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success
                && valueRef is String
        }
        return (element, isEditable(role: role, valueSettable: valueSettable))
    }
}

/// Menu copy for the focus state, Taiwan Traditional Chinese.
enum FocusMenuText {
    static func line(_ snapshot: FocusSnapshot?) -> String {
        guard let snapshot else { return "焦點：讀取中" }
        guard snapshot.axTrusted else { return "輔助使用未授權" }
        let name = snapshot.appName ?? "未知"
        let state = snapshot.editable ? "可編輯" : "不可編輯"
        return "焦點：\(name)（\(state)，epoch \(snapshot.epoch)）"
    }

    static func reason(_ decision: InjectionDecision) -> String {
        switch decision {
        case .allow: "可插入"
        case .notAuthorized: "輔助使用未授權"
        case .noFocus: "目前焦點不可編輯"
        case .staleFocus: "焦點已改變"
        }
    }
}
