/// Decides which Chinese input method the keyboard really uses. Pure, so the table can be tested.
public enum ChineseMethodResolver {
    /// - Parameters:
    ///   - saved: the host App's choice, nil when it never wrote one (the default is handwriting).
    ///   - handwritingNeedsFullAccess: true for the ML Kit engine, whose model lives in the App Group.
    ///   - installed: the methods this build contains.
    /// - Returns: the method to use, or nil when none is usable (the keyboard then has no Chinese page).
    public static func effective(
        saved: ChineseInputMethodID?, hasFullAccess: Bool, handwritingNeedsFullAccess: Bool,
        installed: Set<ChineseInputMethodID>
    ) -> ChineseInputMethodID? {
        func usable(_ id: ChineseInputMethodID) -> Bool {
            guard installed.contains(id) else { return false }
            return id != .handwriting || hasFullAccess || !handwritingNeedsFullAccess
        }
        // The saved choice first, then handwriting, then quick (the fallback when handwriting cannot run).
        let order = [saved ?? .handwriting, .handwriting, .quick]
        return order.first(where: usable)
    }
}
