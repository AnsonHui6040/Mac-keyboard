import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import OSLog
import RemoteKeyboardCore

/// The element found by one AX read, whether it takes typed text, and whether it is a password field (subrole read as
/// AXSecureTextField; a subrole that could not be read is not reported as one). `AXUIElement` is a thread safe CF object
/// that is only ever read after it is handed back, so crossing actors is safe.
struct FocusReadResult: @unchecked Sendable {
    let element: AXUIElement?
    let editable: Bool
    let secure: Bool

    init(element: AXUIElement?, editable: Bool, secure: Bool = false) {
        self.element = element
        self.editable = editable
        self.secure = secure
    }
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
    /// True while typing must not go anywhere: secure keyboard input is on (a password field somewhere) or the screen is locked.
    var inputBlocked: @MainActor () -> Bool = { false }

    /// `CGSessionCopyCurrentDictionary()` says the screen is locked with `CGSSessionScreenIsLocked`. Pure so it can be tested.
    nonisolated static func screenLocked(session: [String: Any]?) -> Bool {
        (session?["CGSSessionScreenIsLocked"] as? Bool) == true
    }

    @MainActor static var live: FocusEnvironment {
        FocusEnvironment(
            trusted: { AXIsProcessTrusted() },
            frontmost: {
                let app = NSWorkspace.shared.frontmostApplication
                return (app?.processIdentifier ?? 0, app?.localizedName)
            },
            ownPID: ProcessInfo.processInfo.processIdentifier,
            inputBlocked: {
                IsSecureEventInputEnabled() || screenLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
            }
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
    /// How often focus is polled: fast while an iPhone is connected and authenticated, slow otherwise so an idle Receiver
    /// does not keep asking the frontmost app for Accessibility data. App switches are caught by the activation notification.
    nonisolated static func pollInterval(linkActive: Bool) -> TimeInterval { linkActive ? 0.25 : 2.0 }
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
    /// An iPhone is connected and authenticated.
    private(set) var isLinkActive = false
    /// The interval of the running poll timer; `nil` while not started.
    var scheduledPollInterval: TimeInterval? { pollTimer?.timeInterval }
    /// The running poll timer, so a test can tell whether it was replaced.
    var scheduledTimerForTesting: Timer? { pollTimer }

    init(reader: FocusReading = AXFocusReader(), environment: FocusEnvironment = .live) {
        self.reader = reader
        self.environment = environment
    }

    /// Whether Accessibility is trusted right now; a cheap call that does not walk the focus tree.
    var isTrusted: Bool { environment.trusted() }

    /// The element read by the latest `refreshNow()`; `nil` when untrusted, nothing focused, or Receiver itself is frontmost.
    var focusedElement: AXUIElement? { lastElement }

    /// A password field has role AXTextField, so the subrole is what tells it apart.
    nonisolated static let secureSubrole = "AXSecureTextField"

    /// Pure classification, kept free of AX types so it can be unit tested. A secure field is never editable, whatever
    /// its role says and even when its value is settable.
    nonisolated static func isEditable(role: String?, subrole: String? = nil, valueSettable: Bool) -> Bool {
        if subrole == secureSubrole { return false }
        if let role, editableRoles.contains(role) { return true }
        return valueSettable
    }

    /// The same decision when the subrole came from a read that may have failed; an unreadable subrole is not editable.
    /// The reader takes the shortcuts below (no value copy for text roles) but must agree with this.
    nonisolated static func isEditable(role: String?, subroleRead: SubroleRead, valueSettable: Bool) -> Bool {
        guard case .value(let subrole) = subroleRead else { return false }
        return isEditable(role: role, subrole: subrole, valueSettable: valueSettable)
    }

    /// What reading the subrole attribute told us. A subrole the element simply does not have is not secure; any other
    /// error means we cannot tell whether it is, so it fails closed.
    enum SubroleRead: Equatable {
        case value(String?)
        case unreadable
    }

    /// Whether a read subrole says password field. An unreadable one is a guess, so it does not.
    nonisolated static func isSecure(subroleRead: SubroleRead) -> Bool {
        guard case .value(let subrole) = subroleRead else { return false }
        return subrole == secureSubrole
    }

    nonisolated static func subroleRead(error: AXError, value: String?) -> SubroleRead {
        switch error {
        case .success: .value(value)
        case .noValue, .attributeUnsupported: .value(nil)
        default: .unreadable
        }
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
        schedulePollTimer()
        poll()
    }

    private func schedulePollTimer() {
        pollTimer?.invalidate()
        pollTimer = CommonModeTimer.make(Self.pollInterval(linkActive: isLinkActive), repeats: true) { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// The link to the iPhone became authenticated or was lost. Reschedules the poll only when the interval changes, and
    /// reads at once when it becomes active so the first status after connecting is fresh.
    func setLinkActive(_ active: Bool) {
        let was = isLinkActive
        isLinkActive = active
        guard pollTimer != nil else { return }
        if Self.pollInterval(linkActive: was) != Self.pollInterval(linkActive: active) { schedulePollTimer() }
        if active, !was { poll() }
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
        // Secure input or a locked screen: nothing is editable, but the epoch rule above is not touched. A password field
        // or either of those also tells the keyboard why, so it can say so instead of "no input field".
        let environmentBlocked = environment.inputBlocked()
        let editable = result.editable && !environmentBlocked
        let inputBlocked = result.secure || environmentBlocked

        let pidChanged = lastPID != pid
        let elementChanged = !Self.sameElement(lastElement, element)
        if pidChanged || elementChanged {
            epoch += 1
            Self.log.info("focus changed epoch \(self.epoch, privacy: .public) editable \(editable, privacy: .public)")
        }
        lastPID = pid
        lastElement = element

        let next = FocusSnapshot(
            axTrusted: trusted, frontmostPID: pid, appName: name, editable: editable, epoch: epoch, inputBlocked: inputBlocked
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
        let (element, editable, secure) = Self.readFocus(pid: pid)
        return FocusReadResult(element: element, editable: editable, secure: secure)
    }

    /// Any AX error or timeout yields `(nil or element, false, false)`; only a subrole read as secure sets the last flag.
    private static func readFocus(pid: pid_t) -> (AXUIElement?, Bool, Bool) {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, axTimeout)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return (nil, false, false) }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, axTimeout)

        var roleRef: CFTypeRef?
        let role = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success
            ? roleRef as? String : nil

        // The subrole comes first: a password field is an AXTextField. Only the subrole string is read, never the value.
        var subroleRef: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = FocusMonitor.subroleRead(error: subroleError, value: subroleRef as? String)
        guard case .value(let subroleName) = subrole else { return (element, false, false) }
        if FocusMonitor.isSecure(subroleRead: subrole) { return (element, false, true) }

        // A text role already qualifies, so the value (the whole document, for a text area) is never copied for it.
        if let role, editableRoles.contains(role) { return (element, true, false) }

        // A settable value only counts when it is text; sliders and checkboxes settle numbers, not typed characters.
        var settable: DarwinBoolean = false
        var valueSettable = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            var valueRef: CFTypeRef?
            valueSettable = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success
                && valueRef is String
        }
        return (element, FocusMonitor.isEditable(role: role, subrole: subroleName, valueSettable: valueSettable), false)
    }
}

/// Menu copy for the focus state, Taiwan Traditional Chinese.
enum FocusMenuText {
    static func line(_ snapshot: FocusSnapshot?) -> String {
        guard let snapshot else { return "目前欄位：讀取中" }
        guard snapshot.axTrusted else { return "目前欄位：無法讀取（尚未授權輔助使用）" }
        let name = snapshot.appName ?? "未知的 App"
        let state = snapshot.editable ? "可輸入" : "不可輸入"
        return "目前欄位：\(name)（\(state)）"
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
