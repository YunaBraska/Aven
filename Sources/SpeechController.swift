import AVFoundation
import Foundation
import Speech

enum SpeechControllerError: LocalizedError {
  case microphoneDenied
  case recognitionDenied
  case recognizerUnavailable
  case recordingFailed(String)
  case noSpeech

  var errorDescription: String? {
    switch self {
    case .microphoneDenied:
      "Microphone access is required."
    case .recognitionDenied:
      "Speech recognition access is required."
    case .recognizerUnavailable:
      "Speech recognition is currently unavailable."
    case .recordingFailed(let message):
      "Recording failed: \(message)"
    case .noSpeech:
      "No speech detected."
    }
  }

  var isSilent: Bool {
    switch self {
    case .noSpeech, .recordingFailed:
      true
    case .microphoneDenied, .recognitionDenied, .recognizerUnavailable:
      false
    }
  }
}

final class SpeechController {
  private let audioEngine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var latestTranscript = ""
  private var completion: ((Result<String, SpeechControllerError>) -> Void)?
  private var generation = 0
  private var wantsRecording = false

  var isRecording: Bool { audioEngine.isRunning }

  func start(
    onPartialTranscript: @escaping (String) -> Void,
    completion: @escaping (Result<String, SpeechControllerError>) -> Void
  ) {
    guard !isRecording else { return }
    cancel()
    generation += 1
    let currentGeneration = generation
    wantsRecording = true
    latestTranscript = ""
    self.completion = completion
    authorize { [weak self] result in
      DispatchQueue.main.async {
        guard let self,
          self.generation == currentGeneration,
          self.wantsRecording
        else {
          return
        }
        switch result {
        case .success:
          self.beginRecording(onPartialTranscript: onPartialTranscript)
        case .failure(let error):
          self.finish(error: error)
        }
      }
    }
  }

  func stop() {
    wantsRecording = false
    guard audioEngine.isRunning else {
      if completion != nil {
        finish(error: .noSpeech)
      }
      return
    }
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    request?.endAudio()
    let currentGeneration = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self, self.generation == currentGeneration else { return }
      self.finish()
    }
  }

  func cancel() {
    generation += 1
    wantsRecording = false
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
    completion = nil
    latestTranscript = ""
  }

  private func authorize(completion: @escaping (Result<Void, SpeechControllerError>) -> Void) {
    func requestSpeech() {
      SFSpeechRecognizer.requestAuthorization { status in
        completion(status == .authorized ? .success(()) : .failure(.recognitionDenied))
      }
    }

    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      requestSpeech()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { allowed in
        allowed ? requestSpeech() : completion(.failure(.microphoneDenied))
      }
    default:
      completion(.failure(.microphoneDenied))
    }
  }

  private func beginRecording(onPartialTranscript: @escaping (String) -> Void) {
    let recognizer = SFSpeechRecognizer(locale: SystemSpeechLanguage.currentLocale)
    guard let recognizer, recognizer.isAvailable else {
      finish(error: .recognizerUnavailable)
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    self.request = request

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      request.append(buffer)
    }

    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      DispatchQueue.main.async {
        guard let self else { return }
        if let result {
          let transcript = result.bestTranscription.formattedString
          self.latestTranscript = transcript
          onPartialTranscript(transcript)
          if result.isFinal {
            self.finish()
          }
        } else if error != nil, !self.latestTranscript.isEmpty {
          self.finish()
        } else if error != nil {
          self.finish(error: .noSpeech)
        }
      }
    }

    do {
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      finish(error: .recordingFailed(error.localizedDescription))
    }
  }

  private func finish(error: SpeechControllerError? = nil) {
    guard let completion else { return }
    generation += 1
    wantsRecording = false
    self.completion = nil
    task?.cancel()
    task = nil
    request = nil
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }

    if let error {
      completion(.failure(error))
      return
    }
    let transcript = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    completion(transcript.isEmpty ? .failure(.noSpeech) : .success(transcript))
  }
}
