BEGIN;

CREATE ROLE attendance_bot WITH LOGIN PASSWORD 'strong-password-here';
GRANT CONNECT ON DATABASE postgres TO attendance_bot;
GRANT USAGE ON SCHEMA public TO attendance_bot;

-- rad-only reference data
GRANT SELECT ON session_types, ignored_identities TO attendance_bot;

-- self healing cache: reads, learns new bindings, refreshes confirmations
GRANT SELECT, UPDATE, INSERT ON learner_identity_map TO attendance_bot;

-- pipelne write surface
GRANT SELECT, INSERT, UPDATE ON 
    meeting_sessions,
    meeting_conferences,
    meeting_attendance_raw,
    meeting_attendance,
    unmatched_participants
TO attendance_bot;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO attendance_bot;

-- Deliberately absent: DELETE (pipeline never deletes), any DDL,
-- attendance_overrides (human-only via Retool; pipeline must never touch it),
-- and the reporting views (Retool reads those under its own role).

ROLLBACK; -- change to COMMIT once the password is set and the bot is ready to go