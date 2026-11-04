import Foundation

/// Splits text for CGEvent unicode strings without cutting a grapheme cluster. The one exception is a single Character that is
/// longer than the limit by itself (a base letter with dozens of combining marks): it is split on unicode scalar boundaries,
/// because one over-limit chunk may be truncated by CGEvent. A scalar is never cut, so a chunk can pass a limit below 2.
public enum UnicodeChunker {
    public static let defaultMaxUTF16 = 20

    public static func chunks(_ text: String, maxUTF16: Int = defaultMaxUTF16) -> [String] {
        var result: [String] = []
        var current = ""
        var currentUnits = 0
        for character in text {
            let units = character.utf16.count
            if units > maxUTF16 {
                if !current.isEmpty { result.append(current) }
                current = ""
                currentUnits = 0
                result.append(contentsOf: splitScalars(of: character, maxUTF16: maxUTF16))
                continue
            }
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

    private static func splitScalars(of character: Character, maxUTF16: Int) -> [String] {
        var pieces: [String] = []
        var piece = String.UnicodeScalarView()
        var pieceUnits = 0
        for scalar in character.unicodeScalars {
            let units = scalar.utf16.count
            if pieceUnits > 0, pieceUnits + units > maxUTF16 {
                pieces.append(String(piece))
                piece = String.UnicodeScalarView()
                pieceUnits = 0
            }
            piece.append(scalar)
            pieceUnits += units
        }
        if !piece.isEmpty { pieces.append(String(piece)) }
        return pieces
    }
}
