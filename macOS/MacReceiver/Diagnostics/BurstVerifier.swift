#if DEBUG
import AppKit
import ApplicationServices
import OSLog
import RemoteKeyboardCore

/// What reading the TextEdit document gave.
enum BurstTextReadResult: Equatable, Sendable {
    case text(String)
    case notTrusted
    case noTextEdit
    case noDocument
}

protocol BurstTextReading: Sendable {
    func read() -> BurstTextReadResult
}

/// Reads the text of TextEdit's focused document through Accessibility.
struct TextEditAXReader: BurstTextReading {
    static let bundleIdentifier = "com.apple.TextEdit"
    /// A 10,000 line document is about 60 KB; give the read more room than the 0.25 s of the focus poll.
    static let timeout: Float = 5

    func read() -> BurstTextReadResult {
        guard AXIsProcessTrusted() else { return .notTrusted }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first
        else { return .noTextEdit }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, Self.timeout)
        if let focused = element(application, kAXFocusedUIElementAttribute), let text = value(of: focused) {
            return .text(text)
        }
        if let window = element(application, kAXFocusedWindowAttribute) ?? element(application, kAXMainWindowAttribute),
           let area = firstTextArea(in: window, depth: 0), let text = value(of: area) {
            return .text(text)
        }
        return .noDocument
    }

    private func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement) // swiftlint:disable:this force_cast
    }

    private func value(of element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, Self.timeout)
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
              (role as? String) == kAXTextAreaRole as String
        else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func firstTextArea(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 6 else { return nil }
        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           (role as? String) == kAXTextAreaRole as String {
            return element
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement]
        else { return nil }
        for child in list {
            if let found = firstTextArea(in: child, depth: depth + 1) { return found }
        }
        return nil
    }
}

/// T15 debug check: reads TextEdit's document and counts what the burst left in it. The panel shows numbers only and
/// the log carries counts only; the document text is never stored, shown or logged.
@MainActor
final class BurstVerifier: ObservableObject {
    static let expectedLines = 10_000
    private nonisolated static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "burst")

    @Published private(set) var status = "尚未驗證"
    @Published private(set) var isRunning = false

    private let reader: BurstTextReading
    private let expected: Int

    init(reader: BurstTextReading = TextEditAXReader(), expected: Int = BurstVerifier.expectedLines) {
        self.reader = reader
        self.expected = expected
    }

    func verify() {
        guard !isRunning else { return }
        isRunning = true
        status = "驗證中…"
        let reader = reader
        let expected = expected
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { reader.read() }.value
            self?.finish(Self.message(for: result, expected: expected))
        }
    }

    private func finish(_ message: String) {
        Self.log.info("burst verify done")
        status = message
        isRunning = false
    }

    /// The panel line for one read. Numbers and fixed words only.
    nonisolated static func message(for result: BurstTextReadResult, expected: Int) -> String {
        switch result {
        case .notTrusted: return "Mac 未授權輔助使用"
        case .noTextEdit: return "找不到 TextEdit"
        case .noDocument: return "TextEdit 沒有可讀的文件"
        case .text(let text):
            let report = BurstFormat.verify(text, expected: expected)
            log.info("burst report expected=\(expected, privacy: .public) missing=\(report.missing.count, privacy: .public) duplicated=\(report.duplicated.count, privacy: .public) outOfOrder=\(report.outOfOrder.count, privacy: .public)")
            return "預期 \(expected) 行，遺漏 \(report.missing.count)，重複 \(report.duplicated.count)，亂序 \(report.outOfOrder.count)"
        }
    }
}
#endif
