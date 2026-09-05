import AVFoundation
import AppKit
import CoreGraphics
import EventKit
import Speech

enum AssistantCapability: String, CaseIterable {
  case aiForwarding
  case microphone
  case speechRecognition
  case inputMonitoring
  case accessibility
  case screenCapture
  case clipboard
  case calendar
  case webSearch

  var title: String {
    switch self {
    case .aiForwarding: "Send to OpenAI"
    case .microphone: "Microphone"
    case .speechRecognition: "Transcription"
    case .inputMonitoring: "Fn Key"
    case .accessibility: "Selected Text"
    case .screenCapture: "Screen"
    case .clipboard: "Clipboard"
    case .calendar: "Calendar"
    case .webSearch: "Web Search"
    }
  }

  var defaultEnabled: Bool {
    switch self {
    case .microphone, .speechRecognition, .inputMonitoring, .accessibility, .clipboard, .webSearch:
      true
    case .aiForwarding: false
    case .screenCapture, .calendar: false
    }
  }

  var preferenceKey: String { "voiceAssistant.capability.\(rawValue).enabled" }

  func isEnabled(in defaults: UserDefaults) -> Bool {
    if self == .aiForwarding { return AIForwardingConsent.isEnabled(defaults: defaults) }
    guard defaults.object(forKey: preferenceKey) != nil else { return defaultEnabled }
    return defaults.bool(forKey: preferenceKey)
  }
}

enum AssistantCapabilityGroup: String, CaseIterable {
  case voice = "Voice"
  case interaction = "Interaction"
  case apps = "Apps"
  case online = "Online"

  var capabilities: [AssistantCapability] {
    switch self {
    case .voice: [.microphone, .speechRecognition]
    case .interaction: [.inputMonitoring, .accessibility, .screenCapture, .clipboard]
    case .apps: [.calendar]
    case .online: [.aiForwarding, .webSearch]
    }
  }

}

enum CapabilityAuthorization: Equatable {
  case available
  case notDetermined
  case denied
  case unavailable
}

enum MeetingPermissionError: LocalizedError, Equatable {
  case microphone
  case speechRecognition
  case screenCapture

  var errorDescription: String? {
    switch self {
    case .microphone:
      "Allow Microphone access, then start meeting recording again."
    case .speechRecognition:
      "Allow Speech Recognition, then start meeting recording again."
    case .screenCapture:
      "Allow Screen & System Audio Recording, then start meeting recording again."
    }
  }
}

struct CapabilitySnapshot: Equatable {
  let capability: AssistantCapability
  let enabled: Bool
  let authorization: CapabilityAuthorization

  var isUsable: Bool { enabled && authorization == .available }

  var menuTitle: String {
    let suffix = switch (enabled, authorization) {
    case (false, _): "Off"
    case (true, .available): "On"
    case (true, .notDetermined): "Allow…"
    case (true, .denied): "Settings…"
    case (true, .unavailable): "Unavailable"
    }
    return "\(capability.title): \(suffix)"
  }
}

@MainActor
final class PermissionController {
  var onChange: (() -> Void)?

  private let defaults: UserDefaults
  private let eventStore = EKEventStore()

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func snapshot(_ capability: AssistantCapability) -> CapabilitySnapshot {
    CapabilitySnapshot(
      capability: capability,
      enabled: isEnabled(capability),
      authorization: authorization(capability)
    )
  }

  func isUsable(_ capability: AssistantCapability) -> Bool {
    snapshot(capability).isUsable
  }

  func toggle(_ capability: AssistantCapability) {
    if capability == .aiForwarding {
      if AIForwardingConsent.isEnabled(defaults: defaults) {
        AIForwardingConsent.revoke(defaults: defaults)
      }
      onChange?()
      return
    }
    if isEnabled(capability) {
      defaults.set(false, forKey: capability.preferenceKey)
      onChange?()
      return
    }
    defaults.set(true, forKey: capability.preferenceKey)
    requestIfNeeded(capability)
    onChange?()
  }

  func acceptAIForwarding() {
    AIForwardingConsent.accept(defaults: defaults)
    onChange?()
  }

  func requestOrOpenSettings(_ capability: AssistantCapability) {
    if authorization(capability) == .denied {
      openSystemSettings(capability)
    } else {
      defaults.set(true, forKey: capability.preferenceKey)
      requestIfNeeded(capability)
      onChange?()
    }
  }

  func prepareForConversation() {
    for capability in [
      AssistantCapability.microphone,
      AssistantCapability.speechRecognition,
      AssistantCapability.inputMonitoring,
    ] {
      defaults.set(true, forKey: capability.preferenceKey)
    }
    requestIfNeeded(.inputMonitoring)
    onChange?()
  }

