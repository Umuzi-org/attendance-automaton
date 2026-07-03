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
WITH attendance AS (
    SELECT
        a.calendar_event_id,
        a.learner_id,
        a.participant_email,
        a.session_type_code,
        a.date_service_accessed,
        a.invited,
        a.present,
        a.attended,
        a.participant_minutes,
        a.denominator_minutes,
        a.attendance_pct,
        a.service_name
    FROM meeting_attendance AS a
)
SELECT
    -- original columns, original order: DO NOT reorder or rename
    att.calendar_event_id,
    att.date_service_accessed,
    att.learner_id,
    att.participant_email,
    att.session_type_code,
    st.display_name        AS session_type,
    s.session_title_raw    AS session_title,
    att.invited,
    att.present,
    att.attended,
    att.participant_minutes,
    att.denominator_minutes,
    att.attendance_pct,
    att.service_name,
    -- appended override columns (new positions only)
    o.override_type,
    o.reason               AS override_reason,
    o.created_by           AS override_by,
    CASE
        WHEN o.override_type IN ('excused', 'present') THEN true
        WHEN o.override_type = 'absent'                THEN false
        ELSE att.attended
    END AS effective_attended
FROM attendance AS att
JOIN meeting_sessions AS s   ON s.calendar_event_id = att.calendar_event_id
LEFT JOIN session_types AS st ON st.code = att.session_type_code
LEFT JOIN attendance_overrides AS o
    ON  o.calendar_event_id = att.calendar_event_id
    AND o.learner_id        = att.learner_id;