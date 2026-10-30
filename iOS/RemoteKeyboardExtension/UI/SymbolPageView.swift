import RemoteKeyboardCore
import UIKit

/// The three key rows of the symbols page: two rows of ten, then a layer key, five keys and delete. The layer key
/// cycles through the layers of `SymbolLayouts` and only changes this page; it never sends a character. The bottom row
/// is `BottomRowView`.
final class SymbolPageView: UIView {
    /// A symbol key was pressed.
    var onSymbol: ((String) -> Void)?
    var onBackspace: (() -> Void)?

    private var origin = SymbolOrigin.english
    private var layers = SymbolLayouts.layers(for: .english)
    private var layerIndex = 0
    private var rowKeys: [[KeyButton]] = []
    private let layerKey = KeyButton(style: .function, title: "", label: "切換符號層", identifier: "rk.symLayer")
    private let backspaceKey = KeyButton(
        style: .function, symbol: "delete.left", label: "刪除", identifier: "rk.backspace")

    override init(frame: CGRect) {
        super.init(frame: frame)
        for count in [10, 10, 5] {
            var keys: [KeyButton] = []
            for _ in 0..<count {
                let key = KeyButton(style: .letter, title: "", label: "")
                key.onTap = { [weak self, weak key] in
                    guard let self, let text = key?.title(for: .normal), !text.isEmpty else { return }
                    self.onSymbol?(text)
                }
                addSubview(key)
                keys.append(key)
            }
            rowKeys.append(keys)
        }
        layerKey.onTap = { [weak self] in self?.nextLayer() }
        backspaceKey.onRepeat = { [weak self] in self?.onBackspace?() }
        addSubview(layerKey)
        addSubview(backspaceKey)
        showLayer(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Called whenever the keyboard shows this page. Entering the page, or coming from a different letter page,
    /// starts again from the first layer.
    func enter(origin: SymbolOrigin) {
        self.origin = origin
        layers = SymbolLayouts.layers(for: origin)
        showLayer(0)
    }

    /// Debug preview only: shows a given layer without any taps.
    func showLayer(_ index: Int) {
        layerIndex = layers.indices.contains(index) ? index : 0
        let layer = layers[layerIndex]
        for (row, keys) in rowKeys.enumerated() {
            for (column, key) in keys.enumerated() {
                let text = layer[row][column]
                key.setTitle(text, for: .normal)
                key.accessibilityLabel = text
                key.accessibilityIdentifier = "rk.sym.\(text)"
            }
        }
        layerKey.setTitle(SymbolLayouts.layerKeyTitles(for: origin)[layerIndex], for: .normal)
    }

    private func nextLayer() {
        showLayer((layerIndex + 1) % layers.count)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = KeyboardMetrics.keyGap
        let height = KeyboardMetrics.keyRowHeight
        let rowStep = height + KeyboardMetrics.rowGap
        let width = bounds.width
        let first = KeyRowLayout.equalKeys(count: 10, x: 0, width: width, gap: gap)
        let key = first[0].width
        for row in 0..<2 {
            for (index, frame) in first.enumerated() {
                rowKeys[row][index].frame = CGRect(x: frame.x, y: Double(row) * rowStep, width: frame.width, height: height)
            }
        }
        // Row 3: layer key, five symbols, delete. The two function keys are wider than a symbol key, as on the English page.
        let function = key * 1.5
        let y = 2 * rowStep
        let symbolsWidth = width - 2 * function - 2 * gap
        layerKey.frame = CGRect(x: 0, y: y, width: function, height: height)
        backspaceKey.frame = CGRect(x: width - function, y: y, width: function, height: height)
        for (index, frame) in KeyRowLayout.equalKeys(count: 5, x: function + gap, width: symbolsWidth, gap: gap).enumerated() {
            rowKeys[2][index].frame = CGRect(x: frame.x, y: y, width: frame.width, height: height)
        }
    }
}
