import RemoteKeyboardCore
import UIKit

/// The candidate row of the top area: Chinese candidates in a horizontally scrolling strip. The first candidate has a
/// light background because the space key commits it. On the Chinese page the delete key sits at the right end and the
/// strip stops before it. With no candidates and no delete key nothing is shown.
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

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let backspaceKey = KeyButton(
        style: .function, symbol: "delete.left", label: "刪除", identifier: "rk.hwDelete")
    private(set) var candidates: [String] = []
    private var showsBackspace = false

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
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.spacing = 4
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        backspaceKey.layer.shadowOpacity = 0
        backspaceKey.isHidden = true
        addSubview(scrollView)
        addSubview(backspaceKey)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The delete key is shown on the Chinese page only. It keeps the row visible even when there are no candidates.
    func setBackspaceVisible(_ visible: Bool) {
        guard visible != showsBackspace else { return }
        showsBackspace = visible
        backspaceKey.isHidden = !visible
        updateVisibility()
        setNeedsLayout()
    }

    private func updateVisibility() {
        isHidden = candidates.isEmpty && !showsBackspace
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let frames = CandidateBarLayout.frames(totalWidth: bounds.width, showsBackspace: showsBackspace)
        scrollView.frame = CGRect(x: 0, y: 0, width: frames.scrollWidth, height: bounds.height)
        if let backspace = frames.backspace {
            backspaceKey.frame = CGRect(
                x: backspace.x, y: (bounds.height - CandidateBarLayout.backspaceHeight) / 2,
                width: backspace.width, height: CandidateBarLayout.backspaceHeight)
        }
    }

    func setCandidates(_ list: [String]) {
        guard list != candidates else { return }
        candidates = list
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, text) in list.enumerated() {
            var configuration = UIButton.Configuration.plain()
            configuration.title = text
            configuration.attributedTitle = AttributedString(
                text, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 22)]))
            configuration.baseForegroundColor = .label
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
            configuration.background.cornerRadius = 6
            configuration.background.backgroundColor = index == 0 ? .tertiarySystemFill : .clear
            let button = UIButton(configuration: configuration)
            button.accessibilityIdentifier = "rk.candidate.\(index)"
            button.accessibilityLabel = text
            button.addAction(UIAction { _ in KeyFeedback.touchDown() }, for: .touchDown)
            button.addAction(UIAction { [weak self] _ in self?.onSelect?(index) }, for: .touchUpInside)
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
            stack.addArrangedSubview(button)
        }
        updateVisibility()
        scrollView.setContentOffset(.zero, animated: false)
    }
}
