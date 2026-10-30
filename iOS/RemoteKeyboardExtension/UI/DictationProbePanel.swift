#if DEBUG
import UIKit

/// T13 (Debug builds only): the dictation probe's checklist, one item per line, drawn over the three letter rows of the
/// English page. It swallows touches, so the letter keys under it cannot be pressed while the probe is on; the top
/// area and the bottom row stay as they are. Lines hold only item names, states and numbers, never text.
final class DictationProbePanel: UIView {
    static let lineCount = 5
    /// The smallest font any line may use; lines are never scaled below it.
    static let fontSize: CGFloat = 15

    private let lines: [UILabel]

    override init(frame: CGRect) {
        lines = (0..<Self.lineCount).map { _ in UILabel() }
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        accessibilityIdentifier = "rk.dictationProbe"
        let stack = UIStackView(arrangedSubviews: lines)
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        for (index, label) in lines.enumerated() {
            label.font = .monospacedDigitSystemFont(ofSize: Self.fontSize, weight: .regular)
            label.textColor = .label
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.accessibilityIdentifier = "rk.dictationProbe.line\(index + 1)"
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sets the lines; a missing line is blank.
    func setLines(_ texts: [String]) {
        for (index, label) in lines.enumerated() {
            label.text = index < texts.count ? texts[index] : ""
        }
    }
}
#endif
