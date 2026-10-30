/// The 26 Cangjie radicals shown on the key faces and in the input code row. Fixed table.
public enum CangjieRadicals {
    public static let byLetter: [Character: String] = [
        "a": "日", "b": "月", "c": "金", "d": "木", "e": "水", "f": "火", "g": "土", "h": "竹", "i": "戈",
        "j": "十", "k": "大", "l": "中", "m": "一", "n": "弓", "o": "人", "p": "心", "q": "手", "r": "口",
        "s": "尸", "t": "廿", "u": "山", "v": "女", "w": "田", "x": "難", "y": "卜", "z": "重"
    ]

    /// The radicals for an input code (`ab` becomes 日月); letters without a radical are skipped.
    public static func display(for code: String) -> String {
        code.compactMap { byLetter[$0] }.joined()
    }
}
