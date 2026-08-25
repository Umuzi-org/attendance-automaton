BEGIN;

ALTER TABLE meeting_sessions
    ADD COLUMN invited_learner_count INTEGER NOT NULL DEFAULT 0;

-- Historical rows: reconcile already flagged invited learners per session.
UPDATE meeting_sessions s
SET invited_learner_count = c.n
FROM (
    SELECT calendar_event_id, count(*) AS n
    FROM meeting_attendance
    WHERE invited
    GROUP BY calendar_event_id
) c
WHERE c.calendar_event_id = s.calendar_event_id;

COMMIT;