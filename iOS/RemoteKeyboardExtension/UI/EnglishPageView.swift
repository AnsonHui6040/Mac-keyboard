import RemoteKeyboardCore
import UIKit

/// The three letter rows of the English page: QWERTY, Shift and delete. The bottom row is `BottomRowView`.
final class EnglishPageView: UIView {
    /// A letter key was pressed; the text already follows Shift.
    var onLetter: ((String) -> Void)?
    var onShift: (() -> Void)?
    var onBackspace: (() -> Void)?

    private static let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
    private var letterKeys: [KeyButton] = []
    private var rowKeys: [[KeyButton]] = []
    private let shiftKey = KeyButton(style: .function, symbol: "shift", label: "大寫", identifier: "rk.shift")
    private let backspaceKey = KeyButton(
        style: .function, symbol: "delete.left", label: "刪除", identifier: "rk.backspace")
    private var isUppercase = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Not drawn, but a surface for touches; see `UIColor.keyboardTouchSurface`.
        backgroundColor = .keyboardTouchSurface
        for row in Self.rows {
            var keys: [KeyButton] = []
            for letter in row {
                let key = KeyButton(style: .letter, title: String(letter), label: String(letter))
                key.onTap = { [weak self, weak key] in
                    guard let self, let text = key?.title(for: .normal) else { return }
                    self.onLetter?(text)
                }
                key.participatesInRollover = true
                addSubview(key)
                keys.append(key)
                letterKeys.append(key)
            }
            rowKeys.append(keys)
        }
        shiftKey.onTap = { [weak self] in self?.onShift?() }
        backspaceKey.onRepeat = { [weak self] in self?.onBackspace?() }
        addSubview(shiftKey)
        addSubview(backspaceKey)
        setShift(.off)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setShift(_ mode: ShiftState.Mode) {
        isUppercase = mode != .off
        for key in letterKeys {
            let title = key.title(for: .normal) ?? ""
            let text = isUppercase ? title.uppercased() : title.lowercased()
            key.setTitle(text, for: .normal)
            key.accessibilityLabel = text
        }
        switch mode {
        case .off: shiftKey.setSymbol("shift"); shiftKey.accessibilityValue = "關閉"
        case .once: shiftKey.setSymbol("shift.fill"); shiftKey.accessibilityValue = "下一個字母大寫"
        case .capsLock: shiftKey.setSymbol("capslock.fill"); shiftKey.accessibilityValue = "鎖定大寫"
        }
        shiftKey.setOn(mode != .off)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = KeyboardMetrics.keyGap
        let height = KeyboardMetrics.keyRowHeight
        let rowStep = height + KeyboardMetrics.rowGap
        let width = bounds.width
        // Row 1: ten keys across the full width. The other rows follow its key width.
        let first = KeyRowLayout.equalKeys(count: 10, x: 0, width: width, gap: gap)
        let key = first[0].width
        for (index, frame) in first.enumerated() {
            rowKeys[0][index].frame = CGRect(x: frame.x, y: 0, width: frame.width, height: height)
        }
        // Row 2: nine keys, centred.
        let inset = (key + gap) / 2
        for (index, frame) in KeyRowLayout.equalKeys(count: 9, x: inset, width: width - 2 * inset, gap: gap).enumerated() {
            rowKeys[1][index].frame = CGRect(x: frame.x, y: rowStep, width: frame.width, height: height)
        }
        // Row 3: Shift, seven letters, delete. The two function keys are wider than a letter key.
        let function = key * 1.5
        let lettersWidth = width - 2 * function - 2 * gap
        let letters = KeyRowLayout.equalKeys(count: 7, x: function + gap, width: lettersWidth, gap: gap)
        let y = 2 * rowStep
        shiftKey.frame = CGRect(x: 0, y: y, width: function, height: height)
        backspaceKey.frame = CGRect(x: width - function, y: y, width: function, height: height)
        for (index, frame) in letters.enumerated() {
            rowKeys[2][index].frame = CGRect(x: frame.x, y: y, width: frame.width, height: height)
        }
    }

    static var height: Double { 3 * KeyboardMetrics.keyRowHeight + 2 * KeyboardMetrics.rowGap }
}
