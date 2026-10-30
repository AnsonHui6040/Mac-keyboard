/// Wording for the keyboard status line. Taiwan Traditional Chinese where it is not a state name.
public enum StatusLine {
    /// - Parameter connectedMs: shown-to-connected time of this appearance; only used while the link is connected.
    public static func text(
        mode: KeyboardMode, link: KeyboardLinkState, receiver: ReceiverStatus?, connectedMs: Int64? = nil
    ) -> String {
        let latency = link == .connected ? connectedMs.map { " (\($0) ms)" } ?? "" : ""
        guard mode == .remote, link == .connected else {
            return link == .connected ? "BLE: connected" + latency : link.statusText
        }
        let base = receiver?.appName.map { "Mac → \($0)" } ?? "Mac"
        guard let receiver else { return base + "（等待狀態）" + latency }
        return (receiver.ready ? base : base + "（無輸入欄位）") + latency
    }

    /// The note for an ack, or `nil` when the ack is not about a typed key (a probe's answer).
    public static func ackText(_ code: AckCode) -> String? {
        switch code {
        case .posted: "Mac 已輸入"
        case .notAuthorized: "Mac 未授權輔助使用"
        case .noFocus: "Mac 沒有輸入欄位"
        case .staleFocus: "焦點已改變，未輸入"
        case .switchFailed: "輸入法切換失敗"
        case .malformed: "Mac 無法處理"
        case .compositionActive: "Mac 正在組字，未輸入"
        case .injectFailed: "Mac 輸入失敗"
        case .outOfOrder: "順序錯誤，未輸入"
        case .pong: nil
        }
    }

    /// Shown after the link dropped with keys that never got an ack.
    public static func unconfirmedText(_ count: Int) -> String {
        "\(count) 個按鍵未確認是否送達"
    }

    public static func appendingNote(_ line: String, note: String?) -> String {
        note.map { "\(line)（\($0)）" } ?? line
    }
}
