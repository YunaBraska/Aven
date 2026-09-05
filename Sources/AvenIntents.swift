import AppIntents
import Foundation

enum AvenIntentAction: String, AppEnum {
  case listen
  case stop
  case pauseOrResume
  case repeatAnswer
  case openChat
  case clearContext
  case showResult
  case openUsage
  case progressOn
  case progressOff
  case startMeeting
  case stopMeeting

  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Aven Action")
  static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .listen: "Listen",
    .stop: "Stop",
    .pauseOrResume: "Pause or Resume",
    .repeatAnswer: "Repeat Answer",
    .openChat: "Open Chat",
    .clearContext: "Clear Context",
    .showResult: "Show Result",
    .openUsage: "Open Usage",
    .progressOn: "Speak Progress On",
    .progressOff: "Speak Progress Off",
    .startMeeting: "Start Meeting Recording",
    .stopMeeting: "Stop Meeting Recording",
  ]
}

@MainActor
enum AvenIntentBridge {
  static var control: ((AvenIntentAction) -> Bool)?
  static var send: ((String) -> Bool)?
}

enum AvenIntentError: Error, CustomLocalizedStringResourceConvertible {
  case unavailable
  case emptyInput

  var localizedStringResource: LocalizedStringResource {
    switch self {
    case .unavailable: "Aven is not ready for this action."
    case .emptyInput: "The message is empty."
    }
  }
}

struct AvenControlIntent: AppIntent {
  static let title: LocalizedStringResource = "Control Aven"
  static let description = IntentDescription(
    "Control listening, work, speech, meeting recording, progress, chat, results, usage, or conversation context."
  )
  static let openAppWhenRun = true

  @Parameter(title: "Action")
  var action: AvenIntentAction

  func perform() async throws -> some IntentResult {
    let accepted = await MainActor.run { AvenIntentBridge.control?(action) == true }
    guard accepted else { throw AvenIntentError.unavailable }
    return .result()
  }
}

struct SendToAvenIntent: AppIntent {
  static let title: LocalizedStringResource = "Send to Aven"
  static let description = IntentDescription(
    "Starts a request, adds context to startup, or steers the active Aven task."
  )
  static let openAppWhenRun = true

  @Parameter(title: "Message")
  var message: String

  func perform() async throws -> some IntentResult {
    let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { throw AvenIntentError.emptyInput }
    let accepted = await MainActor.run { AvenIntentBridge.send?(normalized) == true }
    guard accepted else { throw AvenIntentError.unavailable }
    return .result()
  }
}

struct AvenAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: AvenControlIntent(),
      phrases: ["Control \(.applicationName)"],
      shortTitle: "Control Aven",
      systemImageName: "waveform"
    )
    AppShortcut(
      intent: SendToAvenIntent(),
      phrases: ["Send to \(.applicationName)"],
      shortTitle: "Send to Aven",
      systemImageName: "text.bubble"
    )
  }
}
