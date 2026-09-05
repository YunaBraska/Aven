import Foundation

@main
enum MeetingRecorderTests {
  static func main() {
    writesDurableJsonLinesAndFinalMetadata()
    drainsQueuedSegmentsBeforeFinishing()
    serializesAndCancelsPermissionStarts()
    print("Meeting recorder tests passed")
  }

  private static func writesDurableJsonLinesAndFinalMetadata() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-meeting-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try! MeetingTranscriptStore(rootURL: root)
    let segment = MeetingTranscriptSegment(
      id: UUID(),
      startMilliseconds: 1_000,
      endMilliseconds: 2_500,
      source: "system",
      language: "de-DE",
      text: "Eine Entscheidung",
      confidence: 0.9
    )

    try! store.append(segment)
    store.finish()

    let lines = try! String(contentsOf: store.transcriptURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
    expect(lines.count == 1, "each finalized segment should produce one JSONL record")
    let decoded = try! JSONDecoder().decode(
      MeetingTranscriptSegment.self,
      from: Data(lines[0].utf8)
    )
    expect(decoded == segment, "the transcript must preserve timing, source, language, and text")
    let metadataURL = store.directoryURL.appendingPathComponent("meeting.json")
    let metadata = try! JSONSerialization.jsonObject(
      with: Data(contentsOf: metadataURL)
    ) as! [String: Any]
    expect(metadata["status"] as? String == "completed", "stopping should finalize meeting metadata")
    let transcriptMode = try! FileManager.default.attributesOfItem(
      atPath: store.transcriptURL.path
    )[.posixPermissions] as! NSNumber
    expect(transcriptMode.intValue == 0o600, "meeting transcripts must be private to the user")
    let contents = try! FileManager.default.contentsOfDirectory(atPath: store.directoryURL.path)
    expect(Set(contents) == ["live.jsonl", "meeting.json"], "raw audio must not be stored")
  }

  private static func drainsQueuedSegmentsBeforeFinishing() {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aven-meeting-async-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try! MeetingTranscriptStore(rootURL: root)
    let segment = MeetingTranscriptSegment(
      id: UUID(),
      startMilliseconds: 1_000,
      endMilliseconds: 2_500,
      source: "microphone",
      language: "de-DE",
      text: "Letzte Worte",
      confidence: nil
    )
    let finished = DispatchSemaphore(value: 0)

    store.appendAsync(segment) { result in
      guard case .success = result else {
        expect(false, "queued segment persistence should report success")
        return
      }
    }
    store.finishAsync { result in
      guard case .success = result else {
        expect(false, "finishing should report metadata persistence failures")
        return
      }
      finished.signal()
    }
    expect(
      finished.wait(timeout: .now() + 2) == .success,
      "finishing should wait for earlier queued transcript segments"
    )
    let lines = try! String(contentsOf: store.transcriptURL, encoding: .utf8)
      .split(whereSeparator: \.isNewline)
    expect(lines.count == 1, "queued segment must remain after asynchronous finish")
  }

  private static func serializesAndCancelsPermissionStarts() {
    var gate = MeetingStartGate()
    let first = gate.begin()
    expect(first != nil, "the first permission request should reserve meeting start")
    expect(gate.begin() == nil, "a second meeting start must not race the active permission request")
    gate.cancel()
    expect(
      gate.accept(first!) == false,
      "a permission callback arriving after stop must not start capture"
    )
    let second = gate.begin()
    expect(second != nil, "a cancelled permission request must allow a later start")
    expect(gate.accept(second!) == true, "only the current permission callback may continue")
    expect(!gate.isWaitingForPermission, "accepted permission must leave the preflight phase")
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
      exit(1)
    }
  }
}
