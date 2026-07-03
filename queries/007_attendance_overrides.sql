CREATE TABLE attendance_overrides (
    calendar_event_id  TEXT NOT NULL REFERENCES meeting_sessions(calendar_event_id),
    learner_id         INTEGER NOT NULL REFERENCES learners(id),
    override_type      TEXT NOT NULL
        CHECK (override_type IN ('excused', 'present', 'absent')), -- three types of overrides
    reason             TEXT,
    created_by         TEXT NOT NULL,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by         TEXT,
    updated_at         TIMESTAMPTZ,
    PRIMARY KEY (calendar_event_id, learner_id) -- only one override per learner per session
);


-- Update the current meeting attendance view to accommodate overrides. 
-- This view will now show the override type if it exists, otherwise it will show the original attendance status.

CREATE OR REPLACE VIEW v_meeting_attendance AS
SELECT
    ma.calendar_event_id,
    ma.learner_id,
    ma.participant_email,
    ma.session_type_code,
    ma.date_service_accessed,
    ma.invited,
    ma.present,
    ma.attended,                                   -- raw bot verdict, untouched
    ma.participant_minutes,
    ma.denominator_minutes,
    ma.attendance_pct,
    o.override_type,
    o.reason           AS override_reason,
    o.created_by       AS override_by,
    -- the number reporting should use:
    CASE
        WHEN o.override_type IN ('excused', 'present') THEN true
        WHEN o.override_type = 'absent'                THEN false
        ELSE ma.attended
    END AS effective_attended,
    ma.computed_at,
    ma.computed_at AT TIME ZONE 'Africa/Johannesburg' AS computed_at_sast
FROM meeting_attendance ma
LEFT JOIN attendance_overrides o
    ON  o.calendar_event_id = ma.calendar_event_id
    AND o.learner_id        = ma.learner_id;