-- ============================================================================
-- Migration 015: learner_google_accounts
-- ============================================================================
-- WHY. learner_identity_map is keyed on email, and email identifies a PERSON
-- while google_user_id identifies an ACCOUNT. One row per email with a single
-- google_user_id slot means a learner can only hold as many Google accounts as
-- they have email addresses on file. Today that works for 104 learners (those
-- with both a personal and an @umuzi.org address) and silently fails for
-- everyone else: the second account either collides on the email key or evicts
-- the first binding.
--
-- This table makes google_user_id the durable identity key, as V2 Invariant 4
-- always said it was. Many accounts per learner, no email required.
--
-- WHAT STAYS. learner_identity_map keeps its real job -- email to learner, for
-- invite-scoped name matching (identity._lookup_by_email) and the reseed. Its
-- google_user_id column is NOT dropped here: it is renamed in a follow-up
-- migration once a nightly run has proved clean, so anything still reading it
-- fails loudly rather than quietly returning NULL. Same reasoning as the
-- observability gate.
--
-- ORDER. This migration is additive and breaks nothing on its own. Apply it,
-- then repoint the four readers (identity._lookup_by_user_id,
-- identity._cache_user_id, Retool resolveBatch/ignoreBatch,
-- persist._resolve_stale_unmatched), then verify one green run, then rename.
-- ============================================================================

BEGIN;

CREATE TABLE IF NOT EXISTS learner_google_accounts (
    -- 'users/1234...' straight from the Meet API. The natural key: an account
    -- appears exactly once. Deliberately NO uniqueness on learner_id -- many
    -- accounts per learner is the entire point of this table.
    google_user_id  TEXT PRIMARY KEY,

    learner_id      INTEGER NOT NULL
        REFERENCES learners(id) ON DELETE CASCADE,

    -- The address this account was matched THROUGH, not the account's own
    -- address: Meet never discloses that. Audit context only -- it feeds
    -- IdentityResolution.matched_email and ends up in
    -- meeting_attendance.participant_email. Nullable because an account bound
    -- by a reviewer may have no email evidence at all.
    matched_email   TEXT,

    -- Same vocabulary as learner_identity_map on purpose: one set of words for
    -- a reader to learn. Adding a value means adding it in BOTH places.
    match_method    TEXT NOT NULL
        CHECK (match_method IN ('email_exact', 'user_id_exact', 'manual',
                                'name_fuzzy', 'name_invite_match')),

    -- Nullable to match the source column. Tighten to NOT NULL only after
    -- confirming no bound row in learner_identity_map has a NULL confidence.
    confidence      NUMERIC(4,3),

    first_seen      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_confirmed  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS ix_accounts_learner
    ON learner_google_accounts (learner_id);


-- ----------------------------------------------------------------------------
-- Backfill. Every bound row in the map becomes an account row, unchanged.
-- Expect 803 rows across 699 learners as of 2026-11-10.
-- ON CONFLICT DO NOTHING makes this re-runnable and makes it safe to apply
-- after the pipeline has already started writing here.
-- ----------------------------------------------------------------------------
INSERT INTO learner_google_accounts
    (google_user_id, learner_id, matched_email, match_method,
     confidence, first_seen, last_confirmed)
SELECT m.google_user_id, m.learner_id, m.email, m.match_method,
       m.confidence, m.first_seen, m.last_confirmed
FROM learner_identity_map AS m
WHERE m.google_user_id IS NOT NULL
ON CONFLICT (google_user_id) DO NOTHING;


-- ----------------------------------------------------------------------------
-- Grants. The pipeline reads the cache and writes new bindings, exactly as it
-- does against learner_identity_map. No DELETE, by the same rule as 010.
-- NOTE: Retool reads under its own role, which is not managed in this repo --
-- grant SELECT/INSERT/UPDATE there separately or resolveBatch will fail.
-- ----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON learner_google_accounts TO attendance_bot;

COMMIT;


-- ============================================================================
-- Verification (run after COMMIT; all three should hold)
-- ============================================================================
-- 1. Row counts match the source.
--      SELECT count(*) AS accounts, count(DISTINCT learner_id) AS learners
--      FROM learner_google_accounts;          -- expect 803 / 699
--
-- 2. Nothing bound was left behind.
--      SELECT count(*) FROM learner_identity_map AS m
--      WHERE m.google_user_id IS NOT NULL
--        AND NOT EXISTS (SELECT 1 FROM learner_google_accounts AS a
--                        WHERE a.google_user_id = m.google_user_id
--                          AND a.learner_id     = m.learner_id);   -- expect 0
--
-- 3. The capability this table exists for: learners holding several accounts.
--      SELECT count(*) FROM (
--          SELECT learner_id FROM learner_google_accounts
--          GROUP BY learner_id HAVING count(*) > 1) AS multi;      -- expect 104
-- ============================================================================