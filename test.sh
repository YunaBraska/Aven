#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_dir=$(/usr/bin/mktemp -d "$project_dir/.test-build.XXXXXX")
test_preferences_root="$test_dir/preferences"
/bin/mkdir -p "$test_preferences_root"
export CFFIXED_USER_HOME="$test_preferences_root"

cleanup() {
    /bin/rm -R "$test_dir"
    preferences_dir="$HOME/Library/Preferences"
    if [ -d "$preferences_dir" ]; then
        /usr/bin/find -E "$preferences_dir" -maxdepth 1 -type f \
            \( -regex '.*/(aven|voice-assistant)-[a-z0-9-]+-[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}[.]plist' \
            -o -regex '.*/assistant-access-profile-[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}[.]plist' \
            -o -regex '.*/AssistantShortcutTests[.][0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}[.]plist' \) \
            -delete
    fi
    diagnostics_dir="$HOME/Library/Logs/DiagnosticReports"
    if [ -d "$diagnostics_dir" ]; then
        /usr/bin/find -E "$diagnostics_dir" -maxdepth 1 -type f \
            -regex '.*/aven-[a-z-]+-tests-[0-9-]+[.]ips' -delete
    fi
}
trap cleanup EXIT HUP INT TERM

if [ ! -x "$project_dir/.venv/bin/python" ]; then
    printf '%s\n' "Missing development environment. Run: python3 -m venv .venv && .venv/bin/python -m pip install -r requirements-dev.txt" >&2
    exit 2
fi
"$project_dir/.venv/bin/python" "$project_dir/scripts/validate_skills.py" \
    "$project_dir/Resources/AssistantTemplate/skills"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/AssistantControlCommand.swift" \
    "$project_dir/Sources/AssistantContextCommand.swift" \
    "$project_dir/Sources/TaskCapabilityBroker.swift" \
    "$project_dir/Sources/AIForwardingConsent.swift" \
    "$project_dir/Sources/PermissionController.swift" \
    "$project_dir/Sources/AssistantAccessProfile.swift" \
    "$project_dir/Sources/AssistantShortcut.swift" \
    "$project_dir/Sources/AssistantState.swift" \
    "$project_dir/Sources/AssistantMetrics.swift" \
    "$project_dir/Sources/CodexProgress.swift" \
    "$project_dir/Sources/CodexEventParser.swift" \
    "$project_dir/Sources/CodexAppServerIsolation.swift" \
    "$project_dir/Sources/CodexFeatureIsolation.swift" \
    "$project_dir/Sources/CodexChatLauncher.swift" \
    "$project_dir/Sources/CredentialVault.swift" \
    "$project_dir/Sources/DiagramEditor.swift" \
    "$project_dir/Sources/GlobalHotKey.swift" \
    "$project_dir/Sources/ModelRouter.swift" \
    "$project_dir/Sources/ProjectContextStore.swift" \
    "$project_dir/Sources/MemoryMaintenance.swift" \
    "$project_dir/Sources/PipelinePerformance.swift" \
    "$project_dir/Sources/RecipeMaintenance.swift" \
    "$project_dir/Sources/ScreenContextPolicy.swift" \
    "$project_dir/Sources/SpeechController.swift" \
    "$project_dir/Sources/SpeechOutput.swift" \
    "$project_dir/Sources/StatusIconAnimator.swift" \
    "$project_dir/Sources/SystemSpeechLanguage.swift" \
    "$project_dir/Tests/BehaviorTests.swift" \
    -o "$test_dir/behavior-tests" \
    -framework AVFoundation \
    -framework Carbon \
    -framework CoreAudio \
    -framework CoreGraphics \
    -framework EventKit \
    -framework AppKit \
    -framework Security \
    -framework Speech
"$test_dir/behavior-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/CodexProgress.swift" \
    "$project_dir/Sources/CodexEventParser.swift" \
    "$project_dir/Sources/CodexExecutableLocator.swift" \
    "$project_dir/Sources/CodexAppServerIsolation.swift" \
    "$project_dir/Sources/CodexFeatureIsolation.swift" \
    "$project_dir/Sources/ModelRouter.swift" \
    "$project_dir/Sources/ProjectContextStore.swift" \
    "$project_dir/Sources/RecentSources.swift" \
    "$project_dir/Sources/AIForwardingConsent.swift" \
    "$project_dir/Sources/SystemSpeechLanguage.swift" \
    "$project_dir/Sources/CredentialVault.swift" \
    "$project_dir/Sources/TaskCapabilityBroker.swift" \
    "$project_dir/Sources/CodexClient.swift" \
    "$project_dir/Tests/CodexClientTests.swift" \
    -o "$test_dir/codex-client-tests" \
    -framework Security
