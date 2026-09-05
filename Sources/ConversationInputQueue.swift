import Foundation

struct ConversationInput: Equatable {
  let text: String
  let attachments: [URL]
  let deliveryIDs: [UUID]

  init(text: String, attachments: [URL] = [], deliveryIDs: [UUID] = []) {
    self.text = text
    self.attachments = attachments
    self.deliveryIDs = deliveryIDs
  }

  static func combined(_ values: [Self]) -> Self {
    var seen = Set<String>()
    let attachments = values.flatMap(\.attachments).filter {
      seen.insert($0.standardizedFileURL.path).inserted
    }
    return Self(
      text: values.map(\.text).joined(separator: "\n"),
      attachments: attachments,
      deliveryIDs: values.flatMap(\.deliveryIDs)
    )
  }
}

@MainActor
final class ConversationInputQueue {
  enum Phase: Equatable {
    case idle
    case preparing
    case routing
    case activeTurn
    case responding
    case speaking
  }

  enum Action: Equatable {
    case none
    case queued
    case startTurn(ConversationInput)
    case steer(ConversationInput)
  }

  private var pending: [ConversationInput] = []
  private var submittedSteering: [ConversationInput]?

  init(initialInputs: [ConversationInput] = []) {
    pending = initialInputs.compactMap { $0.normalized }
  }

  var hasPendingInput: Bool { !pending.isEmpty }

  var hasSubmittedSteering: Bool { submittedSteering != nil }

  static func phase(
    state: AssistantState,
    codexRunning: Bool,
    canSteer: Bool,
    contextMaintenanceInProgress: Bool
  ) -> Phase {
    if canSteer { return .activeTurn }
    if state == .routing { return .routing }
    if codexRunning || contextMaintenanceInProgress || state == .compacting { return .preparing }
    if state == .speaking || state == .paused { return .speaking }
    if state == .thinking || state.isWorking { return .responding }
    return .idle
  }

  func submit(_ text: String, attachments: [URL] = [], during phase: Phase) -> Action {
    submit(ConversationInput(text: text, attachments: attachments), during: phase)
  }

  func submit(_ input: ConversationInput, during phase: Phase) -> Action {
    guard let input = input.normalized else { return .none }
    pending.append(input)
    switch phase {
    case .idle:
      return nextAction(during: phase)
    case .activeTurn:
      guard submittedSteering == nil else { return .queued }
      return nextAction(during: phase)
    case .preparing, .routing, .responding, .speaking:
      return .queued
    }
  }

  func nextAction(during phase: Phase) -> Action {
    switch phase {
    case .idle:
      guard submittedSteering == nil, !pending.isEmpty else { return .none }
      return .startTurn(pending.removeFirst())
    case .activeTurn:
      guard submittedSteering == nil, !pending.isEmpty else { return .none }
      let inputs = pending
      pending.removeAll(keepingCapacity: true)
      submittedSteering = inputs
      return .steer(.combined(inputs))
    case .preparing, .routing, .responding, .speaking:
      return .none
    }
  }

  func acceptSteering() -> Self {
    submittedSteering = nil
    return self
  }

  func requeueRejectedSteering() -> Self {
    guard let submittedSteering else { return self }
    pending.insert(contentsOf: submittedSteering, at: 0)
    self.submittedSteering = nil
    return self
  }

  func requeueStarted(_ input: ConversationInput) -> Self {
    pending.insert(input, at: 0)
    return self
  }

  func preserveForRetry(activeInput: ConversationInput?) -> Self {
    _ = requeueRejectedSteering()
    if let activeInput { pending.insert(activeInput, at: 0) }
    return self
  }

  func clear() -> Self {
    pending.removeAll(keepingCapacity: false)
    submittedSteering = nil
    return self
  }
}

private extension ConversationInput {
  var normalized: Self? {
    let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedText.isEmpty else { return nil }
    return Self(text: normalizedText, attachments: attachments, deliveryIDs: deliveryIDs)
  }
}
