import RemoteKeyboardCore
import UIKit

/// The bottom row, left to right: globe (only when iOS asks for it), 中英, 符號, space, return.
final class BottomRowView: UIView {
    var onAction: ((KeyAction) -> Void)?
    #if DEBUG
    /// Long-pressing return for two seconds; the debug build uses it to send one 3,000-character text (T07 check).
    var onDebugLongReturn: (() -> Void)?
    /// Long-pressing space for two seconds; the debug build uses it to fill the draft to its cap (T10 device test).
    var onDebugLongSpace: (() -> Void)?
    #endif

    /// The controller adds `handleInputModeList(from:with:)` to this button.
    let globeKey = KeyButton(style: .function, title: "🌐", label: "下一個鍵盤", identifier: "rk.globe")
    private let chineseEnglishKey = KeyButton(
        style: .function, title: "中英", label: "中英切換", identifier: "rk.zhEn")
    private let symbolsKey = KeyButton(style: .function, title: "符號", label: "符號", identifier: "rk.symbols")
    private let spaceKey = KeyButton(style: .letter, title: "空白", label: "空白鍵", identifier: "rk.space")
    private let returnKey = KeyButton(style: .function, title: "換行", label: "換行", identifier: "rk.return")

    private var showsGlobe = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        globeKey.titleLabel?.font = .systemFont(ofSize: 20)
        globeKey.isHidden = true
        chineseEnglishKey.onTap = { [weak self] in self?.onAction?(.switchChineseEnglish) }
        symbolsKey.onTap = { [weak self] in self?.onAction?(.switchSymbols) }
        spaceKey.onTap = { [weak self] in self?.onAction?(.space) }
        returnKey.onTap = { [weak self] in self?.onAction?(.returnKey) }
        #if DEBUG
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(debugLongReturn(_:)))
        longPress.minimumPressDuration = 2
        returnKey.addGestureRecognizer(longPress)
        let spacePress = UILongPressGestureRecognizer(target: self, action: #selector(debugLongSpace(_:)))
        spacePress.minimumPressDuration = 2
        spaceKey.addGestureRecognizer(spacePress)
        #endif
        for key in [globeKey, chineseEnglishKey, symbolsKey, spaceKey, returnKey] { addSubview(key) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    #if DEBUG
    @objc private func debugLongReturn(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { onDebugLongReturn?() }
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
        let gap = KeyboardMetrics.keyGap
        let height = KeyboardMetrics.keyRowHeight
        let wide = 56.0
        var x = 0.0
        func place(_ key: KeyButton, width: Double) {
            key.frame = CGRect(x: x, y: 0, width: width, height: height)
            x += width + gap
        }
        if showsGlobe { place(globeKey, width: 44) }
        place(chineseEnglishKey, width: wide)
        place(symbolsKey, width: wide)
        let returnWidth = 72.0
        place(spaceKey, width: max(0, bounds.width - x - returnWidth - gap))
        returnKey.frame = CGRect(x: bounds.width - returnWidth, y: 0, width: returnWidth, height: height)
    }
}
