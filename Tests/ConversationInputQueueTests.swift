import Foundation

@main
@MainActor
enum ConversationInputQueueTests {
  static func main() {
    startsImmediatelyWhileIdle()
    queuesInputsWhilePreparingAndRouting()
    keepsPrelaunchScreenCaptureInRouting()
    drainsActiveInputsIntoOneSteeringMessage()
    preservesFifoWhenRejectedSteeringIsRequeued()
    queuesInputsUntilSpeechFinishes()
    keepsAttachmentsWithTheirInput()
    preservesDeliveryIdentityWhenCombiningSteering()
    preservesActiveAndSteeringInputForRetry()
    clearsPendingAndSubmittedInputs()
    rejectsEmptyInputsAtEveryQueueBoundary()
    print("Conversation input queue tests passed")
  }

  private static func startsImmediatelyWhileIdle() {
    let queue = ConversationInputQueue()

    expect(
      queue.submit("first", during: .idle) == .startTurn(ConversationInput(text: "first")),
      "idle input should begin a turn"
    )
    expect(queue.nextAction(during: .idle) == .none, "started input should not remain queued")
  }

  private static func queuesInputsWhilePreparingAndRouting() {
    let queue = ConversationInputQueue()

    expect(queue.submit("first", during: .preparing) == .queued, "preparing should queue input")
    expect(queue.submit("second", during: .routing) == .queued, "routing should queue input")
    expect(
      queue.nextAction(during: .activeTurn)
        == .steer(ConversationInput(text: "first\nsecond")),
      "queued inputs should become FIFO steering input once steerable"
    )
  }

  private static func keepsPrelaunchScreenCaptureInRouting() {
    let phase = ConversationInputQueue.phase(
      state: .routing,
      codexRunning: false,
      canSteer: false,
      contextMaintenanceInProgress: false
    )
    expect(phase == .routing, "routing before process reservation must never start a competing turn")
  }

  private static func drainsActiveInputsIntoOneSteeringMessage() {
    let queue = ConversationInputQueue()

    expect(
      queue.submit("first", during: .activeTurn)
        == .steer(ConversationInput(text: "first")),
      "first active input should steer immediately"
    )
    expect(queue.submit("second", during: .activeTurn) == .queued, "in-flight steering should serialize")
    _ = queue.acceptSteering()
    expect(
      queue.nextAction(during: .activeTurn) == .steer(ConversationInput(text: "second")),
      "accepted steering should allow the next queued input to drain"
    )
  }

  private static func preservesFifoWhenRejectedSteeringIsRequeued() {
    let queue = ConversationInputQueue()

    expect(
      queue.submit("first", during: .activeTurn)
        == .steer(ConversationInput(text: "first")),
      "first input should steer"
    )
    expect(queue.submit("second", during: .activeTurn) == .queued, "second input should queue")
    _ = queue.requeueRejectedSteering()
    expect(
      queue.nextAction(during: .idle) == .startTurn(ConversationInput(text: "first")),
      "rejected steering should be retried before later inputs"
    )
    expect(
      queue.nextAction(during: .idle) == .startTurn(ConversationInput(text: "second")),
      "later inputs should retain FIFO order"
    )
  }

  private static func queuesInputsUntilSpeechFinishes() {
    let queue = ConversationInputQueue()

    expect(queue.submit("next", during: .responding) == .queued, "response completion should queue input")
    expect(queue.submit("later", during: .speaking) == .queued, "speech should queue input")
    expect(
      queue.nextAction(during: .idle) == .startTurn(ConversationInput(text: "next")),
      "speech completion should start the oldest queued turn"
    )
    expect(
      queue.nextAction(during: .idle) == .startTurn(ConversationInput(text: "later")),
      "queued turns should remain FIFO"
    )
  }

  private static func clearsPendingAndSubmittedInputs() {
    let queue = ConversationInputQueue()
    _ = queue.submit("submitted", during: .activeTurn)
    _ = queue.submit("pending", during: .activeTurn)

    _ = queue.clear()

    expect(!queue.hasPendingInput, "stop should discard pending input")
    expect(!queue.hasSubmittedSteering, "stop should discard submitted steering")
    expect(queue.nextAction(during: .idle) == .none, "cleared input should not start a turn")
  }

  private static func rejectsEmptyInputsAtEveryQueueBoundary() {
    let queue = ConversationInputQueue(initialInputs: [ConversationInput(text: " \n ")])

    expect(
      queue.submit("\t", during: .idle) == .none,
      "empty live input must not begin a Codex turn"
    )
    expect(
      queue.submit(ConversationInput(text: " ", attachments: [URL(fileURLWithPath: "/tmp/empty")]),
        during: .activeTurn) == .none,
      "attachments must not turn empty input into steering"
    )
    expect(!queue.hasPendingInput, "empty startup and live inputs must not remain queued")
  }

  private static func keepsAttachmentsWithTheirInput() {
    let queue = ConversationInputQueue()
    let file = URL(fileURLWithPath: "/tmp/later.txt")
    _ = queue.submit("first", during: .speaking)
    _ = queue.submit("file context", attachments: [file], during: .speaking)

    expect(
      queue.nextAction(during: .idle) == .startTurn(ConversationInput(text: "first")),
      "an older request must not consume a later file"
    )
    expect(
      queue.nextAction(during: .idle)
        == .startTurn(ConversationInput(text: "file context", attachments: [file])),
      "a dropped file must remain attached to its own request"
    )
  }

  private static func preservesDeliveryIdentityWhenCombiningSteering() {
    let queue = ConversationInputQueue()
    let firstID = UUID()
    let secondID = UUID()
    _ = queue.submit(
      ConversationInput(text: "first", deliveryIDs: [firstID]),
      during: .preparing
    )
    _ = queue.submit(
      ConversationInput(text: "second", deliveryIDs: [secondID]),
      during: .preparing
    )

    expect(
      queue.nextAction(during: .activeTurn)
        == .steer(ConversationInput(text: "first\nsecond", deliveryIDs: [firstID, secondID])),
      "combined steering must retain every durable delivery identifier"
    )
  }

  private static func preservesActiveAndSteeringInputForRetry() {
    let queue = ConversationInputQueue()
    _ = queue.submit("steering", during: .activeTurn)
    _ = queue.submit("later", during: .activeTurn)

    _ = queue.preserveForRetry(activeInput: ConversationInput(text: "active"))

    expect(
      queue.nextAction(during: .idle) == .startTurn(ConversationInput(text: "active")),
      "preserved active work must be retried before its steering additions"
    )
    expect(
      queue.nextAction(during: .idle) == .startTurn(ConversationInput(text: "steering")),
      "submitted steering must remain durable after an infrastructure cancellation"
    )
    expect(
      queue.nextAction(during: .idle) == .startTurn(ConversationInput(text: "later")),
      "later queued input must retain FIFO order"
    )
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fail(message) }
  }

  private static func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
    exit(1)
  }
}