  func prepareForMeeting(
    completion: @escaping (Result<Void, MeetingPermissionError>) -> Void
  ) {
    defaults.set(true, forKey: AssistantCapability.screenCapture.preferenceKey)
    defaults.set(true, forKey: AssistantCapability.speechRecognition.preferenceKey)
    if #available(macOS 15.0, *) {
      defaults.set(true, forKey: AssistantCapability.microphone.preferenceKey)
      prepareMeetingMicrophone(completion: completion)
    } else {
      prepareMeetingSpeech(completion: completion)
    }
  }

  func codexSummary() -> String {
    let usable = AssistantCapability.allCases.filter(isUsable).map(\.rawValue).sorted()
    let disabled = AssistantCapability.allCases.filter { !isUsable($0) }.map(\.rawValue).sorted()
    let calendarHint = isUsable(.calendar)
      ? "Calendar is readable through $VOICE_ASSISTANT_EXECUTABLE calendar list."
      : "Calendar is unavailable."
    return "Enabled capabilities: \(usable.joined(separator: ", ")). Disabled or unavailable: \(disabled.joined(separator: ", ")). \(calendarHint) Files are governed by the user's request rather than an app-maintained path allowlist."
  }

  private func isEnabled(_ capability: AssistantCapability) -> Bool {
    capability.isEnabled(in: defaults)
  }

  private func authorization(_ capability: AssistantCapability) -> CapabilityAuthorization {
    switch capability {
    case .aiForwarding:
      return .available
    case .microphone:
      return captureAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
    case .speechRecognition:
      return speechAuthorization(SFSpeechRecognizer.authorizationStatus())
    case .inputMonitoring:
      return CGPreflightListenEventAccess() ? .available : .notDetermined
    case .accessibility:
      if AXIsProcessTrusted() { return .available }
      return defaults.bool(forKey: accessibilityPromptedKey) ? .denied : .notDetermined
    case .screenCapture:
      return CGPreflightScreenCaptureAccess() ? .available : .notDetermined
    case .clipboard:
      return .available
    case .calendar:
      return eventAuthorization(EKEventStore.authorizationStatus(for: .event))
    case .webSearch:
      return .available
    }
  }

  private func requestIfNeeded(_ capability: AssistantCapability) {
    guard authorization(capability) == .notDetermined else { return }
    switch capability {
    case .aiForwarding:
      return
    case .microphone:
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
        DispatchQueue.main.async { self?.onChange?() }
      }
    case .speechRecognition:
      SFSpeechRecognizer.requestAuthorization { [weak self] _ in
        DispatchQueue.main.async { self?.onChange?() }
      }
    case .inputMonitoring:
      _ = CGRequestListenEventAccess()
      onChange?()
    case .accessibility:
      defaults.set(true, forKey: accessibilityPromptedKey)
      let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
      _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
      onChange?()
    case .screenCapture:
      _ = CGRequestScreenCaptureAccess()
      onChange?()
    case .clipboard:
      return
    case .calendar:
      eventStore.requestFullAccessToEvents { [weak self] _, _ in
        DispatchQueue.main.async { self?.onChange?() }
      }
    case .webSearch:
      return
    }
  }

  private func openSystemSettings(_ capability: AssistantCapability) {
    let pane: String
    switch capability {
    case .aiForwarding: return
    case .microphone: pane = "Privacy_Microphone"
    case .speechRecognition: pane = "Privacy_SpeechRecognition"
    case .inputMonitoring: pane = "Privacy_ListenEvent"
    case .accessibility: pane = "Privacy_Accessibility"
    case .screenCapture: pane = "Privacy_ScreenCapture"
    case .clipboard: return
    case .calendar: pane = "Privacy_Calendars"
    case .webSearch: return
    }
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
      )
    else { return }
    NSWorkspace.shared.open(url)
  }

  private func prepareMeetingMicrophone(
    completion: @escaping (Result<Void, MeetingPermissionError>) -> Void
  ) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      prepareMeetingSpeech(completion: completion)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
        DispatchQueue.main.async {
          self?.onChange?()
          if allowed {
            self?.prepareMeetingSpeech(completion: completion)
          } else {
            completion(.failure(.microphone))
          }
        }
      }
    case .denied, .restricted:
      openSystemSettings(.microphone)
      completion(.failure(.microphone))
    @unknown default:
      completion(.failure(.microphone))
    }
  }

  private func prepareMeetingSpeech(
    completion: @escaping (Result<Void, MeetingPermissionError>) -> Void
  ) {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      prepareMeetingScreen(completion: completion)
    case .notDetermined:
      SFSpeechRecognizer.requestAuthorization { [weak self] status in
        DispatchQueue.main.async {
          self?.onChange?()
          if status == .authorized {
            self?.prepareMeetingScreen(completion: completion)
          } else {
            completion(.failure(.speechRecognition))
          }
        }
      }
    case .denied, .restricted:
      openSystemSettings(.speechRecognition)
      completion(.failure(.speechRecognition))
    @unknown default:
      completion(.failure(.speechRecognition))
    }
  }

  private func prepareMeetingScreen(
    completion: @escaping (Result<Void, MeetingPermissionError>) -> Void
  ) {
    if CGPreflightScreenCaptureAccess() {
      onChange?()
      completion(.success(()))
      return
    }
    let granted = CGRequestScreenCaptureAccess()
    onChange?()
    if granted {
      completion(.success(()))
    } else {
      openSystemSettings(.screenCapture)
      completion(.failure(.screenCapture))
    }
  }

  private var accessibilityPromptedKey: String {
    "voiceAssistant.capability.accessibility.prompted"
  }

  private func captureAuthorization(_ status: AVAuthorizationStatus) -> CapabilityAuthorization {
    switch status {
    case .authorized: .available
    case .notDetermined: .notDetermined
    case .denied, .restricted: .denied
    @unknown default: .unavailable
    }
  }

  private func speechAuthorization(_ status: SFSpeechRecognizerAuthorizationStatus)
    -> CapabilityAuthorization
  {
    switch status {
    case .authorized: .available
    case .notDetermined: .notDetermined
    case .denied, .restricted: .denied
    @unknown default: .unavailable
    }
  }

  private func eventAuthorization(_ status: EKAuthorizationStatus) -> CapabilityAuthorization {
    switch status {
    case .fullAccess, .authorized: .available
    case .notDetermined: .notDetermined
    case .denied, .restricted, .writeOnly: .denied
    @unknown default: .unavailable
    }
  }
}
