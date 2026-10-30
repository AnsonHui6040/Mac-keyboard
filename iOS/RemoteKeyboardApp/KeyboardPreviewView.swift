#if DEBUG
import RemoteKeyboardCore
import SwiftUI
import UIKit

/// Debug only. Launch the app with `-rkPreview <state>` to see the keyboard views at their real height with fake
/// state, pinned to the bottom of the screen: `local`, `remoteInstant`, `remoteDraft`, `notReady`, `symbols`, `caps`,
/// `handwriting` (Remote mode, Chinese page with sample ink and nine candidates 禾 乐 木 夭 米 未 朱 末 林),
/// `handwritingLocal` (the same in Local mode, where the top area is two rows), `handwritingEmpty` (nothing written
/// yet), `handwritingNoModel` (the model is missing), `dictationProbe` (T13 checklist in the candidate row).
/// `-rkPreviewWidth 375` squeezes the keyboard to that width (centred) to check the narrowest iPhone on a wider
/// simulator. Taps do nothing.
struct KeyboardPreviewView: View {
    let stateName: String
    /// 0 means the full screen width.
    let width: CGFloat

    var body: some View {
        KeyboardPreviewRepresentable(stateName: stateName, width: width)
            .ignoresSafeArea()
    }
}

private struct KeyboardPreviewRepresentable: UIViewRepresentable {
    let stateName: String
    let width: CGFloat

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .systemBackground

        let backdrop = UIView()
        backdrop.backgroundColor = .systemGray5
        let root = KeyboardRootView()
        let preview = Self.preview(named: stateName)
        root.apply(preview.state)
        root.setShift(preview.shift)
        if stateName == "handwriting" || stateName == "handwritingLocal" { root.showSampleInk() }

        for view in [backdrop, root] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        var constraints = [
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            root.heightAnchor.constraint(equalToConstant: root.preferredHeight),
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ]
        constraints.append(
            width > 0
                ? root.widthAnchor.constraint(equalToConstant: width)
                : root.widthAnchor.constraint(equalTo: container.widthAnchor))
        NSLayoutConstraint.activate(constraints)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private static let sampleCandidates = ["禾", "乐", "木", "夭", "米", "未", "朱", "末", "林"]

    private static func preview(named name: String) -> (state: KeyboardViewState, shift: ShiftState.Mode) {
        func make(
            mode: KeyboardMode = .remote, transmit: TransmitMode = .instant, page: KeyboardPage = .english,
            ready: Bool = true, draft: DraftBuffer = DraftBuffer(), status: String = "● Mac → TextEdit",
            link: String = "connected", candidates: [String] = [], message: String? = nil
        ) -> KeyboardViewState {
            KeyboardViewState(
                mode: mode, transmit: transmit, page: page,
                top: TopAreaState(mode: mode, transmit: transmit, ready: ready, draftEmpty: draft.isEmpty, hasNote: false),
                draft: draft, statusText: status, linkName: link, probeText: "AppGroup: OK  版本 預覽",
                showsGlobe: true, chineseAvailable: true, candidates: candidates, handwritingMessage: message,
                hapticsEnabled: false)
        }
        func draft(_ text: String, cursorBack: Int = 0) -> DraftBuffer {
            var buffer = DraftBuffer()
            _ = buffer.insert(text)
            for _ in 0..<cursorBack { buffer.moveLeft() }
            return buffer
        }
        switch name {
        case "local":
            return (make(mode: .local, status: "BLE: idle", link: "idle"), .off)
        case "remoteDraft":
            return (make(transmit: .draft, draft: draft("香港你好", cursorBack: 2)), .off)
        case "notReady":
            return (make(ready: false, draft: draft("abc"), status: "Mac（無輸入欄位）"), .off)
        case "symbols":
            return (make(page: .symbols(origin: .english)), .off)
        case "handwriting":
            return (make(page: .chinese, candidates: Self.sampleCandidates), .off)
        case "handwritingLocal":
            return (
                make(mode: .local, page: .chinese, status: "BLE: idle", link: "idle", candidates: Self.sampleCandidates),
                .off)
        case "handwritingEmpty":
            return (make(page: .chinese), .off)
        case "handwritingNoModel":
            return (make(page: .chinese, message: "請先在 App 下載手寫模型"), .off)
        case "dictationProbe":
            var state = make()
            state.dictationProbeLines = [
                "①請確認下方有麥克風  ②寫入欄位 是12",
                "③變化 will12 did12 隱0  ④差分 退2 字13 重設1  ⑤Mac 送12 回12 稿3"
            ]
            return (state, .off)
        case "caps":
            return (make(), .capsLock)
        default:
            return (make(), .off)
        }
    }
}
#endif
