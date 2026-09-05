PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS memory_records (
  id INTEGER PRIMARY KEY,
  subject TEXT NOT NULL DEFAULT '',
  category TEXT NOT NULL,
  content TEXT NOT NULL,
  locator TEXT NOT NULL DEFAULT '',
  metadata_json TEXT NOT NULL DEFAULT '{}',
  epistemic_state TEXT NOT NULL,
  lifecycle TEXT NOT NULL DEFAULT 'active' CHECK (
    lifecycle IN ('active', 'completed', 'discarded', 'superseded', 'retracted', 'archived')
  ),
  confidence REAL NOT NULL DEFAULT 1.0 CHECK (confidence >= 0.0 AND confidence <= 1.0),
  evidence_count INTEGER NOT NULL DEFAULT 1 CHECK (evidence_count >= 1),
  source TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at TEXT,
  expires_at TEXT,
  supersedes_id INTEGER REFERENCES memory_records(id),
  CHECK (length(trim(category)) > 0),
  CHECK (length(trim(content)) > 0),
  CHECK (json_valid(metadata_json))
);

CREATE INDEX IF NOT EXISTS memory_records_lookup
  ON memory_records(subject, category, lifecycle);

CREATE INDEX IF NOT EXISTS memory_records_retention
  ON memory_records(lifecycle, expires_at);

CREATE VIRTUAL TABLE IF NOT EXISTS memory_records_fts USING fts5(
  subject,
  category,
  content,
  locator,
  content = 'memory_records',
  content_rowid = 'id'
);

CREATE TRIGGER IF NOT EXISTS memory_records_fts_insert AFTER INSERT ON memory_records BEGIN
  INSERT INTO memory_records_fts(rowid, subject, category, content, locator)
  VALUES(new.id, new.subject, new.category, new.content, new.locator);
END;

CREATE TRIGGER IF NOT EXISTS memory_records_fts_delete AFTER DELETE ON memory_records BEGIN
  INSERT INTO memory_records_fts(memory_records_fts, rowid, subject, category, content, locator)
  VALUES('delete', old.id, old.subject, old.category, old.content, old.locator);
END;

CREATE TRIGGER IF NOT EXISTS memory_records_fts_update AFTER UPDATE ON memory_records BEGIN
  INSERT INTO memory_records_fts(memory_records_fts, rowid, subject, category, content, locator)
  VALUES('delete', old.id, old.subject, old.category, old.content, old.locator);
  INSERT INTO memory_records_fts(rowid, subject, category, content, locator)
  VALUES(new.id, new.subject, new.category, new.content, new.locator);
END;

INSERT INTO memory_records_fts(memory_records_fts) VALUES('rebuild');

CREATE TABLE IF NOT EXISTS memory_links (
  source_record_id INTEGER NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
  relation TEXT NOT NULL,
  target_record_id INTEGER NOT NULL REFERENCES memory_records(id) ON DELETE CASCADE,
  source TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  valid_to TEXT,
  PRIMARY KEY(source_record_id, relation, target_record_id),
  CHECK (source_record_id <> target_record_id),
  CHECK (length(trim(relation)) > 0)
);

CREATE TABLE IF NOT EXISTS style_signals (
  dimension TEXT PRIMARY KEY,
  preference TEXT NOT NULL,
  confidence REAL NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
  evidence_count INTEGER NOT NULL CHECK (evidence_count >= 1),
  explicit INTEGER NOT NULL DEFAULT 0 CHECK (explicit IN (0, 1)),
  source TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'superseded', 'retracted'))
);

CREATE TABLE IF NOT EXISTS assistant_identity (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  display_name TEXT,
  self_description TEXT NOT NULL DEFAULT '',
  maturity REAL NOT NULL DEFAULT 0.0 CHECK (maturity >= 0.0 AND maturity <= 1.0),
  source TEXT NOT NULL DEFAULT 'unformed',
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO assistant_identity(singleton) VALUES(1);

CREATE TABLE IF NOT EXISTS assistant_traits (
  id INTEGER PRIMARY KEY,
  dimension TEXT NOT NULL,
  expression TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 0.5 CHECK (confidence >= 0.0 AND confidence <= 1.0),
  evidence_count INTEGER NOT NULL DEFAULT 1 CHECK (evidence_count >= 1),
  source TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'superseded', 'retracted')),
  supersedes_id INTEGER REFERENCES assistant_traits(id),
  CHECK (length(trim(dimension)) > 0),
  CHECK (length(trim(expression)) > 0)
);

CREATE UNIQUE INDEX IF NOT EXISTS assistant_traits_active
  ON assistant_traits(dimension) WHERE status = 'active';

CREATE TABLE IF NOT EXISTS preference_rules (
  id INTEGER PRIMARY KEY,
  scope TEXT NOT NULL,
  scope_key TEXT NOT NULL DEFAULT '',
  subject TEXT NOT NULL,
  rule TEXT NOT NULL,
  confidence REAL NOT NULL DEFAULT 1.0 CHECK (confidence >= 0.0 AND confidence <= 1.0),
  explicit INTEGER NOT NULL DEFAULT 1 CHECK (explicit IN (0, 1)),
  status TEXT NOT NULL DEFAULT 'candidate' CHECK (
    status IN ('candidate', 'active', 'superseded', 'retracted', 'archived')
  ),
  source TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_used_at TEXT,
  expires_at TEXT,
  CHECK (length(trim(scope)) > 0),
  CHECK (length(trim(subject)) > 0),
  CHECK (length(trim(rule)) > 0)
);

CREATE INDEX IF NOT EXISTS preference_rules_lookup
  ON preference_rules(scope, scope_key, subject, status);

CREATE INDEX IF NOT EXISTS preference_rules_retention
  ON preference_rules(status, expires_at);

CREATE TABLE IF NOT EXISTS maintenance_state (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

PRAGMA user_version = 3;
