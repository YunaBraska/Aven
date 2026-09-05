import AppKit
import CoreGraphics
import Foundation

enum AssistantShortcutPreset: String, CaseIterable {
  case function = "fn"
  case leftCommand = "left-command"
  case rightCommand = "right-command"
  case leftOption = "left-option"
  case rightOption = "right-option"
  case leftControl = "left-control"
  case rightControl = "right-control"
  case leftShift = "left-shift"
  case rightShift = "right-shift"

  static let defaultPreset = AssistantShortcutPreset.function
  static let suggestedPresets: [AssistantShortcutPreset] = [.function, .rightOption, .rightControl]

  var displayName: String {
    switch self {
    case .function: "Fn"
    case .leftCommand: "Left Command"
    case .rightCommand: "Right Command"
    case .leftOption: "Left Option"
    case .rightOption: "Right Option"
    case .leftControl: "Left Control"
    case .rightControl: "Right Control"
    case .leftShift: "Left Shift"
    case .rightShift: "Right Shift"
    }
  }

  var keyCode: UInt16 {
    switch self {
    case .function: 63
    case .leftCommand: 55
    case .rightCommand: 54
    case .leftOption: 58
    case .rightOption: 61
    case .leftControl: 59
    case .rightControl: 62
    case .leftShift: 56
    case .rightShift: 60
    }
  }

  var appKitModifierFlag: NSEvent.ModifierFlags {
    switch self {
    case .function: .function
    case .leftCommand, .rightCommand: .command
    case .leftOption, .rightOption: .option
    case .leftControl, .rightControl: .control
    case .leftShift, .rightShift: .shift
    }
  }

  var cgEventFlag: CGEventFlags {
    switch self {
    case .function: .maskSecondaryFn
    case .leftCommand, .rightCommand: .maskCommand
    case .leftOption, .rightOption: .maskAlternate
    case .leftControl, .rightControl: .maskControl
    case .leftShift, .rightShift: .maskShift
    }
  }

  func matches(keyCode: UInt16) -> Bool {
    keyCode == self.keyCode
  }

  func isPressed(modifierFlags: NSEvent.ModifierFlags) -> Bool {
    modifierFlags.contains(appKitModifierFlag)
  }

  func isPressed(eventFlags: CGEventFlags) -> Bool {
    eventFlags.contains(cgEventFlag)
  }

  static func recorded(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Self? {
    allCases.first { $0.keyCode == keyCode && $0.isPressed(modifierFlags: modifierFlags) }
  }
}

final class AssistantShortcutStore {
  static let selectedPresetKey = "assistantShortcutPreset"

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var selectedPreset: AssistantShortcutPreset {
    guard let rawValue = defaults.string(forKey: Self.selectedPresetKey),
      let preset = AssistantShortcutPreset(rawValue: rawValue)
    else { return .defaultPreset }
    return preset
  }

  @discardableResult
  func select(_ preset: AssistantShortcutPreset) -> AssistantShortcutPreset {
    defaults.set(preset.rawValue, forKey: Self.selectedPresetKey)
    return preset
  }

  @discardableResult
  func reset() -> AssistantShortcutPreset {
    defaults.removeObject(forKey: Self.selectedPresetKey)
    return selectedPreset
  }
}
