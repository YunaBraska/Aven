import Foundation

@main
enum CodexFeatureIsolationTests {
  static func main() {
    emitsOnlyFeaturesAdvertisedByTheCurrentCodex()
    ignoresMalformedCatalogRows()
    degradesToNoOptionalArgumentsWhenDiscoveryIsUnavailable()
    sharesOneDiscoveryProbeAcrossConcurrentCacheMisses()
    retriesDiscoveryAfterATransientFailure()
    print("Codex feature isolation tests passed")
  }

  private static func emitsOnlyFeaturesAdvertisedByTheCurrentCodex() {
    let arguments = CodexFeatureIsolation.disableArguments(
      desired: ["plugins", "removed_feature", "apps"],
      featureList: """
        plugins stable true
        apps stable true
        newer_feature under-development false
        """
    )
    expect(
      arguments == ["--disable", "plugins", "--disable", "apps"],
      "only live supported feature names should become arguments"
    )
  }

  private static func ignoresMalformedCatalogRows() {
    let names = CodexFeatureIsolation.featureNames(in: """
      valid_feature stable true
      ../../escape stable true
      --flag stable true
      """)
    expect(names == Set(["valid_feature"]), "feature parsing must reject option and path syntax")
  }

  private static func degradesToNoOptionalArgumentsWhenDiscoveryIsUnavailable() {
    expect(
      CodexFeatureIsolation.disableArguments(desired: ["plugins"], featureList: "").isEmpty,
      "missing optional feature discovery must not invent incompatible arguments"
    )
  }

  private static func sharesOneDiscoveryProbeAcrossConcurrentCacheMisses() {
    let fixture = try! FeatureFixture(script: """
      #!/bin/sh
      printf x >> \"$PROBE_LOG\"
      /bin/sleep 0.2
      printf '%s\\n' 'plugins stable true'
      """)
    defer { fixture.remove() }
    CodexFeatureIsolation.invalidate(executableURL: fixture.executableURL)

    let group = DispatchGroup()
    let lock = NSLock()
    var results: [[String]] = []
    for _ in 0..<12 {
      group.enter()
      DispatchQueue.global().async {
        let result = CodexFeatureIsolation.disableArguments(
          executableURL: fixture.executableURL,
          environment: fixture.environment,
          workspaceURL: fixture.directoryURL,
          desired: ["plugins"]
        )
        lock.lock()
        results.append(result)
        lock.unlock()
        group.leave()
      }
    }
    group.wait()

    expect(results == Array(repeating: ["--disable", "plugins"], count: 12), "all callers need the discovered feature")
    expect(fixture.probeCount == 1, "concurrent cache misses must use one feature probe")
  }

  private static func retriesDiscoveryAfterATransientFailure() {
    let fixture = try! FeatureFixture(script: """
      #!/bin/sh
      if [ ! -f \"$PROBE_STATE\" ]; then
        : > \"$PROBE_STATE\"
        exit 1
      fi
      printf '%s\\n' 'plugins stable true'
      """)
    defer { fixture.remove() }
    CodexFeatureIsolation.invalidate(executableURL: fixture.executableURL)

    let first = CodexFeatureIsolation.disableArguments(
      executableURL: fixture.executableURL,
      environment: fixture.environment,
      workspaceURL: fixture.directoryURL,
      desired: ["plugins"]
    )
    Thread.sleep(forTimeInterval: 1.1)
    let second = CodexFeatureIsolation.disableArguments(
      executableURL: fixture.executableURL,
      environment: fixture.environment,
      workspaceURL: fixture.directoryURL,
      desired: ["plugins"]
    )

    expect(first.isEmpty, "a failed feature probe must not produce arguments")
    expect(second == ["--disable", "plugins"], "a transient feature probe failure must retry soon")
  }

  private final class FeatureFixture: @unchecked Sendable {
    let directoryURL: URL
    let executableURL: URL
    let environment: [String: String]
    private let logURL: URL

    init(script: String) throws {
      directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      executableURL = directoryURL.appendingPathComponent("codex")
      logURL = directoryURL.appendingPathComponent("probes")
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      try script.write(to: executableURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
      environment = [
        "PATH": "/usr/bin:/bin",
        "PROBE_LOG": logURL.path,
        "PROBE_STATE": directoryURL.appendingPathComponent("state").path,
      ]
    }

    var probeCount: Int {
      (try? String(contentsOf: logURL, encoding: .utf8).count) ?? 0
    }

    func remove() {
      try? FileManager.default.removeItem(at: directoryURL)
    }
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
      exit(1)
    }
  }
}
