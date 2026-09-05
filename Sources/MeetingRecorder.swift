import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

enum MeetingRecorderError: LocalizedError, Equatable {
  case alreadyActive
  case noDisplay
  case onDeviceSpeechUnavailable
  case storage(String)
  case capture(String)
  case transcription(String)

  var errorDescription: String? {
    switch self {
    case .alreadyActive:
      "Meeting recording is already active."
    case .noDisplay:
      "No display is available for meeting audio capture."
    case .onDeviceSpeechUnavailable:
      "On-device speech recognition is unavailable for the current system language."
    case .storage(let detail):
      "The meeting transcript could not be stored: \(detail)"
    case .capture(let detail):
      "Meeting recording could not start: \(detail)"
    case .transcription(let detail):
      "Meeting transcription was interrupted: \(detail)"
    }
  }
}

struct MeetingTranscriptSegment: Codable, Equatable {
  let id: UUID
  let startMilliseconds: Int64
  let endMilliseconds: Int64
  let source: String
  let language: String
  let text: String
  let confidence: Float?

  enum CodingKeys: String, CodingKey {
    case id
    case startMilliseconds = "start_ms"
    case endMilliseconds = "end_ms"
    case source
    case language
    case text
    case confidence
  }
}

/// Owns the permission-request phase before ScreenCaptureKit can enter its own start state.
struct MeetingStartGate: Equatable {
  private(set) var generation = 0
  private(set) var isWaitingForPermission = false

  mutating func begin() -> Int? {
    guard !isWaitingForPermission else { return nil }
    generation += 1
    isWaitingForPermission = true
    return generation
  }

  mutating func accept(_ candidate: Int) -> Bool {
    guard isWaitingForPermission, candidate == generation else { return false }
    isWaitingForPermission = false
    return true
  }

  mutating func cancel() {
    generation += 1
    isWaitingForPermission = false
  }
}

final class MeetingTranscriptStore {
  private struct Metadata: Codable {
    let id: UUID
    let startedMilliseconds: Int64
    let endedMilliseconds: Int64?
    let status: String
    let transcript: String

    enum CodingKeys: String, CodingKey {
      case id
      case startedMilliseconds = "started_ms"
      case endedMilliseconds = "ended_ms"
      case status
      case transcript
    }
  }

  let id = UUID()
  let startedAt = Date()
  let directoryURL: URL
  let transcriptURL: URL
  private let metadataURL: URL
  private let handle: FileHandle
  private let persistenceQueue = DispatchQueue(label: "aven.meeting.persistence", qos: .utility)
  private var finished = false

  init(rootURL: URL) throws {
    let stamp = ISO8601DateFormatter.meetingIdentifier.string(from: startedAt)
      .replacingOccurrences(of: ":", with: "-")
    directoryURL = rootURL.appendingPathComponent("\(stamp)-\(id.uuidString.lowercased())")
    transcriptURL = directoryURL.appendingPathComponent("live.jsonl")
    metadataURL = directoryURL.appendingPathComponent("meeting.json")
    do {
      try FileManager.default.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      guard FileManager.default.createFile(
        atPath: transcriptURL.path,
        contents: nil,
        attributes: [.posixPermissions: 0o600]
      ) else {
        throw MeetingRecorderError.storage("The transcript file could not be created.")
      }
      handle = try FileHandle(forWritingTo: transcriptURL)
      try writeMetadata(status: "recording", endedAt: nil)
    } catch let error as MeetingRecorderError {
      throw error
    } catch {
      throw MeetingRecorderError.storage(error.localizedDescription)
    }
  }

  func append(_ segment: MeetingTranscriptSegment) throws {
    try persistenceQueue.sync { try appendNow(segment) }
  }

  func appendAsync(
    _ segment: MeetingTranscriptSegment,
    completion: @escaping (Result<Void, MeetingRecorderError>) -> Void
  ) {
    persistenceQueue.async {
      do {
        try self.appendNow(segment)
        completion(.success(()))
      } catch let error as MeetingRecorderError {
        completion(.failure(error))
      } catch {
        completion(.failure(.storage(error.localizedDescription)))
      }
    }
  }

