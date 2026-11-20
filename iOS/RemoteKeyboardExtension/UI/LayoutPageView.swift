import RemoteKeyboardCore
import UIKit

/// The Chinese key page of a keyed method, drawn from a `KeyboardLayout`: code keys (label as the main character, `hint`
/// as a small corner text), Shift and delete. Keys are placed by `KeyboardLayoutGeometry`, so every layout follows the same
/// rule. Keys are `rk.ime.<code>`, `rk.ime.shift` and `rk.ime.backspace`.
final class LayoutPageView: UIView {
    /// A code key was pressed (the code as the layout file spells it; the input method applies Shift).
    var onCode: ((String) -> Void)?
    var onShift: (() -> Void)?
    var onBackspace: (() -> Void)?
    /// Asked at touch down: false means this delete press fires once and does not repeat.
    var backspaceAllowsRepeat: (() -> Bool)? {
        didSet { backspaceKeys.forEach { $0.allowsRepeat = backspaceAllowsRepeat } }
    }

    private struct Placed {
        let key: KeyButton
        let hint: UILabel?
    }

    private var layout: KeyboardLayout?
    private var placed: [[Placed]] = []
    private var shiftKeys: [KeyButton] = []
    private var backspaceKeys: [KeyButton] = []
    private var shiftOn = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Not drawn, but a surface for touches; see `UIColor.keyboardTouchSurface`.
        backgroundColor = .keyboardTouchSurface
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws a layout; the same layout again changes nothing.
    func apply(_ layout: KeyboardLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        subviews.forEach { $0.removeFromSuperview() }
        placed = []
        shiftKeys = []
        backspaceKeys = []
        for row in layout.rows {
            var rowPlaced: [Placed] = []
            for item in row {
                rowPlaced.append(make(item))
            }
            placed.append(rowPlaced)
        }
        setShift(shiftOn)
        setNeedsLayout()
    }

    /// Draws the one-shot Shift state. The input method owns it; the controller passes it in with every state.
    func setShift(_ on: Bool) {
        shiftOn = on
        for key in shiftKeys {
            key.setSymbol(on ? "shift.fill" : "shift")
            key.accessibilityValue = on ? "下一個字母大寫" : "關閉"
            key.setOn(on)
        }
    }

    private func make(_ item: LayoutKey) -> Placed {
        switch item.action {
        case .shift:
            let key = KeyButton(style: .function, symbol: "shift", label: "大寫", identifier: "rk.ime.shift")
            key.onTap = { [weak self] in self?.onShift?() }
            shiftKeys.append(key)
            addSubview(key)
            return Placed(key: key, hint: nil)
        case .backspace:
            let key = KeyButton(style: .function, symbol: "delete.left", label: "刪除", identifier: "rk.ime.backspace")
            key.onRepeat = { [weak self] in self?.onBackspace?() }
            key.allowsRepeat = backspaceAllowsRepeat
            backspaceKeys.append(key)
            addSubview(key)
            return Placed(key: key, hint: nil)
        case nil:
            let code = item.code ?? ""
            let face = item.label ?? code
            let spoken = item.hint.map { "\(face) \($0)" } ?? face
            let key = KeyButton(style: .letter, title: face, label: spoken, identifier: "rk.ime.\(code)")
            key.onTap = { [weak self] in self?.onCode?(code) }
            key.participatesInRollover = true
            addSubview(key)
            var hintLabel: UILabel?
            if let hint = item.hint {
                let corner = UILabel()
                corner.text = hint
                corner.font = .systemFont(ofSize: 10, weight: .medium)
                corner.textColor = .secondaryLabel
                corner.isUserInteractionEnabled = false
                corner.isAccessibilityElement = false
                addSubview(corner)
                hintLabel = corner
            }
            return Placed(key: key, hint: hintLabel)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout else { return }
        let height = KeyboardMetrics.keyRowHeight
        let rowStep = height + KeyboardMetrics.rowGap
        let frames = KeyboardLayoutGeometry.frames(layout, width: bounds.width, gap: KeyboardMetrics.keyGap)
        for (r, row) in placed.enumerated() where r < frames.count {
            for (i, item) in row.enumerated() where i < frames[r].count {
                let spot = frames[r][i]
                let frame = CGRect(x: spot.x, y: Double(r) * rowStep, width: spot.width, height: height)
                item.key.frame = frame
                if let corner = item.hint {
                    corner.sizeToFit()
                    corner.frame.origin = CGPoint(x: frame.maxX - corner.bounds.width - 4, y: frame.minY + 2)
                }
            }
        }
    }
}
