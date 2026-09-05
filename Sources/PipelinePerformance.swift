import Foundation

enum PipelineStage: String, CaseIterable {
  case transcription
  case routing
  case response
  case speech
  case compaction

  var title: String {
    switch self {
    case .transcription: "Transcribe"
    case .routing: "Route"
    case .response: "Codex"
    case .speech: "Speak"
    case .compaction: "Compact"
    }
  }
}

struct PipelineTimingSnapshot: Equatable {
  let durations: [PipelineStage: TimeInterval]

  func label(for stage: PipelineStage) -> String {
    guard let duration = durations[stage] else { return "\(stage.title) —" }
    return "\(stage.title) \(Self.duration(duration))"
  }

  private static func duration(_ value: TimeInterval) -> String {
    if value < 1 { return String(format: "%.0f ms", value * 1_000) }
    return String(format: "%.1f s", value)
  }
}

@MainActor
final class PipelinePerformanceTracker {
  private var starts: [PipelineStage: Date] = [:]
  private var durations: [PipelineStage: TimeInterval] = [:]

  var snapshot: PipelineTimingSnapshot { PipelineTimingSnapshot(durations: durations) }

  func begin(_ stage: PipelineStage, at date: Date = Date()) {
    starts[stage] = date
  }

  func finish(_ stage: PipelineStage, at date: Date = Date()) {
    guard let start = starts.removeValue(forKey: stage) else { return }
    durations[stage] = max(0, date.timeIntervalSince(start))
  }

  func cancel(_ stage: PipelineStage) {
    starts.removeValue(forKey: stage)
  }

  func cancelAll() {
    starts.removeAll()
  }
}
