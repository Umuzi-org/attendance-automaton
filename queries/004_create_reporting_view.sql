-- ============================================================================
-- Migration 004: Reporting view v_meeting_attendance
-- ============================================================================
-- A denormalized read surface for IDC reporting and the Retool dashboard, so
-- consumers query one view instead of joining four tables. Kept thin: the
-- clean fact table already holds most of what's needed; this layers on the
-- human-readable session type and session title.
-- ============================================================================

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
    att.service_name
FROM attendance AS att
JOIN meeting_sessions AS s  ON s.calendar_event_id = att.calendar_event_id
LEFT JOIN session_types AS st ON st.code = att.session_type_code;