"$test_dir/codex-client-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/CodexExecutableLocator.swift" \
    "$project_dir/Sources/CodexMaintenance.swift" \
    "$project_dir/Tests/CodexMaintenanceTests.swift" \
    -o "$test_dir/codex-maintenance-tests" \
    -framework Security
"$test_dir/codex-maintenance-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/CodexExecutableLocator.swift" \
    "$project_dir/Sources/CodexAppServerIsolation.swift" \
    "$project_dir/Sources/CodexFeatureIsolation.swift" \
    "$project_dir/Sources/CodexAccountMetrics.swift" \
    "$project_dir/Tests/CodexAccountMetricsTests.swift" \
    -o "$test_dir/codex-account-metrics-tests" \
    -framework Security
"$test_dir/codex-account-metrics-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/RecentSources.swift" \
    "$project_dir/Tests/RecentSourcesTests.swift" \
    -o "$test_dir/recent-sources-tests"
"$test_dir/recent-sources-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/CodexAppServerIsolation.swift" \
    "$project_dir/Sources/CodexFeatureIsolation.swift" \
    "$project_dir/Sources/CodexContextMaintenance.swift" \
    "$project_dir/Tests/CodexContextMaintenanceTests.swift" \
    -o "$test_dir/codex-context-maintenance-tests"
"$test_dir/codex-context-maintenance-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/CodexFeatureIsolation.swift" \
    "$project_dir/Tests/CodexFeatureIsolationTests.swift" \
    -o "$test_dir/codex-feature-isolation-tests"
"$test_dir/codex-feature-isolation-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/ProjectContextStore.swift" \
    "$project_dir/Tests/ProjectContextStoreTests.swift" \
    -o "$test_dir/project-context-tests"
"$test_dir/project-context-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/AssistantDataController.swift" \
    "$project_dir/Sources/CredentialVault.swift" \
    "$project_dir/Sources/TaskCapabilityBroker.swift" \
    "$project_dir/Sources/VaultCommand.swift" \
    "$project_dir/Tests/CredentialVaultTests.swift" \
    -o "$test_dir/credential-vault-tests" \
    -framework Security
"$test_dir/credential-vault-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/AssistantDataController.swift" \
    "$project_dir/Sources/CredentialVault.swift" \
    "$project_dir/Sources/TaskCapabilityBroker.swift" \
    "$project_dir/Sources/VaultCommand.swift" \
    "$project_dir/Tests/VaultHelperTests.swift" \
    -o "$test_dir/vault-helper-tests" \
    -framework Security
"$test_dir/vault-helper-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/WorkspaceBootstrap.swift" \
    "$project_dir/Tests/WorkspaceBootstrapTests.swift" \
    -o "$test_dir/workspace-bootstrap-tests"
"$test_dir/workspace-bootstrap-tests" "$project_dir/Resources/AssistantTemplate"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantAccessProfile.swift" \
    "$project_dir/Tests/AssistantAccessProfileTests.swift" \
    -o "$test_dir/assistant-access-profile-tests"
"$test_dir/assistant-access-profile-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantShortcut.swift" \
    "$project_dir/Sources/GlobalHotKey.swift" \
    "$project_dir/Tests/AssistantShortcutTests.swift" \
    -o "$test_dir/assistant-shortcut-tests" \
    -framework AppKit \
    -framework CoreGraphics
"$test_dir/assistant-shortcut-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantState.swift" \
    "$project_dir/Sources/ConversationInputQueue.swift" \
    "$project_dir/Tests/ConversationInputQueueTests.swift" \
    -o "$test_dir/conversation-input-queue-tests"
"$test_dir/conversation-input-queue-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/AssistantState.swift" \
    "$project_dir/Sources/ConversationInputQueue.swift" \
    "$project_dir/Sources/ConversationInputJournal.swift" \
    "$project_dir/Tests/ConversationInputJournalTests.swift" \
    -o "$test_dir/conversation-input-journal-tests"
"$test_dir/conversation-input-journal-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/SingleInstanceLock.swift" \
    "$project_dir/Tests/SingleInstanceLockTests.swift" \
    -o "$test_dir/single-instance-lock-tests"
"$test_dir/single-instance-lock-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/AssistantPaths.swift" \
    "$project_dir/Sources/CodexProgress.swift" \
    "$project_dir/Sources/SystemSpeechLanguage.swift" \
    "$project_dir/Sources/MeetingRecorder.swift" \
    "$project_dir/Tests/MeetingRecorderTests.swift" \
    -o "$test_dir/meeting-recorder-tests" \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework ScreenCaptureKit \
    -framework Speech
"$test_dir/meeting-recorder-tests"

xcrun swiftc \
    -parse-as-library \
    -warnings-as-errors \
    "$project_dir/Sources/StatusFileDrop.swift" \
    "$project_dir/Sources/MenuTextInputView.swift" \
    "$project_dir/Tests/StatusFileDropTests.swift" \
    -o "$test_dir/status-file-drop-tests" \
    -framework AppKit
