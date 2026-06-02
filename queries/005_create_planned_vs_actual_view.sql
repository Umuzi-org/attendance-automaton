-- ============================================================================
-- Migration 005: Reporting view v_planned_vs_actual
-- ============================================================================
-- Enabled by the setup form. Joins INTENT (planned_sessions) against OBSERVED
-- (meeting_sessions + meeting_attendance) so you can see, per planned session,
-- whether it ran, how long, and how attendance compared to what was planned.
-- Sits empty until both the setup form (Phase 5) and the pipeline are live.
-- ============================================================================

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
    count(a.*) FILTER (WHERE a.attended)         AS attended_count
FROM planned_sessions          AS p
LEFT JOIN meeting_sessions     AS s  ON s.calendar_event_id = p.calendar_event_id
LEFT JOIN session_types        AS st ON st.code = p.session_type_code
LEFT JOIN meeting_attendance   AS a  ON a.calendar_event_id = p.calendar_event_id
GROUP BY
    p.calendar_event_id, p.session_type_code, st.display_name,
    p.scheduled_start, p.created_by, p.planned_attendee_count,
    s.calendar_event_id, s.actual_start, s.actual_duration_minutes,
    s.conference_count;
