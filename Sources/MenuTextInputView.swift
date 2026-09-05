import AppKit

@MainActor
final class MenuTextInputView: NSView, NSTextFieldDelegate {
  /// Returns true only after the caller has durably accepted the message.
  var onSubmit: ((String) -> Bool)?

  private let textField = NSTextField()

  override init(frame frameRect: NSRect) {
    let size = NSSize(width: 286, height: 40)
    super.init(frame: NSRect(origin: frameRect.origin, size: size))
    configureTextField()
    textField.frame = NSRect(x: 12, y: 7, width: 262, height: 26)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is unavailable")
  }

  private func configureTextField() {
    textField.placeholderString = "Message Aven"
    textField.font = .systemFont(ofSize: NSFont.systemFontSize)
    textField.delegate = self
    textField.setAccessibilityLabel("Message Aven")
    addSubview(textField)
  }

  func control(
    _ control: NSControl,
    textView: NSTextView,
    doCommandBy commandSelector: Selector
  ) -> Bool {
    guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
    submit()
    return true
  }

  private func submit() {
    let message = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return }
    guard onSubmit?(message) == true else { return }
    textField.stringValue = ""
    enclosingMenuItem?.menu?.cancelTracking()
  }
}
