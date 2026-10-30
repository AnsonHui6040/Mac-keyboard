/// The key layers of the symbols page. A layer is rows of single-character keys: two rows of ten and one of five.
/// The layer key (left of row 3) cycles through the layers; delete sits on the right.
public enum SymbolLayouts {
    private static let englishOne = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""],
        [".", ",", "?", "!", "'"],
    ]
    private static let englishTwo = [
        ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
        ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"],
        [".", ",", "?", "!", "'"],
    ]
    private static let chineseOne = [
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
        ["「", "」", "『", "』", "（", "）", "：", "；", "、", "～"],
        ["，", "。", "？", "！", "…"],
    ]

    /// Layers (first to last), each as rows of keys. English has two layers; Chinese has three.
    public static func layers(for origin: SymbolOrigin) -> [[[String]]] {
        switch origin {
        case .english: [englishOne, englishTwo]
        case .chinese: [chineseOne, englishOne, englishTwo]
        }
    }

    /// What the layer key shows on each layer: the name of the layer it switches to.
    public static func layerKeyTitles(for origin: SymbolOrigin) -> [String] {
        switch origin {
        case .english: ["#+=", "123"]
        case .chinese: ["半形", "#+=", "全形"]
        }
    }
}
