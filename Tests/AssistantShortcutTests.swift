import Foundation

@main
enum AssistantShortcutTests {
  static func main() {
    keepsPresetRawValuesStable()
    exposesPhysicalHoldKeyMatchingData()
    restoresTheFunctionKeyWhenNoSelectionExists()
    recoversFromAnUnknownPersistedPreset()
    persistsTheSelectedPreset()
    updatesTheInactiveMonitorPreset()
    recordsAnyPhysicalModifierKey()
    cancelsFnDictationWhenAnotherModifierIsPressed()
    print("Assistant shortcut tests passed")
  }

  private static func keepsPresetRawValuesStable() {
    expect(AssistantShortcutPreset.function.rawValue == "fn", "Fn raw value must remain stable")
    expect(
      AssistantShortcutPreset.rightOption.rawValue == "right-option",
      "right Option raw value must remain stable"
    )
    expect(
      AssistantShortcutPreset.rightControl.rawValue == "right-control",
      "right Control raw value must remain stable"
    )
  }

  private static func exposesPhysicalHoldKeyMatchingData() {
    expect(AssistantShortcutPreset.function.keyCode == 63, "Fn must use its physical key code")
    expect(AssistantShortcutPreset.rightOption.keyCode == 61, "right Option key code")
    expect(AssistantShortcutPreset.rightControl.keyCode == 62, "right Control key code")
    expect(
      AssistantShortcutPreset.function.isPressed(modifierFlags: .function),
      "Fn must match its AppKit modifier flag"
    )
    expect(
      AssistantShortcutPreset.rightOption.isPressed(eventFlags: .maskAlternate),
      "right Option must match its Core Graphics flag"
    )
    expect(
      AssistantShortcutPreset.rightControl.isPressed(eventFlags: .maskControl),
      "right Control must match its Core Graphics flag"
    )
    expect(AssistantShortcutPreset.function.displayName == "Fn", "Fn display name")
    expect(AssistantShortcutPreset.rightOption.displayName == "Right Option", "Option display name")
    expect(AssistantShortcutPreset.rightControl.displayName == "Right Control", "Control display name")
  }

  private static func restoresTheFunctionKeyWhenNoSelectionExists() {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AssistantShortcutStore(defaults: defaults)

    expect(store.selectedPreset == .function, "missing selections must default to Fn")
    expect(store.reset() == .function, "reset must restore Fn")
  }

  private static func recoversFromAnUnknownPersistedPreset() {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("unsupported-key", forKey: AssistantShortcutStore.selectedPresetKey)

    expect(
      AssistantShortcutStore(defaults: defaults).selectedPreset == .function,
      "unknown selections must recover to Fn"
    )
  }

  private static func persistsTheSelectedPreset() {
    let (defaults, suiteName) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AssistantShortcutStore(defaults: defaults)

    expect(store.select(.rightControl) == .rightControl, "select should return the persisted preset")
    expect(
      AssistantShortcutStore(defaults: defaults).selectedPreset == .rightControl,
      "selected presets must survive a new store instance"
    )
  }

  private static func updatesTheInactiveMonitorPreset() {
    let monitor = GlobalHotKey(preset: .function)
    monitor.configure(.rightControl)
    expect(
      monitor.currentPreset == .rightControl,
      "a preset selected while monitoring is off must be used when it is enabled later"
    )
  }

  private static func recordsAnyPhysicalModifierKey() {
    expect(
      AssistantShortcutPreset.recorded(keyCode: 58, modifierFlags: .option) == .leftOption,
      "recording should distinguish the left Option key"
    )
    expect(
      AssistantShortcutPreset.recorded(keyCode: 60, modifierFlags: .shift) == .rightShift,
      "recording should distinguish the right Shift key"
    )
    expect(
      AssistantShortcutPreset.recorded(keyCode: 49, modifierFlags: []) == nil,
      "ordinary keys must not become hold-to-talk modifiers"
    )
  }

  private static func cancelsFnDictationWhenAnotherModifierIsPressed() {
    for keyCode: UInt16 in [55, 58, 56, 59, 57, 61, 60, 62, 54] {
      expect(
        FunctionKeyEvent.modifierAction(keyCode: keyCode, functionIsPressed: true)
          == .cancelDictation,
        "Fn plus modifier key \(keyCode) must cancel dictation"
      )
    }
    expect(
      FunctionKeyEvent.modifierAction(keyCode: 63, functionIsPressed: true) == nil,
      "releasing Fn must remain a normal hold transition"
    )
    expect(
      FunctionKeyEvent.modifierAction(keyCode: 58, functionIsPressed: false) == nil,
      "a modifier without Fn must remain untouched"
    )
    expect(
      FunctionKeyEvent.chordAction(keyCode: 15, functionIsPressed: true, isRepeat: false)
        == .repeatAnswer,
      "the Fn+R chord must remain available"
    )
    expect(
      FunctionKeyEvent.chordAction(keyCode: 35, functionIsPressed: true, isRepeat: false)
        == .pauseResume,
      "the Fn+P chord must remain available"
    )
    expect(
      FunctionKeyEvent.chordAction(keyCode: 53, functionIsPressed: true, isRepeat: false) == .stop,
      "the Fn+Escape chord must remain available"
    )
  }

  private static func isolatedDefaults() -> (UserDefaults, String) {
    let suiteName = "AssistantShortcutTests.\(UUID().uuidString)"
    return (UserDefaults(suiteName: suiteName)!, suiteName)
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    exit(1)
  }
}
