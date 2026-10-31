#if DEBUG
import UIKit

/// A button of the TP1 measurement page that the probe panel shows instead of its checklist while the Mac's measurement
/// mode is on.
enum MeasureCommand: Equatable {
    case m2, m3, m3Smoke, m5, m6, m4, latency, stop
}

/// What the measurement page shows. `enabled` is true only while the link is authenticated and the Mac says `measure`.
struct MeasurePanelState: Equatable {
    var enabled: Bool
    var running: Bool
    /// Progress while a run goes, otherwise the result lines of the last run. Numbers and names only.
    var text: String
    var latencyTitle: String
}

/// T13 (Debug builds only): the dictation probe's checklist, one item per line, drawn over the three letter rows of the
/// English page. It swallows touches, so the letter keys under it cannot be pressed while the probe is on; the top
/// area and the bottom row stay as they are. Lines hold only item names, states and numbers, never text.
///
/// TP1: while the Mac is in measurement mode the checklist gives way to the measurement page (result text and the
/// buttons of the runs), so the same two-second press on the status label opens it.
final class DictationProbePanel: UIView {
    static let lineCount = 5
    /// The smallest font any line may use; lines are never scaled below it.
    static let fontSize: CGFloat = 15

    private let lines: [UILabel]
    private let checklist = UIStackView()
    private let measurePage = UIView()
    private let resultLabel = UILabel()
    private var measureButtons: [MeasureCommand: UIButton] = [:]
    var onMeasureCommand: ((MeasureCommand) -> Void)?

    override init(frame: CGRect) {
        lines = (0..<Self.lineCount).map { _ in UILabel() }
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 8
        accessibilityIdentifier = "rk.dictationProbe"
        let stack = checklist
        for label in lines { stack.addArrangedSubview(label) }
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
        buildMeasurePage()
        for (index, label) in lines.enumerated() {
            label.font = .monospacedDigitSystemFont(ofSize: Self.fontSize, weight: .regular)
            label.textColor = .label
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.accessibilityIdentifier = "rk.dictationProbe.line\(index + 1)"
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildMeasurePage() {
        measurePage.isHidden = true
        measurePage.translatesAutoresizingMaskIntoConstraints = false
        addSubview(measurePage)
        NSLayoutConstraint.activate([
            measurePage.leadingAnchor.constraint(equalTo: leadingAnchor),
            measurePage.trailingAnchor.constraint(equalTo: trailingAnchor),
            measurePage.topAnchor.constraint(equalTo: topAnchor),
            measurePage.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        resultLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        resultLabel.textColor = .label
        resultLabel.numberOfLines = 0
        resultLabel.adjustsFontSizeToFitWidth = true
        resultLabel.minimumScaleFactor = 0.6
        resultLabel.accessibilityIdentifier = "rk.measure.result"
        let rows = [
            [(MeasureCommand.m2, "M2", "rk.measure.m2"), (.m3, "M3", "rk.measure.m3"), (.m3Smoke, "M3 小", "rk.measure.m3smoke"),
             (.m5, "M5", "rk.measure.m5")],
            [(.m6, "M6", "rk.measure.m6"), (.m4, "M4 觸控", "rk.measure.m4"), (.latency, "延遲 預設", "rk.measure.latency"),
             (.stop, "停止", "rk.measure.stop")]
        ].map { row in
            let buttons = row.map { command, title, identifier -> UIButton in
                let button = UIButton(type: .system)
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
                button.backgroundColor = .systemBackground
                button.layer.cornerRadius = 6
                button.accessibilityIdentifier = identifier
                button.addAction(UIAction { [weak self] _ in self?.onMeasureCommand?(command) }, for: .touchUpInside)
                measureButtons[command] = button
                return button
            }
            let rowStack = UIStackView(arrangedSubviews: buttons)
            rowStack.axis = .horizontal
            rowStack.distribution = .fillEqually
            rowStack.spacing = 6
            rowStack.heightAnchor.constraint(equalToConstant: 32).isActive = true
            return rowStack
        }
        let page = UIStackView(arrangedSubviews: [resultLabel] + rows)
        page.axis = .vertical
        page.spacing = 4
        page.isLayoutMarginsRelativeArrangement = true
        page.layoutMargins = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        page.translatesAutoresizingMaskIntoConstraints = false
        measurePage.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: measurePage.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: measurePage.trailingAnchor),
            page.topAnchor.constraint(equalTo: measurePage.topAnchor),
            page.bottomAnchor.constraint(equalTo: measurePage.bottomAnchor)
        ])
    }

    /// Shows the measurement page for a state, or the checklist for `nil`.
    func setMeasure(_ state: MeasurePanelState?) {
        measurePage.isHidden = state == nil
        checklist.isHidden = state != nil
        guard let state else { return }
        resultLabel.text = state.text
        for (command, button) in measureButtons {
            switch command {
            case .stop: button.isEnabled = state.enabled && state.running
            default: button.isEnabled = state.enabled && !state.running
            }
        }
        measureButtons[.latency]?.setTitle(state.latencyTitle, for: .normal)
    }

    /// Sets the lines; a missing line is blank.
    func setLines(_ texts: [String]) {
        for (index, label) in lines.enumerated() {
            label.text = index < texts.count ? texts[index] : ""
        }
    }
}
#endif