  func finishAsync(
    status: String = "completed",
    completion: @escaping (Result<Void, MeetingRecorderError>) -> Void
  ) {
    persistenceQueue.async {
      do {
        try self.finishNow(status: status)
        completion(.success(()))
      } catch let error as MeetingRecorderError {
        completion(.failure(error))
      } catch {
        completion(.failure(.storage(error.localizedDescription)))
      }
    }
  }

  private func appendNow(_ segment: MeetingTranscriptSegment) throws {
    guard !finished else { return }
    var data = try JSONEncoder.meeting.encode(segment)
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }

  func finish(status: String = "completed") {
    _ = try? persistenceQueue.sync { try finishNow(status: status) }
  }

  private func finishNow(status: String) throws {
    guard !finished else { return }
    finished = true
    do {
      try handle.synchronize()
      try handle.close()
      try writeMetadata(status: status, endedAt: Date())
    } catch {
      throw MeetingRecorderError.storage(error.localizedDescription)
    }
  }

  private func writeMetadata(status: String, endedAt: Date?) throws {
    let metadata = Metadata(
      id: id,
      startedMilliseconds: startedAt.epochMilliseconds,
      endedMilliseconds: endedAt?.epochMilliseconds,
      status: status,
      transcript: transcriptURL.lastPathComponent
    )
    let data = try JSONEncoder.meeting.encode(metadata)
    try data.write(to: metadataURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: metadataURL.path
    )
  }
}

private final class LiveMeetingTranscriber {
  private static let maximumConsecutiveFailures = 2
  private static let finalResultTimeout: TimeInterval = 1.5

  private let source: String
  private let locale: Locale
  private let queue: DispatchQueue
  private let writer: MeetingTranscriptStore
  private let onError: (MeetingRecorderError) -> Void
  private let recognizer: SFSpeechRecognizer
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var latestResult: SFSpeechRecognitionResult?
  private var chunkStartedAt = Date()
  private var generation = 0
  private var active = false
  private var stoppingCompletion: (() -> Void)?
  private var consecutiveFailures = 0

  init?(
    source: String,
    locale: Locale,
    queue: DispatchQueue,
    writer: MeetingTranscriptStore,
    onError: @escaping (MeetingRecorderError) -> Void
  ) {
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition
    else { return nil }
    self.source = source
    self.locale = locale
    self.queue = queue
    self.writer = writer
    self.onError = onError
    self.recognizer = recognizer
  }

  func start() {
    active = true
    beginChunk()
  }

  func append(_ sampleBuffer: CMSampleBuffer) {
    guard active, CMSampleBufferDataIsReady(sampleBuffer) else { return }
    request?.appendAudioSampleBuffer(sampleBuffer)
  }

  func rotate() {
    guard active else { return }
    commitLatest()
    endChunk()
    beginChunk()
  }

  func stop(completion: @escaping () -> Void = {}) {
    guard active else {
      completion()
      return
    }
    active = false
    stoppingCompletion = completion
    let currentGeneration = generation
    request?.endAudio()
    queue.asyncAfter(deadline: .now() + Self.finalResultTimeout) { [weak self] in
      guard let self, self.generation == currentGeneration else { return }
      self.completeStoppingChunk()
    }
  }

  func stopImmediately() {
    guard active || stoppingCompletion != nil else { return }
    active = false
    stoppingCompletion = nil
    commitLatest()
    endChunk()
  }

