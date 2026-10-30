import RemoteKeyboardCore
import UIKit

/// The Quick (速成) page: the same QWERTY rows, key sizes and Shift and delete keys as the English page. Each letter key
/// shows its Cangjie radical as the main character and the English letter in a small corner.
final class QuickPageView: UIView {
    /// A letter key was pressed (always the lowercase letter; the input method applies Shift).
    var onLetter: ((String) -> Void)?
    var onShift: (() -> Void)?
    var onBackspace: (() -> Void)?
    /// Asked at touch down: false means this delete press fires once and does not repeat.
    var backspaceAllowsRepeat: (() -> Bool)? {
        get { backspaceKey.allowsRepeat }
        set { backspaceKey.allowsRepeat = newValue }
    }

    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private var rowKeys: [[KeyButton]] = []
    private var cornerLabels: [[UILabel]] = []
    private let shiftKey = KeyButton(style: .function, symbol: "shift", label: "大寫", identifier: "rk.quick.shift")
    private let backspaceKey = KeyButton(
        style: .function, symbol: "delete.left", label: "刪除", identifier: "rk.quick.backspace")

    override init(frame: CGRect) {
        super.init(frame: frame)
        for row in Self.rows {
            var keys: [KeyButton] = []
            var corners: [UILabel] = []
            for letter in row {
                let radical = CangjieRadicals.byLetter[letter] ?? ""
                let key = KeyButton(
                    style: .letter, title: radical, label: "\(radical) \(letter)", identifier: "rk.quick.\(letter)")
                key.onTap = { [weak self] in self?.letterTapped(String(letter)) }
                let corner = UILabel()
                corner.text = String(letter).uppercased()
                corner.font = .systemFont(ofSize: 10, weight: .medium)
                corner.textColor = .secondaryLabel
                corner.isUserInteractionEnabled = false
                corner.isAccessibilityElement = false
                addSubview(key)
                addSubview(corner)
                keys.append(key)
                corners.append(corner)
            }
            rowKeys.append(keys)
            cornerLabels.append(corners)
        }
        shiftKey.onTap = { [weak self] in self?.shiftTapped() }
        backspaceKey.onRepeat = { [weak self] in self?.onBackspace?() }
        addSubview(shiftKey)
        addSubview(backspaceKey)
        setShift(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws the one-shot Shift state. The input method owns it; the controller passes it in with every state.
    func setShift(_ on: Bool) {
        shiftKey.setSymbol(on ? "shift.fill" : "shift")
        shiftKey.accessibilityValue = on ? "下一個字母大寫" : "關閉"
        shiftKey.setOn(on)
    }

    private func letterTapped(_ letter: String) {
        onLetter?(letter)
    }

    private func shiftTapped() {
        onShift?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = KeyboardMetrics.keyGap
        let height = KeyboardMetrics.keyRowHeight
        let rowStep = height + KeyboardMetrics.rowGap
        let width = bounds.width
        // Same geometry as EnglishPageView: ten keys across, nine centred, then Shift, seven letters and delete.
        let first = KeyRowLayout.equalKeys(count: 10, x: 0, width: width, gap: gap)
        let key = first[0].width
        var frames: [[CGRect]] = [
            first.map { CGRect(x: $0.x, y: 0, width: $0.width, height: height) }
        ]
        let inset = (key + gap) / 2
        frames.append(
            KeyRowLayout.equalKeys(count: 9, x: inset, width: width - 2 * inset, gap: gap).map {
                CGRect(x: $0.x, y: rowStep, width: $0.width, height: height)
            })
        let function = key * 1.5
        let y = 2 * rowStep
        frames.append(
            KeyRowLayout.equalKeys(count: 7, x: function + gap, width: width - 2 * function - 2 * gap, gap: gap).map {
                CGRect(x: $0.x, y: y, width: $0.width, height: height)
            })
        shiftKey.frame = CGRect(x: 0, y: y, width: function, height: height)
        backspaceKey.frame = CGRect(x: width - function, y: y, width: function, height: height)
        for (row, rowFrames) in frames.enumerated() {
            for (index, frame) in rowFrames.enumerated() {
                rowKeys[row][index].frame = frame
                let corner = cornerLabels[row][index]
                corner.sizeToFit()
                corner.frame.origin = CGPoint(x: frame.maxX - corner.bounds.width - 4, y: frame.minY + 2)
            }
        }
    }

    static var height: Double { EnglishPageView.height }
}
