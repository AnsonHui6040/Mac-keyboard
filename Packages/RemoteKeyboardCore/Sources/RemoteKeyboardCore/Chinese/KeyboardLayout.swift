import Foundation

public enum LayoutAction: String, Codable, Sendable {
    case shift
    case backspace
}

/// One key of a keyboard layout file. `codes`, `longPress` and `swipe` are reserved for imported layouts (M15): they
/// are parsed but not drawn yet. `width` is in key units and defaults to 1.
public struct LayoutKey: Codable, Equatable, Sendable {
    public var code: String?
    public var action: LayoutAction?
    public var label: String?
    public var hint: String?
    public var width: Double?
    public var codes: [String]?
    public var longPress: [String]?
    public var swipe: [String: String]?

    public init(
        code: String? = nil, action: LayoutAction? = nil, label: String? = nil, hint: String? = nil,
        width: Double? = nil, codes: [String]? = nil, longPress: [String]? = nil, swipe: [String: String]? = nil
    ) {
        self.code = code
        self.action = action
        self.label = label
        self.hint = hint
        self.width = width
        self.codes = codes
        self.longPress = longPress
        self.swipe = swipe
    }
}

public enum KeyboardLayoutError: Error, Equatable {
    case invalidJSON
    case unsupportedVersion(Int)
    case noRows
    case tooManyRows(Int)
    case emptyRow(Int)
    case keyNeedsCodeOrAction(row: Int, index: Int)
    case badWidth(row: Int, index: Int)
    case duplicateCode(String)
    case tooManyKeys(Int)
}

/// A key layout file (`ime/layouts/*.json`).
public struct KeyboardLayout: Codable, Equatable, Sendable {
    public static let supportedVersion = 1
    public static let maxRows = 6
    public static let maxKeys = 60
    public static let widthRange: ClosedRange<Double> = 0.5...4

    public var id: String
    public var name: String
    public var version: Int
    public var schemas: [String]
    public var rows: [[LayoutKey]]

    public init(id: String, name: String, version: Int, schemas: [String], rows: [[LayoutKey]]) {
        self.id = id
        self.name = name
        self.version = version
        self.schemas = schemas
        self.rows = rows
    }

    /// Decodes and validates a layout file.
    public static func decode(_ data: Data) throws -> KeyboardLayout {
        let layout: KeyboardLayout
        do {
            layout = try JSONDecoder().decode(KeyboardLayout.self, from: data)
        } catch {
            throw KeyboardLayoutError.invalidJSON
        }
        try layout.validate()
        return layout
    }

    private func validate() throws {
        guard version == Self.supportedVersion else { throw KeyboardLayoutError.unsupportedVersion(version) }
        guard !rows.isEmpty else { throw KeyboardLayoutError.noRows }
        guard rows.count <= Self.maxRows else { throw KeyboardLayoutError.tooManyRows(rows.count) }
        var seen = Set<String>()
        var total = 0
        for (r, row) in rows.enumerated() {
            guard !row.isEmpty else { throw KeyboardLayoutError.emptyRow(r) }
            for (i, key) in row.enumerated() {
                let hasCode = key.code.map { !$0.isEmpty } ?? false
                guard hasCode != (key.action != nil) else {
                    throw KeyboardLayoutError.keyNeedsCodeOrAction(row: r, index: i)
                }
                if let width = key.width, !Self.widthRange.contains(width) {
                    throw KeyboardLayoutError.badWidth(row: r, index: i)
                }
                if let code = key.code, !seen.insert(code).inserted {
                    throw KeyboardLayoutError.duplicateCode(code)
                }
                total += 1
            }
        }
        guard total <= Self.maxKeys else { throw KeyboardLayoutError.tooManyKeys(total) }
    }
}
