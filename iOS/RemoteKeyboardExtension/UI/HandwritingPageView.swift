import RemoteKeyboardCore
import UIKit

/// The writing surface. It records the strokes as points in its own coordinates and draws them in the label colour,
/// so the ink follows dark mode. It reports when a stroke begins and when it ends.
final class InkCanvasView: UIView {
    var onStrokeBegan: (() -> Void)?
    /// A stroke ended; the arguments are all strokes (with touch times) and the canvas size.
    var onStrokesEnded: (([[InkPoint]], CGSize) -> Void)?

    private static let maxStrokes = 60
    private static let minPointDistance: CGFloat = 1
    private static let lineWidth: CGFloat = 5

    private(set) var strokes: [[InkPoint]] = []
    private var drawing = false

    var hasInk: Bool { !strokes.isEmpty }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        isOpaque = false
        backgroundColor = Self.surfaceColor
        layer.cornerRadius = 6
        layer.masksToBounds = true
        isAccessibilityElement = true
        accessibilityIdentifier = "rk.hwCanvas"
        accessibilityLabel = "手寫區"
        accessibilityTraits = .allowsDirectInteraction
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: InkCanvasView, _) in
            view.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func clear() {
        guard !strokes.isEmpty || drawing else { return }
        strokes = []
        drawing = false
        setNeedsDisplay()
    }

    #if DEBUG
    /// Debug preview only: shows ink without any touch.
    func showSample(_ sample: [[CGPoint]]) {
        strokes = sample.map { stroke in stroke.enumerated().map { InkPoint(x: $1.x, y: $1.y, t: Double($0) * 0.01) } }
        setNeedsDisplay()
    }
    #endif

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard !drawing, strokes.count < Self.maxStrokes, let touch = touches.first else { return }
        drawing = true
        strokes.append([Self.point(for: touch, in: self)])
        onStrokeBegan?()
        setNeedsDisplay()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard drawing, let touch = touches.first, !strokes.isEmpty else { return }
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for sample in samples {
            let point = Self.point(for: sample, in: self)
            if let last = strokes[strokes.count - 1].last, hypot(point.x - last.x, point.y - last.y) < Self.minPointDistance {
                continue
            }
            strokes[strokes.count - 1].append(point)
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesMoved(touches, with: event)
        finishStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishStroke()
    }

    /// The point and the touch's own timestamp (seconds since boot), which ML Kit uses as stroke timing.
    private static func point(for touch: UITouch, in view: UIView) -> InkPoint {
        let location = touch.location(in: view)
        return InkPoint(x: location.x, y: location.y, t: touch.timestamp)
    }

    private func finishStroke() {
        guard drawing else { return }
        drawing = false
        onStrokesEnded?(strokes, bounds.size)
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        UIColor.label.setStroke()
        for stroke in strokes {
            guard let firstPoint = stroke.first else { continue }
            let first = CGPoint(x: firstPoint.x, y: firstPoint.y)
            let path = UIBezierPath()
            path.lineWidth = Self.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: first)
            if stroke.count == 1 {
                path.addLine(to: first)
            } else {
                // Quadratic curves through the midpoints keep the line smooth between sampled points.
                var previous = first
                for inkPoint in stroke.dropFirst() {
                    let point = CGPoint(x: inkPoint.x, y: inkPoint.y)
                    let mid = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
                    path.addQuadCurve(to: mid, controlPoint: previous)
                    previous = point
                }
                path.addLine(to: previous)
            }
            path.stroke()
        }
    }

    static let surfaceColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.24, alpha: 1) : .white
    }
}

/// The handwriting page: the writing area over the three upper key rows, the full width. Delete sits at the right end
/// of the candidate row and 重寫 in the bottom row, so this view holds nothing else. The bottom row is `BottomRowView`,
/// shared with the other pages.
final class HandwritingPageView: UIView {
    /// A stroke started or ended; see `InkCanvasView`.
    var onStrokeBegan: (() -> Void)?
    var onStrokesEnded: (([[InkPoint]], CGSize) -> Void)?

    private let canvas = InkCanvasView()
    private let messageLabel = UILabel()
    private var message: String?

    /// Whether there are strokes on the writing area; the delete key uses it to decide if a press may repeat.
    var hasInk: Bool { canvas.hasInk }

    override init(frame: CGRect) {
        super.init(frame: frame)
        messageLabel.font = .systemFont(ofSize: 17)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.accessibilityIdentifier = "rk.hwMessage"
        for view in [canvas, messageLabel] { addSubview(view) }
        canvas.onStrokeBegan = { [weak self] in
            self?.updateMessage()
            self?.onStrokeBegan?()
        }
        canvas.onStrokesEnded = { [weak self] strokes, size in self?.onStrokesEnded?(strokes, size) }
        updateMessage()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// A text over the writing area, or nil when the user can write. While there is a message the area is not writable.
    func setMessage(_ text: String?) {
        guard text != message else { return }
        message = text
        canvas.isUserInteractionEnabled = text == nil
        updateMessage()
    }

    /// True while the writing area takes strokes (visible, touchable, no message over it).
    var acceptsInk: Bool { !canvas.isHidden && canvas.isUserInteractionEnabled }

    func clearInk() {
        canvas.clear()
        updateMessage()
    }

    #if DEBUG
    func showSampleInk() {
        let width = 160.0, height = 120.0
        let x = 110.0, y = 14.0
        func scaled(_ points: [(Double, Double)]) -> [CGPoint] {
            points.map { CGPoint(x: x + $0.0 * width, y: y + $0.1 * height) }
        }
        // A rough 禾: top stroke, horizontal, vertical, left falling, right falling.
        canvas.showSample([
            scaled([(0.20, 0.12), (0.45, 0.06), (0.70, 0.03)]),
            scaled([(0.05, 0.38), (0.30, 0.36), (0.60, 0.34), (0.90, 0.33)]),
            scaled([(0.48, 0.05), (0.49, 0.35), (0.49, 0.65), (0.48, 0.95)]),
            scaled([(0.42, 0.45), (0.30, 0.62), (0.15, 0.78), (0.02, 0.88)]),
            scaled([(0.55, 0.45), (0.68, 0.64), (0.82, 0.80), (0.98, 0.90)])
        ])
        updateMessage()
    }
    #endif

    private func updateMessage() {
        if let message {
            messageLabel.text = message
            messageLabel.textColor = .secondaryLabel
            messageLabel.isHidden = false
        } else {
            messageLabel.text = "在這裡手寫"
            messageLabel.textColor = .tertiaryLabel
            messageLabel.isHidden = canvas.hasInk
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        messageLabel.frame = canvas.frame.insetBy(dx: 16, dy: 8)
    }
}
