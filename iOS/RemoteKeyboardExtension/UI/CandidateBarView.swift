import UIKit

/// The candidate row of the top area: Chinese candidates in a horizontally scrolling strip. The first candidate has a
/// light background because the space key commits it. Empty means nothing is shown.
final class CandidateBarView: UIView {
    /// The user tapped the candidate at this index.
    var onSelect: ((Int) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private(set) var candidates: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.spacing = 4
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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
        isHidden = list.isEmpty
        scrollView.setContentOffset(.zero, animated: false)
    }
}
