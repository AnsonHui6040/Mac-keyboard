import UIKit

/// The keyboard's input view. `UIDevice.playInputClick()` plays only when this view, the controller's `inputView`,
/// adopts `UIInputViewAudioFeedback`; the system still applies the silent switch and the keyboard feedback setting.
final class ClickableInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    override init(frame: CGRect, inputViewStyle: UIInputView.Style) {
        super.init(frame: frame, inputViewStyle: inputViewStyle)
        // The controller's height constraint decides the keyboard height, as it did with the system's own view.
        allowsSelfSizing = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
