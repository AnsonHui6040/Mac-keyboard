/// Wording for the keyboard status line. Taiwan Traditional Chinese where it is not a state name.
public enum StatusLine {
    /// Remote mode with no pair key: nothing is sent, and this is what the user is told to do.
    public static let unpairedText = "尚未配對"

    /// How the status line names the computer: Mac keeps its own wording (focus, Accessibility, password field); a Windows
    /// or Linux receiver is just 「電腦」, and none of the Mac-only states (focus, password field) exist for it.
    static func noun(_ platform: HostPlatform) -> String { platform == .mac ? "Mac" : "電腦" }

    /// The noun as the first word of a sentence: Mac is set apart from the Chinese after it by a space, 「電腦」 is not.
    private static func lead(_ platform: HostPlatform) -> String { platform == .mac ? "Mac " : "電腦" }

    /// - Parameters:
    ///   - connectedMs: shown-to-connected time of this appearance; only used while the link is connected.
    ///   - paired: whether this iPhone holds a pair key. Only Remote mode depends on it.
    ///   - platform: the current host's platform; decides the wording.
    public static func text(
        mode: KeyboardMode, link: KeyboardLinkState, receiver: ReceiverStatus?, connectedMs: Int64? = nil,
        paired: Bool = true, platform: HostPlatform = .mac
    ) -> String {
        if mode == .remote, !paired { return unpairedText }
        let latency = link == .connected ? connectedMs.map { " (\($0) ms)" } ?? "" : ""
        guard mode == .remote, link == .connected else {
            return link == .connected ? "BLE: connected" + latency : link.statusText
        }
        if let receiver, !receiver.trusted { return notAuthorizedText(platform) + latency }
        let name = noun(platform)
        let base = receiver?.appName.map { "\(name) → \($0)" } ?? name
        guard let receiver else { return base + "（等待狀態）" + latency }
        guard platform == .mac else { return (receiver.ready ? base : base + "（無法輸入）") + latency }
        if receiver.inputBlocked { return base + "（密碼欄，不能輸入）" + latency }
        return (receiver.ready ? base : base + "（無輸入欄位）") + latency
    }

    private static func notAuthorizedText(_ platform: HostPlatform) -> String {
        platform == .mac ? "Mac 未授權輔助使用" : "電腦未授權"
    }

    /// The status line as the keyboard draws it: a short text and a tone for its colour.
    public struct Display: Equatable, Sendable {
        public enum Tone: Equatable, Sendable { case connected, problem }
        public let text: String
        public let tone: Tone
        /// The current host's name, only while this iPhone holds two or more hosts (the cell then has two lines: this and
        /// `text`) and the keyboard is in Remote mode. `nil` keeps the single-line cell.
        public let title: String?

        public init(text: String, tone: Tone, title: String? = nil) {
            self.text = text
            self.tone = tone
            self.title = title
        }
    }

    public static let notPairedShortText = "尚未配對"
    public static let connectedText = "已連接"
    public static let disconnectedText = "未連接"

    /// Said while the Mac is blocked (password field, secure input, locked screen). Six characters, for the narrow cell.
    public static let inputBlockedText = "密碼不能輸入"

    /// First match wins: unpaired Remote, a note (a `.posted` note counts as none), an untrusted host, a blocked Mac,
    /// connected, not connected. Local mode shows nothing while there is no note (`nil`).
    ///
    /// - Parameters:
    ///   - host: the current host; its platform picks the wording (`nil` reads as a Mac) and, with `hostCount` of two or
    ///     more, its name becomes the `title`.
    ///   - hostCount: how many hosts this iPhone has paired.
    public static func display(
        mode: KeyboardMode, link: KeyboardLinkState, receiver: ReceiverStatus?, paired: Bool, note: String?,
        host: HostIdentity? = nil, hostCount: Int = 1
    ) -> Display? {
        let platform = host?.platform ?? .mac
        let title = mode == .remote && hostCount >= 2 ? host?.name : nil
        if mode == .remote, !paired { return Display(text: notPairedShortText, tone: .problem, title: title) }
        if let note, !isPostedNote(note) { return Display(text: note, tone: .problem, title: title) }
        guard mode == .remote else { return nil }
        if link == .connected, let receiver, !receiver.trusted {
            return Display(text: ackText(.notAuthorized, platform: platform) ?? "", tone: .problem, title: title)
        }
        // Windows and Linux have no password field to detect, so a status that claims one is not shown.
        if link == .connected, platform == .mac, receiver?.inputBlocked == true {
            return Display(text: inputBlockedText, tone: .problem, title: title)
        }
        if link == .connected { return Display(text: connectedText, tone: .connected, title: title) }
        return Display(text: disconnectedText, tone: .problem, title: title)
    }

    /// The posted note of any platform: it names a success and is not shown. A note made for one host may still be on screen
    /// when another is chosen.
    private static func isPostedNote(_ note: String) -> Bool {
        ([HostPlatform.mac, .windows, .linux]).contains { ackText(.posted, platform: $0) == note }
    }

    /// The note for a typing key that was dropped (`RouteOutcome.rejected`) while the Mac was not ready. `nil` says
    /// nothing: the status line already names the cause (a password field, a Mac without Accessibility), and a note would
    /// cover it.
    public static func droppedKeyNote(
        link: KeyboardLinkState, receiver: ReceiverStatus?, platform: HostPlatform = .mac
    ) -> String? {
        let lead = lead(platform)
        guard link == .connected else { return "\(lead)未連接，未輸入" }
        guard let receiver else { return "\(lead)尚未就緒，未輸入" }
        if receiver.inputBlocked || !receiver.trusted { return nil }
        return platform == .mac ? "Mac 沒有輸入欄位，未輸入" : "電腦尚未就緒，未輸入"
    }

    /// Shown on the touchpad page while the Mac does not accept pointer control.
    public static let pointerDeniedText = "Mac 未允許觸控板控制"
    public static let pointerTimeoutText = "無法連接觸控板，請按鍵盤再按觸控板重試"
    public static let pointerConnectingText = "正在連接觸控板…"
    public static let pointerOfflineText = "尚未連線 Mac"

    /// The note for an ack, or `nil` when the ack is not about a typed key (a probe's answer). Mac wording; see `ackText(_:platform:)`.
    public static func ackText(_ code: AckCode) -> String? { ackText(code, platform: .mac) }

    /// The same for the platform of the current host. A Windows or Linux receiver never sends the focus acks, but one that
    /// arrives is still worded without 「Mac」.
    public static func ackText(_ code: AckCode, platform: HostPlatform) -> String? {
        let lead = lead(platform)
        switch code {
        case .posted: return "\(lead)已輸入"
        case .notAuthorized: return notAuthorizedText(platform)
        case .noFocus: return platform == .mac ? "Mac 沒有輸入欄位" : "電腦無法輸入"
        case .staleFocus: return "焦點已改變，未輸入"
        case .switchFailed: return "輸入法切換失敗"
        case .malformed: return "\(lead)無法處理"
        case .compositionActive: return "\(lead)正在組字，未輸入"
        case .injectFailed: return "\(lead)輸入失敗"
        case .outOfOrder: return "順序錯誤，未輸入"
        case .pong: return nil
        }
    }

    /// Shown after the link dropped with keys that never got an ack.
    public static func unconfirmedText(_ count: Int) -> String {
        "\(count) 個按鍵未確認是否送達"
    }

    public static func appendingNote(_ line: String, note: String?) -> String {
        guard let note, !line.contains(note) else { return line }
        return "\(line)（\(note)）"
    }
}
