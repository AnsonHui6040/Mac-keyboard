/// Names shared by the host App and the keyboard Extension. Only strings that really live in the App Group are here:
/// `rk.mode` is read and written through `UserDefaults.standard` and therefore stays out.
public enum AppGroup {
    /// App Group identifier. It is also the Keychain access group for the pairing item (confirmed on device in T09 Step 0).
    public static let identifier = "group.com.ansonhui.remotekeyboard"

    /// Keychain access group of the pairing item. No other group is used.
    public static let keychainAccessGroup = identifier

    /// Keys inside the App Group `UserDefaults` suite.
    public enum Key {
        /// Time stamp written by the host App so the Extension can check that the suite is shared.
        public static let probe = "probe"
        /// The Chinese input method the host App chose (`ChineseInputMethodID` raw value).
        public static let chineseMethod = "rk.chineseMethod"
    }
}
