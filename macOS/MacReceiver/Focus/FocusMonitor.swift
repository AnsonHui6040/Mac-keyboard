import AppKit
import ApplicationServices
import Foundation
import OSLog
import RemoteKeyboardCore

/// The element found by one AX read and whether it takes typed text. `AXUIElement` is a thread safe CF object that is
/// only ever read after it is handed back, so crossing actors is safe.
struct FocusReadResult: @unchecked Sendable {
    let element: AXUIElement?
    let editable: Bool
}

/// Seam over the blocking AX walk so it can run off the main thread and be replaced in tests.
protocol FocusReading: Sendable {
    func read(pid: pid_t) -> FocusReadResult
}

/// What the monitor asks the system on the main actor (cheap calls only; the AX walk is the reader's job).
struct FocusEnvironment {
    let trusted: @MainActor () -> Bool
    let frontmost: @MainActor () -> (pid: Int32, name: String?)
    let ownPID: Int32

    @MainActor static var live: FocusEnvironment {
        FocusEnvironment(
            trusted: { AXIsProcessTrusted() },
            frontmost: {
                let app = NSWorkspace.shared.frontmostApplication
                return (app?.processIdentifier ?? 0, app?.localizedName)
            },
            ownPID: ProcessInfo.processInfo.processIdentifier
        )
    }
}

/// Watches the system-wide keyboard focus through Accessibility and publishes a `FocusSnapshot`.
///
/// Epoch rule: `epoch` increases by one whenever the frontmost PID or the focused UI element changes
/// (including gaining or losing a focused element). Every read error fails closed (`editable == false`).
///
/// The AX walk runs on a background queue, so a hung target app cannot stall the main thread (and with it the
/// Bluetooth callbacks). Reads are applied in the order they were started: a read that finishes after a newer one was
/// applied is discarded and the newer snapshot is returned.
@MainActor
final class FocusMonitor: ObservableObject {
    static let pollInterval: TimeInterval = 0.25
    /// Upper bound for any single AX call; a hung target app must not stall the Receiver.
    nonisolated static let axTimeout: Float = 0.25
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
    private let reader: FocusReading
    private let environment: FocusEnvironment
    private var startedReads: UInt64 = 0
    private var appliedRead: UInt64 = 0
    private var pollInFlight = false

    init(reader: FocusReading = AXFocusReader(), environment: FocusEnvironment = .live) {
        self.reader = reader
        self.environment = environment
    }

    /// Whether Accessibility is trusted right now; a cheap call that does not walk the focus tree.
    var isTrusted: Bool { environment.trusted() }

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
            MainActor.assumeIsolated { Task { _ = await self?.refreshNow() } }
        }
        pollTimer = CommonModeTimer.make(Self.pollInterval, repeats: true) { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
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

    /// One poll at a time: a slow read must not queue up a pile of further reads behind it.
    private func poll() {
        guard !pollInFlight else { return }
        pollInFlight = true
        Task {
            _ = await refreshNow()
            pollInFlight = false
        }
    }

    /// Forces an immediate AX read (bypassing the 250 ms poll) and returns the fresh snapshot. The read itself runs off
    /// the main thread; the caller is suspended, not blocked.
    @discardableResult
    func refreshNow() async -> FocusSnapshot {
        let trusted = environment.trusted()
        var (pid, name) = environment.frontmost()
        startedReads &+= 1
        let ticket = startedReads

        var result = FocusReadResult(element: nil, editable: false)
        if Self.shouldReadFocus(trusted: trusted, pid: pid, ownPID: environment.ownPID) {
            let reader = reader
            result = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: reader.read(pid: pid))
                }
            }
        }
        // The user may have switched apps while the walk was running; the element then belongs to the old app.
        // Fail closed: nothing is editable and the epoch moves on.
        let now = environment.frontmost()
        if now.pid != pid {
            result = FocusReadResult(element: nil, editable: false)
            pid = now.pid
            name = now.name
        }
        // A newer read already landed; applying this older one would move the epoch backwards in time.
        if ticket < appliedRead, let current = snapshot { return current }
        appliedRead = ticket
        let element = result.element
        let editable = result.editable

        let pidChanged = lastPID != pid
        let elementChanged = !Self.sameElement(lastElement, element)
        if pidChanged || elementChanged {
            epoch += 1
            Self.log.info("focus changed epoch \(self.epoch, privacy: .public) editable \(editable, privacy: .public)")
        }
        lastPID = pid
        lastElement = element

        let next = FocusSnapshot(
            axTrusted: trusted, frontmostPID: pid, appName: name, editable: editable, epoch: epoch
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
}

/// The real AX walk. Nonisolated and blocking: always call it off the main thread.
struct AXFocusReader: FocusReading {
    private static let axTimeout = FocusMonitor.axTimeout
    private static let editableRoles = FocusMonitor.editableRoles

    func read(pid: pid_t) -> FocusReadResult {
        let (element, editable) = Self.readFocus(pid: pid)
        return FocusReadResult(element: element, editable: editable)
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
        return (element, FocusMonitor.isEditable(role: role, valueSettable: valueSettable))
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
