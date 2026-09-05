import AppKit

@MainActor
final class AboutPanelController: NSWindowController {
  private static let messages = [
    "Hold a key. Say the thing. Aven handles the paperwork.",
    "Quiet when idle. Useful when summoned. A rare software achievement.",
    "A voice assistant with a healthy respect for your focus.",
    "The shortest path from thought to finished work should not be another window.",
  ]

  convenience init() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "About Aven"
    window.isReleasedWhenClosed = false
    window.center()
    self.init(window: window)
    window.contentView = makeContent()
  }

  func present() {
    guard let window else { return }
    window.center()
    showWindow(nil)
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func makeContent() -> NSView {
    let root = NSView()
    root.translatesAutoresizingMaskIntoConstraints = false

    let icon = NSImageView(image: NSApp.applicationIconImage)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.imageScaling = .scaleProportionallyUpOrDown

    let name = label("Aven", size: 26, weight: .semibold, color: .labelColor)
    let tagline = label(
      "A quiet voice companion for focused work.",
      size: 13,
      weight: .regular,
      color: .secondaryLabelColor
    )
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? ""
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    let versionLabel = label(
      "Version \(version) · Build \(build)",
      size: 11,
      weight: .regular,
      color: .tertiaryLabelColor
    )
    let titleStack = NSStackView(views: [name, tagline, versionLabel])
    titleStack.orientation = .vertical
    titleStack.alignment = .leading
    titleStack.spacing = 4
    titleStack.translatesAutoresizingMaskIntoConstraints = false

    let header = NSStackView(views: [icon, titleStack])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 16
    header.translatesAutoresizingMaskIntoConstraints = false

    let message = label(
      Self.messages.randomElement() ?? Self.messages[0],
      size: 14,
      weight: .regular,
      color: .labelColor
    )
    message.maximumNumberOfLines = 0
    message.lineBreakMode = .byWordWrapping
    message.alignment = .center

    let messageContent = NSView()
    messageContent.addSubview(message)
    NSLayoutConstraint.activate([
      message.leadingAnchor.constraint(equalTo: messageContent.leadingAnchor, constant: 18),
      message.trailingAnchor.constraint(equalTo: messageContent.trailingAnchor, constant: -18),
      message.centerYAnchor.constraint(equalTo: messageContent.centerYAnchor),
    ])

    let messageBox = NSBox()
    messageBox.boxType = .custom
    messageBox.borderColor = .separatorColor
    messageBox.borderWidth = 1
    messageBox.cornerRadius = 10
    messageBox.fillColor = .controlBackgroundColor
    messageBox.contentView = messageContent
    messageBox.translatesAutoresizingMaskIntoConstraints = false

    let supportTitle = label("Support & project", size: 13, weight: .semibold, color: .labelColor)
    let sponsor = linkButton("GitHub Sponsors", url: "https://github.com/sponsors/YunaBraska")
    let repository = linkButton("Aven on GitHub", url: "https://github.com/YunaBraska/Aven")
    let buttons = NSStackView(views: [sponsor, repository])
    buttons.orientation = .horizontal
    buttons.alignment = .centerY
    buttons.spacing = 8
    buttons.translatesAutoresizingMaskIntoConstraints = false

    let author = label(
      "Made with care by Yuna Morgenstern.",
      size: 11,
      weight: .regular,
      color: .secondaryLabelColor
    )

    [header, messageBox, supportTitle, buttons, author].forEach(root.addSubview)
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 88),
      icon.heightAnchor.constraint(equalToConstant: 88),
      header.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
      header.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -30),
      messageBox.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
      messageBox.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 30),
      messageBox.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -30),
      messageBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 82),
      supportTitle.topAnchor.constraint(equalTo: messageBox.bottomAnchor, constant: 24),
      supportTitle.leadingAnchor.constraint(equalTo: messageBox.leadingAnchor),
      buttons.topAnchor.constraint(equalTo: supportTitle.bottomAnchor, constant: 10),
      buttons.leadingAnchor.constraint(equalTo: messageBox.leadingAnchor),
      buttons.trailingAnchor.constraint(lessThanOrEqualTo: messageBox.trailingAnchor),
      author.leadingAnchor.constraint(equalTo: messageBox.leadingAnchor),
      author.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
    ])
    return root
  }

  private func label(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor
  ) -> NSTextField {
    let value = NSTextField(labelWithString: text)
    value.font = .systemFont(ofSize: size, weight: weight)
    value.textColor = color
    value.translatesAutoresizingMaskIntoConstraints = false
    return value
  }

  private func linkButton(_ title: String, url: String) -> NSButton {
    let button = NSButton(title: title, target: self, action: #selector(openLink(_:)))
    button.bezelStyle = .rounded
    button.controlSize = .regular
    button.identifier = NSUserInterfaceItemIdentifier(url)
    return button
  }

  @objc private func openLink(_ sender: NSButton) {
    guard let value = sender.identifier?.rawValue, let url = URL(string: value) else { return }
    NSWorkspace.shared.open(url)
  }
}
