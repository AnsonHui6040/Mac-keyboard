import Foundation

/// Splits text for CGEvent unicode strings without ever cutting a grapheme cluster.
public enum UnicodeChunker {
    public static let defaultMaxUTF16 = 20

    public static func chunks(_ text: String, maxUTF16: Int = defaultMaxUTF16) -> [String] {
        var result: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = character.utf16.count
            if currentUnits > 0, currentUnits + units > maxUTF16 {
                result.append(current)
                current = ""
                currentUnits = 0
            }
            current.append(character)
            currentUnits += units
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
