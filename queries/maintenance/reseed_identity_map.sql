-- ============================================================================
-- Maintenance (NOT a migration): reseed learner_identity_map from enrolment.
-- ============================================================================
-- Migration 009 seeded the map once. Enrolment is continuous, so the map goes
-- stale: as of 2026-08-18, 201 enrolled learners had no identity row at all,
-- which meant the review queue could not suggest them and coaches were offered
-- 14%-similarity strangers instead.
--
-- This file is the SELECT from 009, re-runnable. Called at the start of every
-- pipeline run (attendance.orchestration.cli). Safe to run by hand any time.
--
-- Policy unchanged from 009: umuzi_email is the canonical joining identity.
-- Personal email is seeded ONLY when no umuzi_email exists (SAP / BeGreen
-- sponsored pathways). learners.email is known-messy for learners who have a
-- umuzi account, so it stays excluded for them; those cases resolve through
-- the review queue, which writes a 'manual' binding.
--
-- ON CONFLICT (email) DO NOTHING makes this idempotent: existing rows are
-- never overwritten, so pipeline-written name_invite_match rows and
-- reviewer-written manual rows are preserved.
-- ============================================================================

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
    WHERE l.email IS NOT NULL AND l.umuzi_email IS NULL  -- personal only as fallback
)
INSERT INTO learner_identity_map (email, learner_id, match_method, confidence)
SELECT DISTINCT ON (email) email, learner_id, 'email_exact', 1.000
FROM emails
ORDER BY email, learner_id
ON CONFLICT (email) DO NOTHING;