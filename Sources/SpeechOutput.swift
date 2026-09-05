import AppKit
import CoreAudio
import Foundation

@MainActor
final class SpeechOutput: NSObject {
  private enum Kind {
    case status
    case answer
  }

  private struct Utterance {
    let text: String
    let kind: Kind
  }

  private let engineFactory: () -> any SpeechEngine
  private let outputRouteObserver: any SpeechOutputRouteObserving
  private var synthesizer: (any SpeechEngine)?
  private var active: Utterance?
  private var pending: [Utterance] = []
  var onStart: (() -> Void)?
  var onFinish: (() -> Void)?
  var canPause: Bool { active != nil }

  override convenience init() {
    self.init(
      engineFactory: { SystemSpeechEngine() },
      outputRouteObserver: SystemDefaultOutputRouteObserver()
    )
  }

  init(
    engineFactory: @escaping () -> any SpeechEngine,
    outputRouteObserver: any SpeechOutputRouteObserving
  ) {
    self.engineFactory = engineFactory
    self.outputRouteObserver = outputRouteObserver
    super.init()
    outputRouteObserver.observe { [weak self] in self?.restartActiveUtteranceForCurrentOutputRoute() }
  }

  func speak(_ text: String) {
    enqueue(text, kind: .answer)
  }

  func speakStatus(_ text: String) {
    let cleaned = SpokenText.clean(text)
    guard !cleaned.isEmpty, active?.kind != .answer,
      !pending.contains(where: { $0.kind == .answer }),
      active?.text != cleaned,
      pending.last?.text != cleaned
    else {
      return
    }
    pending.append(Utterance(text: cleaned, kind: .status))
    startNextIfNeeded()
  }

  func stop() {
    active = nil
    pending.removeAll()
    synthesizer?.stop()
    synthesizer = nil
  }

  func stopStatus() {
    pending.removeAll { $0.kind == .status }
    guard active?.kind == .status else { return }
    active = nil
    synthesizer?.stop()
    synthesizer = nil
    startNextIfNeeded()
  }

  func togglePause() -> Bool? {
    guard active != nil else { return nil }
    guard let synthesizer else { return nil }
    if synthesizer.isPaused {
      synthesizer.resume()
      return false
    }
    synthesizer.pause()
    return true
  }

  private func enqueue(_ text: String, kind: Kind) {
    let cleaned = SpokenText.clean(text)
    guard !cleaned.isEmpty else { return }
    if kind == .answer {
      pending.removeAll { $0.kind == .status }
      if active?.kind == .status {
        active = nil
        synthesizer?.stop()
        synthesizer = nil
      }
    }
    pending.append(Utterance(text: cleaned, kind: kind))
    startNextIfNeeded()
  }

  private func startNextIfNeeded() {
    guard active == nil, !pending.isEmpty else { return }
    let next = pending.removeFirst()
    active = next
    if next.kind == .answer { onStart?() }
    start(next)
  }

  private func start(_ utterance: Utterance) {
    let synthesizer = engineFactory()
    synthesizer.onFinish = { [weak self, weak synthesizer] in
      guard let self, let synthesizer, self.synthesizer === synthesizer else { return }
      self.finishActiveUtterance()
    }
    self.synthesizer = synthesizer
    if !synthesizer.speak(utterance.text) { finishActiveUtterance() }
  }

  private func restartActiveUtteranceForCurrentOutputRoute() {
    guard let active else { return }
    let wasPaused = synthesizer?.isPaused == true
    synthesizer?.stop()
    synthesizer = nil
    start(active)
    if wasPaused { synthesizer?.pause() }
  }

  private func finishActiveUtterance() {
    guard let finished = active else { return }
    active = nil
    synthesizer = nil
    if finished.kind == .answer { onFinish?() }
    startNextIfNeeded()
  }
}

@MainActor
protocol SpeechEngine: AnyObject {
  var isPaused: Bool { get }
  var onFinish: (() -> Void)? { get set }
  func speak(_ text: String) -> Bool
  func stop()
  func pause()
  func resume()
}

