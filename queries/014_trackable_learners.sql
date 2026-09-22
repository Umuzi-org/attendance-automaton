BEGIN;

-- Trackable = actively learning, OR under Launch Lab support.
-- Deliberately NOT named v_enrolled_learners: it returns non-enrolled people.
-- Denylist rather than allowlist on launch_lab_status: six of the eight
-- statuses are unused today and will populate as Launch Lab matures. New
-- statuses should be tracked by default; only explicit end-of-support excludes.
CREATE OR REPLACE VIEW v_trackable_learners AS
WITH latest_change AS (
    SELECT DISTINCT ON (lscl.lpp_id)
        lscl.lpp_id, lscl.new_learner_status_id, lscl.changed_at
    FROM learner_status_change_log lscl
    ORDER BY lscl.lpp_id, lscl.changed_at DESC
)
SELECT
    lpp.learner_id,
    l.first_name || ' ' || l.last_name AS learner_name,
    COALESCE(l.umuzi_email, l.email)   AS learner_email,
    p.id        AS programme_id,
    p.name      AS cohort_name,
    lsl.status  AS current_status,
    llsl.status AS launch_lab_status,
    lc.changed_at AS status_since
FROM learners_programmes_pathways lpp
JOIN programmes p ON p.id = lpp.programmes_id
JOIN learners   l ON l.id = lpp.learner_id
LEFT JOIN latest_change lc ON lc.lpp_id = lpp.id
JOIN learner_status_lookup lsl
    ON lsl.id = COALESCE(lc.new_learner_status_id, lpp.learner_status_id)
LEFT JOIN launch_lab_status_lookup llsl
    ON llsl.id = lpp.launch_lab_status_id
WHERE lsl.status = 'Enrolled'
   OR (llsl.status IS NOT NULL
       AND llsl.status NOT IN ('Support revoked', 'Opted out of support'));

GRANT SELECT ON v_trackable_learners TO attendance_bot;
-- plus the Retool role, matching whatever v_enrolled_learners has

COMMIT;