-- Seed prod identity map from currently enrolled learners (v_enrolled_learners, 008).
-- Policy: umuzi_email is the canonical joining identity. Personal email is seeded
-- ONLY when no umuzi_email exists (e.g. SAP / BeGreen sponsored pathways).
-- learners.email is known-messy (stale/duplicate addresses), so it is deliberately
-- excluded for learners who have a umuzi account.

WITH enrolled AS (
    SELECT DISTINCT learner_id FROM v_enrolled_learners
),
emails AS (
    SELECT l.id AS learner_id, lower(l.umuzi_email) AS email
    FROM learners l JOIN enrolled e ON e.learner_id = l.id
    WHERE l.umuzi_email IS NOT NULL
    UNION
    SELECT l.id, lower(l.email)
    FROM learners l JOIN enrolled e ON e.learner_id = l.id
    WHERE l.email IS NOT NULL AND l.umuzi_email IS NULL -- personal email ONLY as fallback
)
INSERT INTO learner_identity_map (email, learner_id, match_method, confidence)
SELECT DISTINCT ON (email) email, learner_id, 'email_exact', 1.000
FROM emails
ORDER BY email, learner_id
ON CONFLICT (email) DO NOTHING;