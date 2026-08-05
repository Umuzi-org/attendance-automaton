-- ============================================================================
-- Migration 012: meeting_sessions.department_key
-- ============================================================================
-- Observed sessions become department-aware. The pipeline stamps this column
-- on every upsert from the account whose credential observed the session.
-- Historical rows: all sessions to date were organised by technical@ by
-- mandate, so the backfill is factual.
--
-- Post-deploy step (run only after the first stamped pipeline run is
-- verified in Phase E): SET NOT NULL, so future writes must be explicit.
-- ============================================================================

BEGIN;

ALTER TABLE meeting_sessions
    ADD COLUMN department_key TEXT REFERENCES departments(key);

UPDATE meeting_sessions SET department_key = 'technical'
WHERE department_key IS NULL;

COMMIT;

-- POST-DEPLOY:
-- ALTER TABLE meeting_sessions ALTER COLUMN department_key SET NOT NULL;