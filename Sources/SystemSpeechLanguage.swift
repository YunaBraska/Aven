import CoreFoundation
import Foundation

enum SystemSpeechLanguage {
  private static let accessibilityDomain = "com.apple.Accessibility" as CFString
  private static let assistantDomain = "com.apple.assistant.backedup" as CFString

  static var currentIdentifier: String {
    let configured = CFPreferencesCopyAppValue(
      "SystemTTSLanguage" as CFString,
      "com.apple.speech.voice.prefs" as CFString
    ) as? String
    return resolve(configured: configured, fallback: Locale.current.identifier)
  }

  static var currentLocale: Locale {
    Locale(identifier: currentIdentifier)
  }

  static var menuLabel: String {
    let languageCode = currentIdentifier
      .replacingOccurrences(of: "_", with: "-")
      .split(separator: "-")
      .first
      .map(String.init) ?? currentIdentifier
    let language = Locale.current.localizedString(forLanguageCode: languageCode)?.capitalized
      ?? languageCode.uppercased()
    let voice = selectedVoiceIdentifier(languageCode: languageCode)
      .flatMap(voiceLabel(identifier:)) ?? "System Voice"
    return "\(language) / \(voice)"
  }

  static let settingsURLs = [
    "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
    "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent",
  ].compactMap(URL.init(string:))

  static var contextCleared: String {
    currentIdentifier.lowercased().hasPrefix("de") ? "Kontext gelöscht." : "Context cleared."
  }

  static func resolve(configured: String?, fallback: String) -> String {
    let value = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? fallback : value
  }

  static func voiceLabel(identifier: String) -> String? {
    let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let marker = trimmed.split(whereSeparator: { $0 == "." || $0 == "-" }).last,
      marker.count == 1,
      let scalar = marker.uppercased().unicodeScalars.first,
      scalar.value >= 65, scalar.value <= 90
    {
      return String(format: "Voice%02d", scalar.value - 64)
    }
    return trimmed.split(separator: ".").last.map(String.init)
  }

  private static func selectedVoiceIdentifier(languageCode: String) -> String? {
    if let selections = CFPreferencesCopyAppValue(
      "SpokenContentDefaultVoiceSelectionsByLanguage" as CFString,
      accessibilityDomain
    ) as? [Any] {
      var index = 0
      while index + 1 < selections.count {
        let key = selections[index] as? String
        let value = selections[index + 1] as? [String: Any]
        if key?.lowercased() == languageCode.lowercased(),
          let identifier = value?["voiceId"] as? String
        {
          return identifier
        }
        index += 2
      }
    }
    guard let output = CFPreferencesCopyAppValue(
      "Output Voice" as CFString,
      assistantDomain
    ) as? [String: Any]
    else { return nil }
    return output["Name"] as? String
  }

  static func spokenProgress(_ progress: CodexProgress) -> String {
    let isGerman = currentIdentifier.lowercased().hasPrefix("de")
    return switch (progress, isGerman) {
    case (.routing, true): ""
    case (.thinking, true): "Ich denke nach."
    case (.searching, true): "Ich suche kurz."
    case (.working, true): "Ich arbeite daran."
    case (.workers, true): ""
    case (.update(let text), true): text
    case (.routing, false): ""
    case (.thinking, false): "I'm thinking."
    case (.searching, false): "I'm searching."
    case (.working, false): "I'm working on it."
    case (.workers, false): ""
    case (.update(let text), false): text
    }
  }
}
