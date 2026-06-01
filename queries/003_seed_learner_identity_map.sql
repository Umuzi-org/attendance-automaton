-- ============================================================================
-- Migration 003: Seed learner_identity_map from the learner master
-- ============================================================================
-- This is a TEMPLATE. Point the SELECT at your actual canonical learner table
-- (the one holding learner_id + email). The pipeline will backfill
-- google_user_id lazily the first time each learner appears in a Meet, so we
-- seed only email + learner_id here, with match_method = 'email_exact'.
--
-- Notes:
--   - We lowercase + trim emails to match how the resolver normalizes them.
--   - One learner with multiple emails -> multiple rows, same learner_id (fine).
--   - ON CONFLICT (email) keeps the seed idempotent and re-runnable.
-- ============================================================================

INSERT INTO learner_identity_map (email, learner_id, match_method)
SELECT
    lower(trim(lm.email))      AS email,
    lm.learner_id              AS learner_id,
    'email_exact'              AS match_method
FROM your_learner_master AS lm     -- <-- REPLACE with your real table/view
WHERE lm.email IS NOT NULL
  AND trim(lm.email) <> ''
ON CONFLICT (email) DO UPDATE
    SET learner_id     = EXCLUDED.learner_id,
        last_confirmed = now();

-- Sanity check after seeding:
--   SELECT count(*) AS seeded, count(google_user_id) AS resolved
--   FROM learner_identity_map;
-- 'resolved' will start at 0 and climb as the pipeline runs.
