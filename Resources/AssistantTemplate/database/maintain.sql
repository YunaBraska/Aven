PRAGMA foreign_keys = ON;

BEGIN IMMEDIATE;

UPDATE memory_records
SET lifecycle = 'archived', updated_at = CURRENT_TIMESTAMP
WHERE lifecycle = 'active'
  AND expires_at IS NOT NULL
  AND datetime(expires_at) <= datetime('now');

DELETE FROM memory_records
WHERE lifecycle IN ('discarded', 'retracted', 'archived')
  AND expires_at IS NOT NULL
  AND datetime(expires_at) <= datetime('now', '-30 days')
  AND NOT EXISTS (
    SELECT 1 FROM memory_records AS successor
    WHERE successor.supersedes_id = memory_records.id
  );

DELETE FROM memory_links
WHERE valid_to IS NOT NULL
  AND datetime(valid_to) <= datetime('now', '-30 days');

UPDATE preference_rules
SET status = 'archived', updated_at = CURRENT_TIMESTAMP
WHERE status = 'candidate'
  AND expires_at IS NOT NULL
  AND datetime(expires_at) <= datetime('now');

DELETE FROM preference_rules
WHERE status IN ('retracted', 'archived')
  AND expires_at IS NOT NULL
  AND datetime(expires_at) <= datetime('now', '-30 days');

INSERT INTO maintenance_state(key, value)
VALUES('last_maintenance', datetime('now'))
ON CONFLICT(key) DO UPDATE SET value = excluded.value;

COMMIT;
