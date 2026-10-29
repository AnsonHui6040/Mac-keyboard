/// Wording for the keyboard status line. Taiwan Traditional Chinese where it is not a state name.
public enum StatusLine {
    public static func text(mode: KeyboardMode, link: KeyboardLinkState, receiver: ReceiverStatus?) -> String {
        guard mode == .remote, link == .connected else { return link.statusText }
        let base = receiver?.appName.map { "Mac → \($0)" } ?? "Mac"
        guard let receiver else { return base + "（等待狀態）" }
        return receiver.ready ? base : base + "（無輸入欄位）"
    }

    public static func ackText(_ code: AckCode) -> String {
        switch code {
        case .posted: "Mac 已輸入"
        case .notAuthorized: "Mac 未授權輔助使用"
        case .noFocus: "Mac 沒有輸入欄位"
        case .staleFocus: "焦點已改變，未輸入"
        case .switchFailed: "輸入法切換失敗"
        case .malformed: "Mac 無法處理"
        case .compositionActive: "Mac 正在組字，未輸入"
        }
    }

    public static func appendingNote(_ line: String, note: String?) -> String {
        note.map { "\(line)（\($0)）" } ?? line
    }
}
