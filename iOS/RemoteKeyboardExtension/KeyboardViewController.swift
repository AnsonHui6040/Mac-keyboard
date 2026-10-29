import UIKit
import RemoteKeyboardCore

/// Adapts the system text proxy to the Core `TextSink` protocol.
@MainActor
struct TextDocumentProxySink: @preconcurrency TextSink {
    let proxy: UITextDocumentProxy
    func insertText(_ text: String) { proxy.insertText(text) }
    func deleteBackward() { proxy.deleteBackward() }
}

/// Remote path is not available until T05.
private struct UnavailableRemoteSink: RemoteEventSink {
    func enqueue(_ kind: EventKind) {}
}

final class KeyboardViewController: UIInputViewController {
    private var keyboardView: MinimalKeyboardView?

    override func viewDidLoad() {
        super.viewDidLoad()

        let router = KeyboardActionRouter(
            local: TextDocumentProxySink(proxy: textDocumentProxy),
            remote: UnavailableRemoteSink()
        )
        let view = MinimalKeyboardView(
            showsGlobeKey: needsInputModeSwitchKey,
            probeText: Self.probeStatusText()
        )
        view.onAction = { [weak self] action in
            guard self != nil else { return }
            _ = router.route(action, mode: .local)
        }
        view.globeButton.addTarget(
            self,
            action: #selector(handleInputModeList(from:with:)),
            for: .allTouchEvents
        )

        view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: self.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        keyboardView = view
    }

    override func viewWillLayoutSubviews() {
        keyboardView?.setGlobeVisible(needsInputModeSwitchKey)
        super.viewWillLayoutSubviews()
    }

    private static func probeStatusText() -> String {
        let value = UserDefaults(suiteName: "group.com.ansonhui.remotekeyboard")?.object(forKey: "probe")
        return value == nil ? "AppGroup: NIL" : "AppGroup: OK"
    }
}
