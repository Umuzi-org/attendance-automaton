CREATE OR REPLACE VIEW v_enrolled_learners AS
WITH latest_change AS (
    -- newest status-change row per pathway (changes-only log)
    SELECT DISTINCT ON (lscl.lpp_id)
        lscl.lpp_id,
        lscl.new_learner_status_id,
        lscl.changed_at
    FROM learner_status_change_log lscl
    ORDER BY lscl.lpp_id, lscl.changed_at DESC
)
SELECT
    lpp.learner_id,
    l.first_name || ' ' || l.last_name AS learner_name,
    COALESCE(l.umuzi_email, l.email) AS learner_email,
    p.id   AS programme_id,
    p.name AS cohort_name,
    lsl.status AS current_status,
    lc.changed_at AS status_since   -- NULL = never changed since enrolment
FROM learners_programmes_pathways lpp
JOIN programmes p ON p.id = lpp.programmes_id
JOIN learners   l ON l.id = lpp.learner_id
LEFT JOIN latest_change lc ON lc.lpp_id = lpp.id
JOIN learner_status_lookup lsl
    ON lsl.id = COALESCE(lc.new_learner_status_id, lpp.learner_status_id) -- latest change if any, else initial status
WHERE lsl.status = 'Enrolled';


-- log is changes-only (5,887 untouched pathways as of Jul 2026); LPP status is authoritative for never-changed row