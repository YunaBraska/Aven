import AppKit
import CoreGraphics
import Foundation
import OSLog

enum FunctionKeyTransition: Equatable {
  case pressed
  case released
}

struct FunctionKeyTracker {
  private(set) var isPressed = false

  mutating func update(isPressed newValue: Bool) -> FunctionKeyTransition? {
    guard newValue != isPressed else { return nil }
    isPressed = newValue
    return newValue ? .pressed : .released
  }

  mutating func reset() -> FunctionKeyTransition? {
    update(isPressed: false)
  }
}

enum FunctionKeyEvent {
  static let repeatKeyCode: UInt16 = 15
  static let pauseKeyCode: UInt16 = 35
  static let escapeKeyCode: UInt16 = 53

  static func isPhysicalHoldKey(
    keyCode: UInt16,
    preset: AssistantShortcutPreset = .function
  ) -> Bool {
    preset.matches(keyCode: keyCode)
  }

  static func isPhysicalFunctionKey(keyCode: UInt16) -> Bool {
    isPhysicalHoldKey(keyCode: keyCode, preset: .function)
  }

  static func modifierAction(
    keyCode: UInt16,
    functionIsPressed: Bool
  ) -> FunctionChordAction? {
    guard functionIsPressed, keyCode != AssistantShortcutPreset.function.keyCode else { return nil }
    return .cancelDictation
  }

  static func chordAction(
    keyCode: UInt16,
    functionIsPressed: Bool,
    isRepeat: Bool
  ) -> FunctionChordAction? {
    guard functionIsPressed, !isRepeat,
      !AssistantShortcutPreset.allCases.contains(where: { $0.keyCode == keyCode })
    else { return nil }
    return switch keyCode {
    case repeatKeyCode: .repeatAnswer
    case pauseKeyCode: .pauseResume
    case escapeKeyCode: .stop
    default: .cancelDictation
    }
  }
}

enum FunctionChordAction: Equatable {
  case repeatAnswer
  case pauseResume
  case stop
  case cancelDictation
}

private func functionKeyEventTapCallback(
  _ proxy: CGEventTapProxy,
  _ type: CGEventType,
  _ event: CGEvent,
  _ userData: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let userData else { return Unmanaged.passUnretained(event) }
  let controller = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
  if controller.receive(type: type, event: event) { return nil }
  return Unmanaged.passUnretained(event)
}

final class GlobalHotKey {
  var onPress: (() -> Void)?
  var onRelease: (() -> Void)?
  var onChord: ((FunctionChordAction) -> Void)?
  var onAvailabilityChange: ((Bool) -> Void)?

  private let logger = Logger(
    subsystem: "com.yunabraska.aven",
    category: "FunctionKey"
  )
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var permissionPoller: Timer?
  private var tracker = FunctionKeyTracker()
  private var lastRepeatDispatch = Date.distantPast
  private var preset: AssistantShortcutPreset

  init(preset: AssistantShortcutPreset = .function) {
    self.preset = preset
  }

  var currentPreset: AssistantShortcutPreset { preset }

  func configure(_ preset: AssistantShortcutPreset) {
    unregister()
    self.preset = preset
  }

  func use(_ preset: AssistantShortcutPreset) -> Bool {
    if preset == self.preset {
      return eventTap != nil || globalMonitor != nil ? true : register()
    }
    configure(preset)
    return register()
  }