  private func beginChunk() {
    generation += 1
    let currentGeneration = generation
    chunkStartedAt = Date()
    latestResult = nil
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.requiresOnDeviceRecognition = true
    request.taskHint = .dictation
    self.request = request
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      guard let self else { return }
      self.queue.async {
        guard self.generation == currentGeneration,
          self.active || self.stoppingCompletion != nil
        else { return }
        if let result {
          self.latestResult = result
          self.consecutiveFailures = 0
          if result.isFinal {
            self.commitLatest()
            if self.stoppingCompletion != nil {
              self.completeStoppingChunk()
            } else {
              self.endChunk()
              if self.active { self.beginChunk() }
            }
          }
        } else if let error {
          self.commitLatest()
          self.onError(.transcription(error.localizedDescription))
          if self.stoppingCompletion != nil {
            self.completeStoppingChunk()
            return
          }
          self.endChunk()
          self.consecutiveFailures += 1
          guard self.consecutiveFailures <= Self.maximumConsecutiveFailures else {
            self.active = false
            return
          }
          let restartGeneration = self.generation
          self.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.active, self.generation == restartGeneration else { return }
            self.beginChunk()
          }
        }
      }
    }
  }

  private func endChunk() {
    generation += 1
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
    latestResult = nil
  }

  private func completeStoppingChunk() {
    guard let completion = stoppingCompletion else { return }
    stoppingCompletion = nil
    commitLatest()
    endChunk()
    completion()
  }

  private func commitLatest() {
    guard let result = latestResult else { return }
    let text = result.bestTranscription.formattedString
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let segments = result.bestTranscription.segments
    let startOffset = segments.first?.timestamp ?? 0
    let endOffset = segments.last.map { $0.timestamp + $0.duration }
      ?? Date().timeIntervalSince(chunkStartedAt)
    let confidenceValues = segments.map(\.confidence).filter { $0 > 0 }
    let confidence = confidenceValues.isEmpty
      ? nil : confidenceValues.reduce(0, +) / Float(confidenceValues.count)
    let segment = MeetingTranscriptSegment(
      id: UUID(),
      startMilliseconds: chunkStartedAt.addingTimeInterval(startOffset).epochMilliseconds,
      endMilliseconds: chunkStartedAt.addingTimeInterval(endOffset).epochMilliseconds,
      source: source,
      language: locale.identifier,
      text: text,
      confidence: confidence
    )
    writer.appendAsync(segment) { [weak self] result in
      guard case .failure(let error) = result else { return }
      self?.queue.async { self?.onError(error) }
    }
    latestResult = nil
  }
}