"$test_dir/status-file-drop-tests"

knowledge_db="$test_dir/knowledge.sqlite3"
/usr/bin/sqlite3 "$knowledge_db" ".read $project_dir/Resources/AssistantTemplate/database/schema.sql"
/usr/bin/sqlite3 "$knowledge_db" "
  INSERT INTO memory_records(subject,category,content,epistemic_state,source)
  VALUES('orbit','constellation','durable','confirmed','test');
  INSERT INTO memory_records(subject,category,content,epistemic_state,source,created_at,expires_at)
  VALUES('discarded path','brainstorming','old thought','tentative','test',datetime('now','-70 days'),datetime('now','-31 days'));
  INSERT INTO memory_records(subject,category,content,epistemic_state,source,expires_at)
  VALUES('open path','brainstorming','current thought','tentative','test',datetime('now','+30 days'));
  INSERT INTO memory_records(subject,category,content,epistemic_state,source,lifecycle,expires_at)
  VALUES('history','fact','old referenced value','superseded','test','archived',datetime('now','-31 days'));
  INSERT INTO memory_records(subject,category,content,epistemic_state,source,supersedes_id)
  VALUES('history','correction','current correction','confirmed','test',4);
  INSERT INTO style_signals(dimension,preference,confidence,evidence_count,explicit,source)
  VALUES('answer length','concise',1.0,1,1,'user correction');
  INSERT INTO preference_rules(scope,scope_key,subject,rule,status,source)
  VALUES('tool','ansible','logging','do not add logs','active','user confirmation');
  INSERT INTO assistant_traits(dimension,expression,confidence,evidence_count,source)
  VALUES('humor','dry and sparing',0.7,3,'assistant development');
  UPDATE assistant_traits SET status='superseded' WHERE dimension='humor' AND status='active';
  INSERT INTO assistant_traits(dimension,expression,confidence,evidence_count,source,supersedes_id)
  VALUES('humor','warm and dry',0.8,4,'assistant development',1);
"
/usr/bin/sqlite3 -bail "$knowledge_db" ".read $project_dir/Resources/AssistantTemplate/database/maintain.sql"
remaining=$(/usr/bin/sqlite3 "$knowledge_db" "SELECT group_concat(content, ',') FROM (SELECT content FROM memory_records ORDER BY id);")
if [ "$remaining" != "durable,current thought,old referenced value,current correction" ]; then
    printf '%s\n' "FAILED: memory maintenance removed the wrong entries: $remaining" >&2
    exit 1
fi
category=$(/usr/bin/sqlite3 "$knowledge_db" "SELECT category FROM memory_records WHERE content = 'durable';")
if [ "$category" != "constellation" ]; then
    printf '%s\n' "FAILED: memory categories must remain open-ended: $category" >&2
    exit 1
fi
name=$(/usr/bin/sqlite3 "$knowledge_db" "SELECT coalesce(display_name, '<unnamed>') FROM assistant_identity WHERE singleton = 1;")
if [ "$name" != "<unnamed>" ]; then
    printf '%s\n' "FAILED: a new assistant must start unnamed: $name" >&2
    exit 1
fi
style=$(/usr/bin/sqlite3 "$knowledge_db" "SELECT preference FROM style_signals WHERE dimension = 'answer length';")
if [ "$style" != "concise" ]; then
    printf '%s\n' "FAILED: explicit style preferences must persist: $style" >&2
    exit 1
fi
matches=$(/usr/bin/sqlite3 "$knowledge_db" "SELECT count(*) FROM memory_records_fts WHERE memory_records_fts MATCH 'orbit';")
if [ "$matches" != "1" ]; then
    printf '%s\n' "FAILED: related memory must be searchable: $matches" >&2
    exit 1
fi
rule=$(/usr/bin/sqlite3 "$knowledge_db" "SELECT rule FROM preference_rules WHERE scope_key = 'ansible';")
if [ "$rule" != "do not add logs" ]; then
    printf '%s\n' "FAILED: contextual preference must persist: $rule" >&2
    exit 1
fi
trait=$(/usr/bin/sqlite3 "$knowledge_db" "SELECT expression FROM assistant_traits WHERE dimension = 'humor' AND status = 'active';")
if [ "$trait" != "warm and dry" ]; then
    printf '%s\n' "FAILED: assistant traits must persist separately: $trait" >&2
    exit 1
fi
version=$(/usr/bin/sqlite3 "$knowledge_db" "PRAGMA user_version;")
if [ "$version" != "3" ]; then
    printf '%s\n' "FAILED: unexpected memory schema version: $version" >&2
    exit 1
fi
printf '%s\n' "Knowledge database tests passed"
