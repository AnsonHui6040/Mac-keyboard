import Foundation

/// Same ranges as `HanCharacters` in RemoteKeyboardCore (copied so this package has no dependency on it).
public enum Han {
    private static let ranges: [ClosedRange<UInt32>] = [
        0x3400...0x4DBF,
        0x4E00...0x9FFF,
        0xF900...0xFAFF,
        0x20000...0x323AF,
        0x2F800...0x2FA1F
    ]

    public static func isAllHan(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in ranges.contains { $0.contains(scalar.value) } }
    }
}
