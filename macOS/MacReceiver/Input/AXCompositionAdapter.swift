import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import RemoteKeyboardCore

/// Reads and cancels an open IME composition on the focused element through Accessibility.
@MainActor
final class AXCompositionAdapter: CompositionControlling {
    /// `AXTextInputMarkedTextMarkerRange` from AXWebConstants.h; not exported as a Swift constant.
    nonisolated static let markedRangeAttribute = "AXTextInputMarkedTextMarkerRange"
    nonisolated static let escapeKey: CGKeyCode = 53
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "composition")

    private let element: @MainActor () -> AXUIElement?
    private let poster: EventPosting

    /// - Parameter element: the focused element to inspect; `nil` reads as `.unknown`.
    init(element: @escaping @MainActor () -> AXUIElement?, poster: EventPosting = HIDEventPoster()) {
        self.element = element
        self.poster = poster
    }

    /// Pure mapping of one AX read. A value means composing; a supported attribute without one means not composing;
    /// an unsupported attribute, a timeout or any other error cannot say, so it is `.unknown`.
    nonisolated static func state(error: AXError, hasValue: Bool) -> CompositionState {
        switch error {
        case .success: hasValue ? .composing : .notComposing
        case .noValue: .notComposing
        default: .unknown
        }
    }

    func state() -> CompositionState {
        guard let element = element() else { return .unknown }
        AXUIElementSetMessagingTimeout(element, FocusMonitor.axTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, Self.markedRangeAttribute as CFString, &value)
        let result = Self.state(error: error, hasValue: value != nil)
        // Error code and result only; the field content is never read here.
        Self.log.info("composition ax \(error.rawValue, privacy: .public) \(String(describing: result), privacy: .public)")
        return result
    }

    /// Escape ends an open composition in the focused app. Goes through the posting seam.
    func cancel() {
        let events = TextInjector.makeKeyEvents(virtualKey: Self.escapeKey)
        guard !events.isEmpty else { return }
        poster.post(events)
    }
}
