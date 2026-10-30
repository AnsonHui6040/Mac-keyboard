public enum SymbolOrigin: Equatable, Sendable {
    case chinese
    case english
}

public enum KeyboardPage: Equatable, Sendable {
    case chinese
    case english
    /// The symbols page remembers the letter page it was opened from.
    case symbols(origin: SymbolOrigin)

    /// The letter page this page belongs to: itself, or the origin of the symbols page.
    var letterPage: KeyboardPage {
        switch self {
        case .chinese, .english: self
        case .symbols(let origin): origin == .chinese ? .chinese : .english
        }
    }

    /// Persisted as `rk.page`: only the letter page, never the symbols page.
    public var storageValue: String { letterPage == .chinese ? "chinese" : "english" }

    public static func stored(rawValue: String?) -> KeyboardPage? {
        switch rawValue {
        case "chinese": .chinese
        case "english": .english
        default: nil
        }
    }
}

/// What the text field asks for, mapped from `UIKeyboardType` by the keyboard.
public enum FieldKind: Sendable {
    case text
    case emailOrURL
    case number
}

public struct PageNavigator: Sendable, Equatable {
    public let chineseAvailable: Bool
    public private(set) var page: KeyboardPage

    public init(lastPage: KeyboardPage?, field: FieldKind, chineseAvailable: Bool) {
        self.chineseAvailable = chineseAvailable
        var letters = lastPage?.letterPage ?? (chineseAvailable ? .chinese : .english)
        if letters == .chinese, !chineseAvailable { letters = .english }
        switch field {
        case .text:
            page = letters
        case .emailOrURL:
            page = .english
        case .number:
            page = .symbols(origin: letters == .chinese ? .chinese : .english)
        }
    }

    /// The letter page to save for the next appearance.
    public var persistablePage: KeyboardPage { page.letterPage }

    /// Switches between the Chinese and English letter pages; from the symbols page it goes to the other letter page.
    /// Without a Chinese page nothing changes.
    public mutating func switchChineseEnglish() {
        guard chineseAvailable else { return }
        page = page.letterPage == .chinese ? .english : .chinese
    }

    /// Opens the symbols page, or returns to the page it was opened from.
    public mutating func switchSymbols() {
        switch page {
        case .chinese: page = .symbols(origin: .chinese)
        case .english: page = .symbols(origin: .english)
        case .symbols: page = page.letterPage
        }
    }
}
