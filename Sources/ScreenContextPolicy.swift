import Foundation

enum ScreenContextPolicy {
  static func shouldCapture(for transcript: String) -> Bool {
    let normalized = transcript.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: .current
    )
    let explicitReferences = [
      "auf meinem bildschirm", "auf dem bildschirm", "meinen bildschirm",
      "dieser bildschirm", "dieses fenster", "aktuelles fenster", "screenshot",
      "was siehst du", "siehst du das", "on my screen", "the screen",
      "this screen", "this window", "current window", "what do you see",
      "can you see this", "look at my screen",
    ]
    return explicitReferences.contains(where: normalized.contains)
  }
}
