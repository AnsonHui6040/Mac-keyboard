import RemoteKeyboardCore
import UIKit

/// A strip of Chinese candidates that scrolls sideways. In the top area (keyed methods) the first candidate has a light
/// background because the space key commits it. On the handwriting page the strip floats over the writing area with
/// the delete key at its right end; there nothing has a background and empty space passes touches through to the ink.
/// With no candidates and no delete key nothing is shown.
final class CandidateBarView: UIView {
    /// The user tapped the candidate at this index.
    var onSelect: ((Int) -> Void)?
    /// The delete key fired (touch down, then repeating while held when `backspaceAllowsRepeat` says so).
    var onBackspace: (() -> Void)? {
        get { backspaceKey.onRepeat }
        set { backspaceKey.onRepeat = newValue }
    }
    /// Asked at touch down: false means this press deletes once and does not repeat.
    var backspaceAllowsRepeat: (() -> Bool)? {
        get { backspaceKey.allowsRepeat }
        set { backspaceKey.allowsRepeat = newValue }
    }

    /// The first candidate gets a light background (the one the space key commits).
    var highlightsFirst = true
    /// Floating over the writing area: empty space does not take touches, and the delete key has no fill.
    var floatsOverInk = false {
        didSet { backspaceKey.isTransparent = floatsOverInk }
    }

