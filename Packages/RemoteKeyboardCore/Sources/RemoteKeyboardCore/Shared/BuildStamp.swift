import Foundation

/// Formats the build time of an executable so a user can tell which build is installed.
public enum BuildStamp {
    public static func text(for date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "未知" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    /// Build time of the running bundle, taken from its executable's modification date.
    public static func current(bundle: Bundle = .main) -> String {
        let date = bundle.executableURL
            .flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        return text(for: date)
    }
}
