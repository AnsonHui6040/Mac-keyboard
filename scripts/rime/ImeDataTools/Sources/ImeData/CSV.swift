import Foundation

public enum ImeDataError: Error, Equatable {
    case badLine(Int)
}

/// Comma separated values as words.hk writes them: CRLF or LF row ends, double-quoted fields that may hold commas,
/// carriage returns and newlines, and `""` for one quote. Works on Unicode scalars because Swift treats "\r\n" as
/// a single Character.
public enum CSV {
    public static func rows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var pending = false  // something of the current row has been read
        let scalars = Array(text.unicodeScalars)
        var i = 0
        func endField() {
            row.append(String(field))
            field = String.UnicodeScalarView()
        }
        func endRow() {
            endField()
            rows.append(row)
            row = []
            pending = false
        }
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                    pending = true
                case ",":
                    endField()
                    pending = true
                case "\r":
                    if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                    endRow()
                case "\n":
                    endRow()
                default:
                    field.append(c)
                    pending = true
                }
            }
            i += 1
        }
        if pending { endRow() }
        return rows
    }
}

public enum WordsHKFrequency {
    /// `character -> count` from words.hk `charcount.csv`; the first row (`Source,…`) is skipped.
    public static func parse(_ csv: String) -> [String: Int] {
        var result: [String: Int] = [:]
        for row in CSV.rows(csv).dropFirst() where row.count >= 2 {
            guard let count = Int(row[1]) else { continue }
            if result[row[0]] == nil { result[row[0]] = count }
        }
        return result
    }
}

public enum VersionsLock {
    /// The URL column of the line whose name column is `name` in `scripts/rime/versions.lock`.
    public static func url(named name: String, in lock: String) -> String? {
        for line in lock.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: " ")
            if columns.count >= 4, columns[0] == name { return String(columns[2]) }
        }
        return nil
    }
}
