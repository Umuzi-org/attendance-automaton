-- ============================================================================
-- Migration 003: Seed learner_identity_map from the learner master
-- ============================================================================
-- This is a TEMPLATE. The pipeline will backfill
-- google_user_id lazily the first time each learner appears in a Meet, so we
-- seed only email + learner_id here, with match_method = 'email_exact'.
--
-- Notes:
--   - We lowercase + trim emails to match how the resolver normalizes them.
--   - One learner with multiple emails -> multiple rows, same learner_id (fine).
--   - ON CONFLICT (umuzi_email) keeps the seed idempotent and re-runnable.
-- ============================================================================

INSERT INTO learner_identity_map (email, learner_id, match_method)
SELECT DISTINCT ON (lower(trim(lm.umuzi_email)))
    lower(trim(lm.umuzi_email)) AS email,
    lm.id                 AS learner_id,
    'email_exact'               AS match_method
FROM learners AS lm
WHERE lm.umuzi_email IS NOT NULL
  AND trim(lm.umuzi_email) <> ''
ORDER BY lower(trim(lm.umuzi_email)), lm.id   -- tie-break: keep lowest id
ON CONFLICT (email) DO UPDATE
    SET learner_id     = EXCLUDED.learner_id,
        last_confirmed = now();

-- Sanity check after seeding:
--   SELECT count(*) AS seeded, count(google_user_id) AS resolved
--   FROM learner_identity_map;
-- 'resolved' will start at 0 and climb as the pipeline runs.