@MainActor
private final class SystemSpeechEngine: NSObject, SpeechEngine {
  private typealias StartSpeaking = @convention(c) (AnyObject, Selector, NSString) -> Bool
  private typealias IsSpeaking = @convention(c) (AnyObject, Selector) -> Bool
  private typealias StopSpeaking = @convention(c) (AnyObject, Selector) -> Void
  private typealias PauseSpeaking = @convention(c) (AnyObject, Selector, Int) -> Void
  private typealias ContinueSpeaking = @convention(c) (AnyObject, Selector) -> Void

  private static let startSelector = NSSelectorFromString("startSpeakingString:")
  private static let isSpeakingSelector = NSSelectorFromString("isSpeaking")
  private static let stopSelector = NSSelectorFromString("stopSpeaking")
  private static let pauseSelector = NSSelectorFromString("pauseSpeakingAtBoundary:")
  private static let continueSelector = NSSelectorFromString("continueSpeaking")

  private let engine: NSObject?
  private var ownsActiveSpeech = false
  private(set) var isPaused = false
  var onFinish: (() -> Void)?

  override init() {
    engine = (NSClassFromString("NSSpeechSynthesizer") as? NSObject.Type)?.init()
    super.init()
    engine?.setValue(self, forKey: "delegate")
  }

  func speak(_ text: String) -> Bool {
    guard !text.isEmpty, let engine else { return false }
    isPaused = false
    let implementation = engine.method(for: Self.startSelector)
    let start = unsafeBitCast(implementation, to: StartSpeaking.self)
    ownsActiveSpeech = start(engine, Self.startSelector, text as NSString)
    return ownsActiveSpeech
  }

  func stop() {
    guard let engine else { return }
    isPaused = false
    ownsActiveSpeech = false
    let isSpeaking = unsafeBitCast(engine.method(for: Self.isSpeakingSelector), to: IsSpeaking.self)
    guard isSpeaking(engine, Self.isSpeakingSelector) else { return }
    let stop = unsafeBitCast(engine.method(for: Self.stopSelector), to: StopSpeaking.self)
    stop(engine, Self.stopSelector)
  }

  func pause() {
    guard ownsActiveSpeech, !isPaused, let engine else { return }
    let pause = unsafeBitCast(engine.method(for: Self.pauseSelector), to: PauseSpeaking.self)
    pause(engine, Self.pauseSelector, 0)
    isPaused = true
  }

  func resume() {
    guard ownsActiveSpeech, isPaused, let engine else { return }
    let resume = unsafeBitCast(engine.method(for: Self.continueSelector), to: ContinueSpeaking.self)
    resume(engine, Self.continueSelector)
    isPaused = false
  }

  @objc(speechSynthesizer:didFinishSpeaking:)
  private func didFinishSpeaking(_ sender: AnyObject, finished: Bool) {
    guard ownsActiveSpeech else { return }
    ownsActiveSpeech = false
    isPaused = false
    onFinish?()
  }
}

@MainActor
protocol SpeechOutputRouteObserving: AnyObject {
  func observe(_ onRouteChange: @escaping () -> Void)
}

@MainActor
private final class SystemDefaultOutputRouteObserver: SpeechOutputRouteObserving {
  private var listener: AudioObjectPropertyListenerBlock?
  private var onRouteChange: (() -> Void)?

  func observe(_ onRouteChange: @escaping () -> Void) {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    self.onRouteChange = onRouteChange
    listener = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.onRouteChange?() }
    }
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      .main,
      listener!
    )
  }

  deinit {
    guard let listener else { return }
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    AudioObjectRemovePropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      .main,
      listener
    )
  }
}

enum SpokenText {
  static func clean(_ text: String) -> String {
    text
      .replacingOccurrences(of: "Noxius: ", with: "")
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "`", with: "")
      .replacingOccurrences(of: #"\[([^\]]+)\]\([^\)]+\)"#, with: "$1", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
