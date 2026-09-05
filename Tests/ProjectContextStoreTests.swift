import Foundation

@main
enum ProjectContextStoreTests {
  static func main() {
    migratesTheExistingConversationIntoGeneralContext()
    keepsIndependentProjectThreads()
    expiresOnlyTheProjectMapping()
    expiresAnInactiveActiveProjectBackToGeneral()
    rejectsInvalidModelSelectedKeys()
    print("Project context tests passed")
  }

  private static func migratesTheExistingConversationIntoGeneralContext() {
    withDefaults { defaults in
      let thread = UUID().uuidString
      defaults.set(thread, forKey: ProjectContextStore.legacyThreadKey)
      let store = ProjectContextStore(defaults: defaults, now: Date(timeIntervalSince1970: 100))

      expect(store.threadID() == thread, "legacy conversation should become the general context")
      expect(defaults.string(forKey: ProjectContextStore.legacyThreadKey) == nil, "legacy key should be retired")
    }
  }

  private static func keepsIndependentProjectThreads() {
    withDefaults { defaults in
      let store = ProjectContextStore(defaults: defaults)
      let general = UUID().uuidString
      let project = UUID().uuidString
      store.remember(threadID: general, for: store.select("general"))
      let projectKey = store.select("new:aven")
      store.remember(threadID: project, for: projectKey)

      expect(store.threadID() == project, "active project should use its own conversation")
      expect(store.select("general") == "general", "general context should remain selectable")
      expect(store.threadID() == general, "switching context should restore its conversation")
      expect(Set(store.allThreadIDs()) == Set([general, project]), "both owned contexts should remain known")
    }
  }

  private static func expiresOnlyTheProjectMapping() {
    withDefaults { defaults in
      let old = Date(timeIntervalSince1970: 1_000)
      let store = ProjectContextStore(defaults: defaults, now: old)
      let project = store.select("new:temporary", now: old)
      store.remember(threadID: UUID().uuidString, for: project, now: old)
      _ = store.select("general", now: old)

      let later = old.addingTimeInterval(ProjectContextStore.ttl + 1)
      let reloaded = ProjectContextStore(defaults: defaults, now: later)

      expect(!reloaded.hint().availableKeys.contains("temporary"), "stale project mapping should expire")
      expect(reloaded.hint().availableKeys.contains("general"), "general context should remain")
    }
  }

  private static func rejectsInvalidModelSelectedKeys() {
    withDefaults { defaults in
      let store = ProjectContextStore(defaults: defaults)
      expect(store.select("unannounced-project") == "general", "unknown contexts require an explicit new marker")
      expect(store.select("new:../../secret") == "general", "unsafe context keys should be ignored")
      expect(store.select(String(repeating: "a", count: 65)) == "general", "oversized context keys should be ignored")
    }
  }

  private static func expiresAnInactiveActiveProjectBackToGeneral() {
    withDefaults { defaults in
      let old = Date(timeIntervalSince1970: 1_000)
      let store = ProjectContextStore(defaults: defaults, now: old)
      let project = store.select("new:forgotten", now: old)
      store.remember(threadID: UUID().uuidString, for: project, now: old)

      let reloaded = ProjectContextStore(
        defaults: defaults,
        now: old.addingTimeInterval(ProjectContextStore.ttl + 1)
      )

      expect(reloaded.hint().activeKey == "general", "an expired active project should return to general")
      expect(!reloaded.hint().availableKeys.contains("forgotten"), "opening the app must not refresh an unused project")
    }
  }

  private static func withDefaults(_ operation: (UserDefaults) -> Void) {
    let name = "aven-project-context-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    operation(defaults)
  }

  private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("FAILED: \(message)\n".utf8))
      exit(1)
    }
  }
}
