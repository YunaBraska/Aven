import AppKit
import QuartzCore

enum StatusMotion: Equatable {
  case none
  case breathe
  case consider
  case speak

  var keyPath: String? {
    switch self {
    case .none: nil
    case .breathe: "transform.scale"
    case .consider: "transform.rotation.z"
    case .speak: "transform.translation.y"
    }
  }
}

enum StatusAnimation {
  static func symbol(for state: AssistantState) -> String {
    switch state {
    case .idle, .failed:
      "face.smiling"
    case .listening:
      "mic.fill"
    case .transcribing:
      "waveform"
    case .routing:
      "arrow.triangle.branch"
    case .thinking, .working:
      "face.dashed"
    case .compacting:
      "arrow.down.right.and.arrow.up.left.circle"
    case .speaking:
      "speaker.wave.2.fill"
    case .paused:
      "pause.circle.fill"
    }
  }

  static func motion(for state: AssistantState) -> StatusMotion {
    switch state {
    case .listening: .breathe
    case .routing, .thinking, .working, .compacting: .consider
    case .transcribing, .speaking: .speak
    case .idle, .paused, .failed: .none
    }
  }

  static func shouldAnimate(_ motion: StatusMotion, reducedMotion: Bool) -> Bool {
    motion != .none && !reducedMotion
  }

  static func visual(
    for state: AssistantState,
    hasWarning: Bool,
    isMeetingRecording: Bool
  ) -> StatusIconVisual {
    StatusIconVisual(
      symbol: symbol(for: state),
      hasWarning: hasWarning,
      isMeetingRecording: isMeetingRecording
    )
  }
}

struct StatusIconVisual: Equatable {
  let symbol: String
  let hasWarning: Bool
  let isMeetingRecording: Bool
}

@MainActor
final class StatusIconAnimator: NSObject {
  private static let animationKey = "aven-status-motion"

  private weak var button: NSStatusBarButton?
  private var currentVisual: StatusIconVisual?
  private var currentMotion = StatusMotion.none
  private var latestState = AssistantState.idle

  init(button: NSStatusBarButton?) {
    self.button = button
    super.init()
    button?.wantsLayer = true
    button?.imagePosition = .imageOnly
    button?.title = ""
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(accessibilityDisplayOptionsDidChange),
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil
    )
  }

  func update(
    state: AssistantState,
    hasWarning: Bool = false,
    isMeetingRecording: Bool = false
  ) {
    latestState = state
    render(
      state: state,
      hasWarning: hasWarning,
      isMeetingRecording: isMeetingRecording,
      forceMotionRefresh: false
    )
  }

  @objc private func accessibilityDisplayOptionsDidChange() {
    render(
      state: latestState,
      hasWarning: currentVisual?.hasWarning ?? false,
      isMeetingRecording: currentVisual?.isMeetingRecording ?? false,
      forceMotionRefresh: true
    )
  }

  private func render(
    state: AssistantState,
    hasWarning: Bool,
    isMeetingRecording: Bool,
    forceMotionRefresh: Bool
  ) {
    guard let button else { return }
    let description = [
      state.statusText,
      isMeetingRecording ? "meeting recording active" : nil,
      hasWarning ? "warning" : nil,
    ].compactMap { $0 }.joined(separator: ", ")
    button.setAccessibilityLabel(description)
    button.toolTip = description
    let visual = StatusAnimation.visual(
      for: state,
      hasWarning: hasWarning,
      isMeetingRecording: isMeetingRecording
    )
    let motion = StatusAnimation.motion(for: state)

    if currentVisual != visual {
      button.image = Self.image(for: visual)
      currentVisual = visual
    }
    guard forceMotionRefresh || currentMotion != motion else { return }
    button.layer?.removeAnimation(forKey: Self.animationKey)
    currentMotion = motion
    guard StatusAnimation.shouldAnimate(
      motion,
      reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    ),
      let animation = animation(for: motion)
    else { return }
    button.layer?.add(animation, forKey: Self.animationKey)
  }

  private static func image(for visual: StatusIconVisual) -> NSImage? {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }
    draw(symbol: visual.symbol, in: NSRect(x: 0, y: 0, width: 18, height: 18))
    if visual.hasWarning {
      draw(symbol: "exclamationmark.triangle.fill", in: NSRect(x: 10, y: 10, width: 8, height: 8))
    }
    if visual.isMeetingRecording {
      draw(symbol: "record.circle.fill", in: NSRect(x: 10, y: 0, width: 8, height: 8))
    }
    image.isTemplate = true
    return image
  }

  private static func draw(symbol: String, in rect: NSRect) {
    let configuration = NSImage.SymbolConfiguration(pointSize: rect.width, weight: .medium)
    let source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      ?? NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)
    source?.withSymbolConfiguration(configuration)?.draw(in: rect)
  }

  private func animation(for motion: StatusMotion) -> CAKeyframeAnimation? {
    guard let keyPath = motion.keyPath else { return nil }
    let animation = CAKeyframeAnimation(keyPath: keyPath)
    switch motion {
    case .none:
      return nil
    case .breathe:
      animation.values = [1.0, 1.08, 1.0]
      animation.duration = 1.4
    case .consider:
      animation.values = [-0.07, 0.07, -0.07]
      animation.duration = 1.6
    case .speak:
      animation.values = [0.0, -1.0, 0.0, 1.0, 0.0]
      animation.duration = 1.0
    }
    animation.calculationMode = .cubic
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    return animation
  }
}
