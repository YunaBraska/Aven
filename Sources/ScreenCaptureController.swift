import AppKit
import CoreGraphics
import Foundation

enum ScreenCaptureError: LocalizedError {
  case permissionDenied
  case displayUnavailable
  case captureFailed

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      "Bildschirmaufnahme ist nicht erlaubt."
    case .displayUnavailable:
      "Der aktive Bildschirm wurde nicht gefunden."
    case .captureFailed:
      "Der Bildschirm konnte nicht aufgenommen werden."
    }
  }
}

@MainActor
final class ScreenCaptureController {
  private let captureDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("com.yunabraska.aven/screenshots", isDirectory: true)

  init() {
    removeStaleCaptures()
  }

  func captureActiveDisplay(
    completion: @escaping (Result<URL, ScreenCaptureError>) -> Void
  ) {
    guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
      completion(.failure(.permissionDenied))
      return
    }
    guard let displayID = activeDisplayID() else {
      completion(.failure(.displayUnavailable))
      return
    }

    let output = captureDirectory.appendingPathComponent("current-\(UUID().uuidString).png")
    do {
      try FileManager.default.createDirectory(
        at: captureDirectory,
        withIntermediateDirectories: true
      )
    } catch {
      completion(.failure(.captureFailed))
      return
    }

    DispatchQueue.global(qos: .userInitiated).async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-D", String(displayID), output.path]
      do {
        try process.run()
        process.waitUntilExit()
        let succeeded =
          process.terminationStatus == 0
          && FileManager.default.fileExists(atPath: output.path)
        if succeeded {
          try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: output.path
          )
        } else {
          try? FileManager.default.removeItem(at: output)
        }
        DispatchQueue.main.async {
          completion(succeeded ? .success(output) : .failure(.captureFailed))
        }
      } catch {
        DispatchQueue.main.async { completion(.failure(.captureFailed)) }
      }
    }
  }

  func remove(_ screenshot: URL) {
    guard screenshot.deletingLastPathComponent() == captureDirectory else { return }
    try? FileManager.default.removeItem(at: screenshot)
  }

  private func activeDisplayID() -> CGDirectDisplayID? {
    let pointer = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) }
      ?? NSScreen.main
      ?? NSScreen.screens.first
    return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
  }

  private func removeStaleCaptures() {
    try? FileManager.default.createDirectory(
      at: captureDirectory,
      withIntermediateDirectories: true
    )
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: captureDirectory.path
    )
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: captureDirectory,
        includingPropertiesForKeys: nil
      )
    else {
      return
    }
    for file in files where file.lastPathComponent.hasPrefix("current-") {
      try? FileManager.default.removeItem(at: file)
    }
  }
}
