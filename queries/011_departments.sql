-- ============================================================================
-- Migration 011: departments dimension + planned_sessions.department_key
-- ============================================================================
-- Multi-organiser expansion. departments drives the setup-form selector and
-- becomes the reporting dimension. planned_sessions rows are stamped with the
-- department whose account organised the event.
--
-- Rollout note: department_key ships with DEFAULT 'technical' so the live form
-- (which does not yet send the column) keeps inserting. After the Phase D form
-- deploy, run the post-deploy step at the bottom to drop the default, making
-- all future writes explicit.
-- ============================================================================

BEGIN;

CREATE TABLE departments (
    key            TEXT PRIMARY KEY,          -- 'technical', 'experience_labs', ...
    account_email  TEXT NOT NULL UNIQUE,      -- the organising Workspace account
    display_name   TEXT NOT NULL,             -- selector label
    sort_order     INTEGER NOT NULL DEFAULT 100,
    is_active      BOOLEAN NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO departments (key, account_email, display_name, sort_order) VALUES
    ('technical',       'technical@umuzi.org',       'Technical',       10),
    ('experience_labs', 'experience.labs@umuzi.org', 'Experience Labs', 20),
    ('launch_labs',     'launch.labs@umuzi.org',     'Launch Labs',     30);

ALTER TABLE planned_sessions
    ADD COLUMN department_key TEXT NOT NULL
        REFERENCES departments(key);

-- Existing rows were all created as technical@ by mandate; the default has
-- already stamped them correctly on ADD COLUMN.

-- Reporting: replace the view (never layer) to carry the new dimension.
-- New columns appended at the end, as CREATE OR REPLACE requires.
CREATE OR REPLACE VIEW v_planned_vs_actual AS
SELECT
    p.calendar_event_id,
    p.session_type_code,
    st.display_name                              AS session_type,
    p.scheduled_start,
    p.created_by,
    p.planned_attendee_count,
    s.actual_start,
    s.actual_duration_minutes,
    s.conference_count,
    (s.calendar_event_id IS NOT NULL
        AND s.conference_count > 0)              AS did_run,
    count(a.*) FILTER (WHERE a.invited)          AS invited_count,
    count(a.*) FILTER (WHERE a.attended)         AS attended_count,
    p.department_key,
    d.display_name                               AS department_name
FROM planned_sessions          AS p
LEFT JOIN meeting_sessions     AS s  ON s.calendar_event_id = p.calendar_event_id
LEFT JOIN session_types        AS st ON st.code = p.session_type_code
LEFT JOIN departments          AS d  ON d.key  = p.department_key
LEFT JOIN meeting_attendance   AS a  ON a.calendar_event_id = p.calendar_event_id
GROUP BY
    p.calendar_event_id, p.session_type_code, st.display_name,
    p.scheduled_start, p.created_by, p.planned_attendee_count,
    s.calendar_event_id, s.actual_start, s.actual_duration_minutes,
    s.conference_count, p.department_key, d.display_name;

-- Grants: mirror the conventions in 010_bot_permissions.sql. The dimension is
-- read-only reference data for everything except migrations.
-- GRANT SELECT ON departments TO <retool_role>;
-- GRANT SELECT ON departments TO <readonly_reporting_role>;

COMMIT;