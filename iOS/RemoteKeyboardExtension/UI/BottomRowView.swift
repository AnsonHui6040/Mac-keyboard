import RemoteKeyboardCore
import UIKit

/// The bottom row, left to right: globe (only when iOS asks for it), 符號, 中英, space, 重寫 (Chinese page only), return (D19).
final class BottomRowView: UIView {
    var onAction: ((KeyAction) -> Void)?
    /// 重寫 was tapped (Chinese page only).
    var onClear: (() -> Void)?
    #if DEBUG
    /// Long-pressing return for two seconds; the debug build uses it to send one 3,000-character text (T07 check).
    var onDebugLongReturn: (() -> Void)?
    /// Long-pressing space for two seconds; the debug build uses it to fill the draft to its cap (T10 device test).
    var onDebugLongSpace: (() -> Void)?
    /// Long-pressing return for four seconds; the debug build uses it to start the T15 burst.
    var onDebugBurst: (() -> Void)?
    /// Counts the second half of a return press (two seconds after the two-second mark). While it is pending, the
    /// two-second action waits for the release, so a four-second press starts only the burst.
    private var burstArm: Task<Void, Never>?
    #endif

    /// The controller adds `handleInputModeList(from:with:)` to this button.
    let globeKey = KeyButton(style: .function, title: "🌐", label: "下一個鍵盤", identifier: "rk.globe")
    private let chineseEnglishKey = KeyButton(
        style: .function, title: "中英", label: "中英切換", identifier: "rk.zhEn")
    private let symbolsKey = KeyButton(style: .function, title: "符號", label: "符號", identifier: "rk.symbols")
    private let spaceKey = KeyButton(style: .letter, title: "空白", label: "空白鍵", identifier: "rk.space")
    private let clearKey = KeyButton(style: .function, title: "重寫", label: "重寫", identifier: "rk.hwClear")
    private let returnKey = KeyButton(style: .function, title: "換行", label: "換行", identifier: "rk.return")

    private var showsGlobe = false
    private var showsClear = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Not drawn, but a surface for touches; see `UIColor.keyboardTouchSurface`.
        backgroundColor = .keyboardTouchSurface
        globeKey.titleLabel?.font = .systemFont(ofSize: 20)
        globeKey.isHidden = true
        clearKey.isHidden = true
        chineseEnglishKey.onTap = { [weak self] in self?.onAction?(.switchChineseEnglish) }
        symbolsKey.onTap = { [weak self] in self?.onAction?(.switchSymbols) }
        spaceKey.onTap = { [weak self] in self?.onAction?(.space) }
        clearKey.onTap = { [weak self] in self?.onClear?() }
        returnKey.onTap = { [weak self] in self?.onAction?(.returnKey) }
        #if DEBUG
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(debugLongReturn(_:)))
        longPress.minimumPressDuration = 2
        returnKey.addGestureRecognizer(longPress)
        let spacePress = UILongPressGestureRecognizer(target: self, action: #selector(debugLongSpace(_:)))
        spacePress.minimumPressDuration = 2
        spaceKey.addGestureRecognizer(spacePress)
        #endif
        for key in [globeKey, symbolsKey, chineseEnglishKey, spaceKey, clearKey, returnKey] { addSubview(key) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if DEBUG
    @objc private func debugLongReturn(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            burstArm?.cancel()
            burstArm = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.burstArm = nil
                self.onDebugBurst?()
            }
        case .ended:
            // Released between two and four seconds: the old two-second action, now on release.
            guard burstArm != nil else { return }
            burstArm?.cancel()
            burstArm = nil
            onDebugLongReturn?()
        case .cancelled, .failed:
            burstArm?.cancel()
            burstArm = nil
        default:
            break
        }
    }

    @objc private func debugLongSpace(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { onDebugLongSpace?() }
    }
    #endif

    func setGlobeVisible(_ visible: Bool) {
        guard showsGlobe != visible else { return }
        showsGlobe = visible
        globeKey.isHidden = !visible
        setNeedsLayout()
    }

    /// 重寫 is shown on the Chinese (handwriting) page only.
    func setClearVisible(_ visible: Bool) {
        guard showsClear != visible else { return }
        showsClear = visible
        clearKey.isHidden = !visible
        setNeedsLayout()
    }

    /// 中英 stays visible but looks disabled while there is no Chinese page.
    func setChineseAvailable(_ available: Bool) {
        chineseEnglishKey.isEnabled = available
    }

    /// The symbols key reads 符號 on the letter pages and names the page it returns to on the symbols page.
    func setPage(_ page: KeyboardPage) {
        switch page {
        case .chinese, .english:
            symbolsKey.setTitle("符號", for: .normal)
            symbolsKey.accessibilityLabel = "符號"
        case .symbols(let origin):
            symbolsKey.setTitle(origin == .english ? "ABC" : "中", for: .normal)
            symbolsKey.accessibilityLabel = origin == .english ? "返回英文字母" : "返回中文"
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = KeyboardMetrics.keyRowHeight
        let keys: [BottomRowKey: KeyButton] = [
            .globe: globeKey, .chineseEnglish: chineseEnglishKey, .symbols: symbolsKey,
            .space: spaceKey, .clear: clearKey, .returnKey: returnKey
        ]
        for placement in BottomRowLayout.placements(
            totalWidth: bounds.width, showsGlobe: showsGlobe, showsClear: showsClear) {
            keys[placement.key]?.frame = CGRect(x: placement.x, y: 0, width: placement.width, height: height)
        }
    }
}
