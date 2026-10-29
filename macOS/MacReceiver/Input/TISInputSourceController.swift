import Carbon
import Foundation
import RemoteKeyboardCore

/// Text Input Source Services behind `InputSourceControlling`.
@MainActor
final class TISInputSourceController: InputSourceControlling {
    func currentID() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "" }
        return Self.id(of: source) ?? ""
    }

    /// Selects an enabled input source by ID. False when it is not enabled or the call fails.
    func select(_ id: String) -> Bool {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue(),
              let sources = list as? [TISInputSource], let source = sources.first
        else { return false }
        return TISSelectInputSource(source) == noErr
    }

    private static func id(of source: TISInputSource) -> String? {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }
}
