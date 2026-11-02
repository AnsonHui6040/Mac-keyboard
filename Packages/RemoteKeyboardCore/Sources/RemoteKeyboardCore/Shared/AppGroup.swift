import Foundation

/// Names shared by the host App and the keyboard Extension. Only strings that really live in the App Group are here:
/// `rk.mode` is read and written through `UserDefaults.standard` and therefore stays out.
public enum AppGroup {
    /// The group the project's own entitlements files request.
    public static let baseIdentifier = "group.com.ansonhui.remotekeyboard"

    /// App Group identifier of this process. It is also the Keychain access group for the pairing item (confirmed on
    /// device in T09 Step 0). SideStore re-signs with the tester's team and appends `.<TEAMID>` to the group, so the
    /// name is read from the group the embedded profile really grants. Each process reads its own bundle: the
    /// Extension reads the appex's profile. Without a profile (Mac, tests, Xcode-signed builds) it is `baseIdentifier`.
    public static let identifier: String = {
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        return resolvedIdentifier(provisioningProfile: url.flatMap { try? Data(contentsOf: $0) })
    }()

    /// Picks the group out of the (CMS-wrapped) provisioning profile bytes: the exact `baseIdentifier`, else the first
    /// group named `baseIdentifier.<suffix>`, else `baseIdentifier`. Anything unreadable falls back to the base.
    public static func resolvedIdentifier(provisioningProfile: Data?) -> String {
        guard let profile = provisioningProfile,
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let root = try? PropertyListSerialization.propertyList(
                  from: profile.subdata(in: start.lowerBound..<end.upperBound), options: [], format: nil) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return baseIdentifier }
        if groups.contains(baseIdentifier) { return baseIdentifier }
        return groups.first { $0.hasPrefix(baseIdentifier + ".") } ?? baseIdentifier
    }

    /// Keychain access group of the pairing item. No other group is used.
    public static let keychainAccessGroup = identifier

    /// Keys inside the App Group `UserDefaults` suite.
    public enum Key {
        /// Time stamp written by the host App so the Extension can check that the suite is shared.
        public static let probe = "probe"
        /// The Chinese input method the host App chose (`ChineseInputMethodID` raw value).
        public static let chineseMethod = "rk.chineseMethod"
        /// 「聽寫同步到 Mac」, a `Bool` written by the host App and read by the Extension. Not set means on
        /// (`DictationSync.isEnabled`).
        public static let dictationSync = "rk.dictationSync"
        /// 「按鍵聲音」, a `Bool` written by the host App and read by the Extension. Not set means on
        /// (`KeyFeedbackSettings`).
        public static let keySound = "rk.keySound"
        /// 「按鍵震動」, a `Bool` written by the host App and read by the Extension. Not set means on
        /// (`KeyFeedbackSettings`).
        public static let keyHaptics = "rk.keyHaptics"
        /// 「音量」, a `Double` 0…2 written by the host App and read by the Extension. Not set means 1.4
        /// (`KeyFeedbackSettings`).
        public static let keySoundVolume = "rk.keySoundVolume"
        /// 「震動強度」, a `Double` 0…1 written by the host App and read by the Extension. Not set means 0.7
        /// (`KeyFeedbackSettings`).
        public static let keyHapticIntensity = "rk.keyHapticIntensity"
        /// 「傳輸次數」, an `Int` written by the Extension's trackpad bar: 20…120, or 0 for 自動. Not set means 自動
        /// (`TrackpadSendRate`). The key is `.v2`: the old `rk.trackpadSendRate` held a rate with 60 as default and is not read.
        public static let trackpadSendRate = "rk.trackpadSendRate.v2"
        /// 「靈敏度」, a `Double` 0.2…3.0 written by the host App and read by the Extension. Not set means 1.0
        /// (`TrackpadSensitivity`).
        public static let trackpadSensitivity = "rk.trackpadSensitivity"
    }
}