  func register() -> Bool {
    unregister()
    globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in
      _ = self?.receive(event: event, source: "AppKit")
    }
    localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) {
      [weak self] event in
      self?.receive(event: event, source: "AppKit local") == true ? nil : event
    }

    let hasListenPermission = CGPreflightListenEventAccess() || CGRequestListenEventAccess()
    guard hasListenPermission else {
      logger.notice("Input Monitoring is not authorized; using physical AppKit Fn events")
      schedulePermissionUpgrade()
      let fallbackAvailable = globalMonitor != nil || localMonitor != nil
      onAvailabilityChange?(fallbackAvailable)
      return fallbackAvailable
    }

    let mask =
      (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
      | (CGEventMask(1) << CGEventType.keyDown.rawValue)
    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: mask,
        callback: functionKeyEventTapCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()
      )
    else {
      logger.error("CGEvent tap could not be created; using physical AppKit Fn events")
      let available = globalMonitor != nil || localMonitor != nil
      onAvailabilityChange?(available)
      return available
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    eventTap = tap
    runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    logger.notice("Fn monitoring registered")
    onAvailabilityChange?(true)
    return true
  }

  func unregister() {
    permissionPoller?.invalidate()
    permissionPoller = nil
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
      self.globalMonitor = nil
    }
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
    if let runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
      self.runLoopSource = nil
    }
    if let eventTap {
      CFMachPortInvalidate(eventTap)
      self.eventTap = nil
    }
    dispatch(tracker.reset())
  }

  fileprivate func receive(type: CGEventType, event: CGEvent) -> Bool {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
      dispatch(tracker.reset())
      return false
    }
    let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    if type == .keyDown {
      let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
      if let action = FunctionKeyEvent.chordAction(
        keyCode: keyCode,
        functionIsPressed: tracker.isPressed,
        isRepeat: isRepeat
      ) {
        dispatchChord(action)
        return action != .cancelDictation
      }
      return false
    }
    guard type == .flagsChanged else { return false }
    if preset == .function,
      let action = FunctionKeyEvent.modifierAction(
        keyCode: keyCode,
        functionIsPressed: tracker.isPressed
      )
    {
      _ = tracker.reset()
      dispatchChord(action)
      return false
    }
    guard FunctionKeyEvent.isPhysicalHoldKey(keyCode: keyCode, preset: preset) else { return false }
    receive(isPressed: preset.isPressed(eventFlags: event.flags), source: "CGEvent")
    return false
  }

  private func receive(event: NSEvent, source: String) -> Bool {
    if event.type == .keyDown {
      if let action = FunctionKeyEvent.chordAction(
        keyCode: event.keyCode,
        functionIsPressed: tracker.isPressed,
        isRepeat: event.isARepeat
      ) {
        dispatchChord(action)
        return action != .cancelDictation
      }
      return false
    }
    if preset == .function,
      let action = FunctionKeyEvent.modifierAction(
        keyCode: event.keyCode,
        functionIsPressed: tracker.isPressed
      )
    {
      _ = tracker.reset()
      dispatchChord(action)
      return false
    }
    guard FunctionKeyEvent.isPhysicalHoldKey(keyCode: event.keyCode, preset: preset) else {
      return false
    }
    receive(isPressed: preset.isPressed(modifierFlags: event.modifierFlags), source: source)
    return false
  }

  private func schedulePermissionUpgrade() {
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      guard CGPreflightListenEventAccess() else { return }
      _ = self?.register()
    }
    permissionPoller = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  private func receive(isPressed: Bool, source: String) {
    let transition = tracker.update(isPressed: isPressed)
    if let transition {
      logger.debug("Fn \(String(describing: transition), privacy: .public) via \(source, privacy: .public)")
    }
    dispatch(transition)
  }

  private func dispatch(_ transition: FunctionKeyTransition?) {
    guard let transition else { return }
    DispatchQueue.main.async { [weak self] in
      switch transition {
      case .pressed:
        self?.onPress?()
      case .released:
        self?.onRelease?()
      }
    }
  }

  private func dispatchChord(_ action: FunctionChordAction) {
    if action == .cancelDictation {
      DispatchQueue.main.async { [weak self] in self?.onChord?(action) }
      return
    }
    let now = Date()
    guard now.timeIntervalSince(lastRepeatDispatch) > 0.15 else { return }
    lastRepeatDispatch = now
    DispatchQueue.main.async { [weak self] in self?.onChord?(action) }
  }

  deinit {
    unregister()
  }
}