    private let scrollView = UIScrollView()
    /// The input code label; nil while there is no code.
    private var composingLabel: UILabel?
    /// Candidate buttons, reused between updates. The first `candidates.count` are shown, the rest are hidden.
    /// None of the content uses Auto Layout: hundreds of width constraints in the keyboard's own layout engine once
    /// made the system spin in `NSISEngine optimize`, so the frames are computed by `CandidateBarLayout.strip`.
    private var buttons: [UIButton] = []
    private let candidateFont = UIFont.systemFont(ofSize: 22)
    private let composingFont = UIFont.systemFont(ofSize: 20, weight: .medium)
    private let backspaceKey = KeyButton(
        style: .function, symbol: "delete.left", label: "刪除", identifier: "rk.hwDelete")
    private(set) var candidates: [String] = []
    /// The input code (as radicals, Bopomofo or letters) shown at the left end, before the candidates; empty for handwriting.
    private(set) var composing = ""
    private var showsBackspace = false
    /// Bumped on every real update of the strip. A press that began under an older generation selects nothing, because
    /// the reused button now stands for a different candidate.
    private var generation = 0
    private var pressGeneration: [ObjectIdentifier: Int] = [:]
    /// Text widths measured once per update, not on every layout pass.
    private var candidateWidths: [Double] = []
    private var composingWidth: Double?

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        // The strip scrolls sideways only; no safe-area inset may shift its content.
        scrollView.contentInsetAdjustmentBehavior = .never
        // iOS 26 gives every scroll view soft edge effects, which may blur the upper half of the characters in this
        // 36 pt strip (not reproduced in the simulator; to be confirmed on a device). All four edges are switched off.
        if #available(iOS 26.0, *) {
            scrollView.topEdgeEffect.isHidden = true
            scrollView.leftEdgeEffect.isHidden = true
            scrollView.bottomEdgeEffect.isHidden = true
            scrollView.rightEdgeEffect.isHidden = true
        }
        backspaceKey.layer.shadowOpacity = 0
        backspaceKey.isHidden = true
        addSubview(scrollView)
        addSubview(backspaceKey)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Only a candidate or the delete key takes a touch when floating over the ink; everything else is not hit.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard floatsOverInk, let hit else { return hit }
        var view: UIView? = hit
        while let current = view, current !== self {
            if current is UIControl { return hit }
            view = current.superview
        }
        return nil
    }

    /// The delete key is shown on the Chinese page only. It keeps the row visible even when there are no candidates.
    func setBackspaceVisible(_ visible: Bool) {
        guard visible != showsBackspace else { return }
        showsBackspace = visible
        backspaceKey.isHidden = !visible
        updateVisibility()
        setNeedsLayout()
    }

    private func updateVisibility() {
        isHidden = candidates.isEmpty && composing.isEmpty && !showsBackspace
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = CandidateBarLayout.frames(totalWidth: bounds.width, showsBackspace: showsBackspace)
        scrollView.frame = CGRect(x: 0, y: 0, width: frames.scrollWidth, height: bounds.height)
        layoutStrip()
        if let backspace = frames.backspace {
            backspaceKey.frame = CGRect(
                x: backspace.x, y: (bounds.height - CandidateBarLayout.backspaceHeight) / 2,
                width: backspace.width, height: CandidateBarLayout.backspaceHeight)
        }
    }

    /// Frames of the code label and the candidate buttons, and the scroll view's content size.
    private func layoutStrip() {
        let strip = CandidateBarLayout.strip(
            composingTextWidth: composingWidth, candidateTextWidths: candidateWidths, height: Double(scrollView.bounds.height))
        if let label = composingLabel, let rect = strip.composing { label.frame = Self.cgRect(rect) }
        for (index, rect) in strip.candidates.enumerated() where index < buttons.count {
            buttons[index].frame = Self.cgRect(rect)
        }
        scrollView.contentSize = CGSize(width: strip.contentWidth, height: scrollView.bounds.height)
    }

    private static func cgRect(_ rect: CandidateBarLayout.StripRect) -> CGRect {
        CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    private func makeButton() -> UIButton {
        let button = UIButton(type: .custom)
        button.titleLabel?.font = candidateFont
        button.setTitleColor(.label, for: .normal)
        button.setTitleColor(.secondaryLabel, for: .highlighted)
        button.layer.cornerRadius = 6
        button.addAction(UIAction { [weak self, weak button] _ in
            KeyFeedback.touchDown()
            guard let self, let button else { return }
            self.pressGeneration[ObjectIdentifier(button)] = self.generation
        }, for: .touchDown)
        // The button's tag is its index, so a reused button never stacks actions. If the strip was updated after the
        // press began, the button now shows another candidate, so releasing selects nothing.
        button.addAction(UIAction { [weak self, weak button] _ in
            guard let self, let button else { return }
            let started = self.pressGeneration.removeValue(forKey: ObjectIdentifier(button))
            guard started == self.generation else { return }
            self.onSelect?(button.tag)
        }, for: .touchUpInside)
        scrollView.addSubview(button)
        return button
    }

    func setCandidates(_ list: [String], composing code: String = "") {
        guard list != candidates || code != composing else { return }
        candidates = list
        composing = code
        generation &+= 1
        candidateWidths = list.map { Double(($0 as NSString).size(withAttributes: [.font: candidateFont]).width) }
        composingWidth = code.isEmpty ? nil : Double(code.size(withAttributes: [.font: composingFont]).width)
        if code.isEmpty {
            composingLabel?.removeFromSuperview()
            composingLabel = nil
        } else {
            let label: UILabel
            if let existing = composingLabel {
                label = existing
            } else {
                label = UILabel()
                label.font = composingFont
                label.textColor = .systemBlue
                label.textAlignment = .center
                label.accessibilityIdentifier = "rk.ime.composing"
                label.accessibilityLabel = "輸入碼"
                scrollView.addSubview(label)
                composingLabel = label
            }
            label.text = code
            label.accessibilityValue = code
        }
        while buttons.count < list.count { buttons.append(makeButton()) }
        for (index, button) in buttons.enumerated() {
            guard index < list.count else {
                button.isHidden = true
                continue
            }
            button.isHidden = false
            button.tag = index
            button.setTitle(list[index], for: .normal)
            button.accessibilityIdentifier = "rk.candidate.\(index)"
            button.accessibilityLabel = list[index]
            button.backgroundColor = index == 0 && highlightsFirst ? .tertiarySystemFill : .clear
        }
        updateVisibility()
        scrollView.setContentOffset(.zero, animated: false)
        setNeedsLayout()
    }
}