final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
  enum State: Equatable {
    case idle
    case starting
    case recording
    case stopping
  }

  private let rootURL: URL
  private let sampleQueue = DispatchQueue(label: "aven.meeting.audio", qos: .userInitiated)
  private let stateLock = NSLock()
  private var stateValue = State.idle
  private var writer: MeetingTranscriptStore?
  private var stream: SCStream?
  private var systemTranscriber: LiveMeetingTranscriber?
  private var microphoneTranscriber: LiveMeetingTranscriber?
  private var rotationTimer: DispatchSourceTimer?
  private var microphoneSuppressed = false
  private var stopWasRequested = false
  private var operationGeneration = 0

  var onUnexpectedStop: ((MeetingRecorderError) -> Void)?
  var onTranscriptionWarning: ((MeetingRecorderError) -> Void)?

  init(rootURL: URL = AssistantPaths.workspaceURL.appendingPathComponent("meetings")) {
    self.rootURL = rootURL
    super.init()
  }

  var state: State { stateLock.withMeetingLock { stateValue } }
  var isRecording: Bool { state == .recording }
  var transcriptURL: URL? { stateLock.withMeetingLock { writer?.transcriptURL } }
  var startedAt: Date? { stateLock.withMeetingLock { writer?.startedAt } }

  func start(completion: @escaping (Result<URL, MeetingRecorderError>) -> Void) {
    let generation = stateLock.withMeetingLock { () -> Int? in
      guard stateValue == .idle else { return nil }
      stateValue = .starting
      stopWasRequested = false
      operationGeneration += 1
      return operationGeneration
    }
    guard let generation else {
      completion(.failure(.alreadyActive))
      return
    }
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) {
      [weak self] content, error in
      guard let self else { return }
      self.sampleQueue.async {
        guard self.isStarting(generation) else { return }
        if let error {
          self.failStart(.capture(error.localizedDescription), generation: generation, completion: completion)
          return
        }
        guard let displays = content?.displays, !displays.isEmpty else {
          self.failStart(.noDisplay, generation: generation, completion: completion)
          return
        }
        let display = displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays[0]
        self.configureAndStart(display: display, generation: generation, completion: completion)
      }
    }
  }

  func stop(completion: @escaping (URL?) -> Void = { _ in }) {
    let currentStream = stateLock.withMeetingLock { () -> (accepted: Bool, stream: SCStream?)? in
      guard stateValue == .recording || stateValue == .starting else { return nil }
      stateValue = .stopping
      stopWasRequested = true
      operationGeneration += 1
      return (true, stream)
    }
    guard let currentStream else {
      DispatchQueue.main.async { completion(nil) }
      return
    }
    sampleQueue.async { [weak self] in
      guard let self else { return }
      self.finishTranscription {
        guard let stream = currentStream.stream else {
          self.finish(status: "completed") { result in
            DispatchQueue.main.async { completion(result.successValue) }
          }
          return
        }
        stream.stopCapture { error in
          self.sampleQueue.async {
            let status = error == nil ? "completed" : "failed"
            self.finish(status: status) { result in
              if let error {
                self.onUnexpectedStop?(.capture(error.localizedDescription))
              }
              if case .failure(let storageError) = result {
                self.onTranscriptionWarning?(storageError)
              }
              DispatchQueue.main.async { completion(result.successValue) }
            }
          }
        }
      }
    }
  }

  func stopImmediately() {
    let currentStream = stateLock.withMeetingLock { () -> SCStream? in
      guard stateValue != .idle else { return nil }
      stateValue = .stopping
      stopWasRequested = true
      operationGeneration += 1
      return stream
    }
    sampleQueue.sync {
      finishTranscriptionImmediately()
      currentStream?.stopCapture(completionHandler: nil)
      finishImmediately(status: "completed")
    }
  }

  func setQuestionCaptureActive(_ active: Bool) {
    stateLock.withMeetingLock { microphoneSuppressed = active }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    switch outputType {
    case .audio:
      systemTranscriber?.append(sampleBuffer)
    case .microphone:
      guard !stateLock.withMeetingLock({ microphoneSuppressed }) else { return }
      microphoneTranscriber?.append(sampleBuffer)
    case .screen:
      return
    @unknown default:
      return
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    sampleQueue.async { [weak self] in
      guard let self else { return }
      let requested = self.stateLock.withMeetingLock { self.stopWasRequested }
      guard !requested else { return }
      self.finishTranscription {
        self.finish(status: "failed") { result in
          if case .failure(let storageError) = result {
            self.onTranscriptionWarning?(storageError)
          }
          self.onUnexpectedStop?(.capture(error.localizedDescription))
        }
      }
    }
  }

  private func configureAndStart(
    display: SCDisplay,
    generation: Int,
    completion: @escaping (Result<URL, MeetingRecorderError>) -> Void
  ) {
    let writer: MeetingTranscriptStore
    do {
      writer = try MeetingTranscriptStore(rootURL: rootURL)
    } catch let error as MeetingRecorderError {
      failStart(error, generation: generation, completion: completion)
      return
    } catch {
      failStart(.storage(error.localizedDescription), generation: generation, completion: completion)
      return
    }
    guard isStarting(generation) else {
      writer.finish(status: "cancelled")
      return
    }
    let locale = SystemSpeechLanguage.currentLocale
    guard let systemTranscriber = LiveMeetingTranscriber(
      source: "system",
      locale: locale,
      queue: sampleQueue,
      writer: writer,
      onError: { [weak self] error in self?.onTranscriptionWarning?(error) }
    ) else {
      writer.finish(status: "failed")
      failStart(.onDeviceSpeechUnavailable, generation: generation, completion: completion)
      return
    }
    let microphoneTranscriber: LiveMeetingTranscriber?
    if #available(macOS 15.0, *) {
      microphoneTranscriber = LiveMeetingTranscriber(
        source: "microphone",
        locale: locale,
        queue: sampleQueue,
        writer: writer,
        onError: { [weak self] error in self?.onTranscriptionWarning?(error) }
      )
    } else {
      microphoneTranscriber = nil
    }
    let filter = SCContentFilter(
      display: display,
      excludingApplications: [],
      exceptingWindows: []
    )
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 1
    configuration.showsCursor = false
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = 48_000
    configuration.channelCount = 1
    if #available(macOS 15.0, *) {
      configuration.captureMicrophone = microphoneTranscriber != nil
    }
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    do {
      try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
      if #available(macOS 15.0, *), microphoneTranscriber != nil {
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
      }
    } catch {
      writer.finish(status: "failed")
      failStart(.capture(error.localizedDescription), generation: generation, completion: completion)
      return
    }
    guard isStarting(generation) else {
      writer.finish(status: "cancelled")
      return
    }
    stateLock.withMeetingLock {
      self.writer = writer
      self.stream = stream
      self.systemTranscriber = systemTranscriber
      self.microphoneTranscriber = microphoneTranscriber
    }
    systemTranscriber.start()
    microphoneTranscriber?.start()
    stream.startCapture { [weak self] error in
      guard let self else { return }
      self.sampleQueue.async {
        guard self.isStarting(generation) else {
          stream.stopCapture(completionHandler: nil)
          let isStillOwned = self.stateLock.withMeetingLock { self.writer === writer }
          if !isStillOwned {
            writer.finishAsync(status: "cancelled") { _ in }
          }
          return
        }
        if let error {
          self.finishTranscriptionImmediately()
          self.finish(status: "failed") { result in
            if case .failure(let storageError) = result {
              self.onTranscriptionWarning?(storageError)
            }
            DispatchQueue.main.async {
              completion(.failure(.capture(error.localizedDescription)))
            }
          }
          return
        }
        guard self.stateLock.withMeetingLock({
          guard self.stateValue == .starting, self.operationGeneration == generation else { return false }
          self.stateValue = .recording
          return true
        }) else { return }
        self.startRotationTimer()
        DispatchQueue.main.async { completion(.success(writer.transcriptURL)) }
      }
    }
  }

  private func startRotationTimer() {
    let timer = DispatchSource.makeTimerSource(queue: sampleQueue)
    timer.schedule(deadline: .now() + 30, repeating: 30)
    timer.setEventHandler { [weak self] in
      self?.systemTranscriber?.rotate()
      self?.microphoneTranscriber?.rotate()
    }
    rotationTimer = timer
    timer.resume()
  }

  private func finishTranscription(completion: @escaping () -> Void) {
    rotationTimer?.cancel()
    rotationTimer = nil
    let transcribers = [systemTranscriber, microphoneTranscriber].compactMap { $0 }
    guard !transcribers.isEmpty else {
      completion()
      return
    }
    var remaining = transcribers.count
    for transcriber in transcribers {
      transcriber.stop {
        remaining -= 1
        if remaining == 0 { completion() }
      }
    }
  }

  private func finishTranscriptionImmediately() {
    rotationTimer?.cancel()
    rotationTimer = nil
    systemTranscriber?.stopImmediately()
    microphoneTranscriber?.stopImmediately()
  }

  private func finish(
    status: String,
    completion: @escaping (Result<URL?, MeetingRecorderError>) -> Void
  ) {
    let snapshot = stateLock.withMeetingLock { () -> (MeetingTranscriptStore?, URL?) in
      let writer = self.writer
      let url = writer?.transcriptURL
      self.writer = nil
      self.stream = nil
      self.systemTranscriber = nil
      self.microphoneTranscriber = nil
      self.stateValue = .idle
      self.stopWasRequested = false
      self.microphoneSuppressed = false
      return (writer, url)
    }
    guard let writer = snapshot.0 else {
      completion(.success(snapshot.1))
      return
    }
    writer.finishAsync(status: status) { result in
      completion(result.map { snapshot.1 })
    }
  }

  private func finishImmediately(status: String) {
    let snapshot = stateLock.withMeetingLock { () -> MeetingTranscriptStore? in
      let writer = self.writer
      self.writer = nil
      self.stream = nil
      self.systemTranscriber = nil
      self.microphoneTranscriber = nil
      self.stateValue = .idle
      self.stopWasRequested = false
      self.microphoneSuppressed = false
      return writer
    }
    snapshot?.finish(status: status)
  }

  private func failStart(
    _ error: MeetingRecorderError,
    generation: Int,
    completion: @escaping (Result<URL, MeetingRecorderError>) -> Void
  ) {
    let shouldReport = stateLock.withMeetingLock { () -> Bool in
      guard stateValue == .starting, operationGeneration == generation else { return false }
      stateValue = .idle
      stream = nil
      systemTranscriber = nil
      microphoneTranscriber = nil
      return true
    }
    guard shouldReport else { return }
    DispatchQueue.main.async { completion(.failure(error)) }
  }

  private func isStarting(_ generation: Int) -> Bool {
    stateLock.withMeetingLock { stateValue == .starting && operationGeneration == generation }
  }
}

private extension Result where Success == URL?, Failure == MeetingRecorderError {
  var successValue: URL? {
    guard case .success(let value) = self else { return nil }
    return value
  }
}

private extension Date {
  var epochMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1_000).rounded()) }
}

private extension ISO8601DateFormatter {
  static let meetingIdentifier: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()
}

private extension JSONEncoder {
  static var meeting: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

private extension NSLock {
  func withMeetingLock<T>(_ operation: () -> T) -> T {
    lock()
    defer { unlock() }
    return operation()
  }
}
