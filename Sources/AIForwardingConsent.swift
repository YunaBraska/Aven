import Foundation

enum AIForwardingConsent {
  static let currentVersion = 1
  private static let enabledKey = "voiceAssistant.aiForwarding.enabled"
  private static let versionKey = "voiceAssistant.aiForwarding.consentVersion"
  private static let acceptedAtKey = "voiceAssistant.aiForwarding.acceptedAt"

  static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
    defaults.bool(forKey: enabledKey)
      && defaults.integer(forKey: versionKey) == currentVersion
      && defaults.object(forKey: acceptedAtKey) is Date
  }

  static func accept(defaults: UserDefaults = .standard, at date: Date = Date()) {
    defaults.set(true, forKey: enabledKey)
    defaults.set(currentVersion, forKey: versionKey)
    defaults.set(date, forKey: acceptedAtKey)
  }

  static func revoke(defaults: UserDefaults = .standard) {
    defaults.set(false, forKey: enabledKey)
    defaults.removeObject(forKey: versionKey)
    defaults.removeObject(forKey: acceptedAtKey)
  }
}
