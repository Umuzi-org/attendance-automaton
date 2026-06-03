-- ============================================================================
-- Migration 006: Identity resolution support
--   - ignored_identities: service accounts / staff to skip during resolution
--   - extend learner_identity_map.match_method with 'name_invite_match'
--   - seed the known recording/service account
-- Additive and idempotent; safe to apply on top of 001-005.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- ignored_identities
--   Participants that should never be resolved to a learner or queued for
--   review: the recording bot, facilitators, staff who attend sessions, etc.
--   Match by google_user_id (most reliable) and/or email. A row needs at least
--   one of the two. Manage by INSERT/UPDATE here (and, later, from Retool).
--   Plain UNIQUE on the nullable keys: Postgres treats multiple NULLs as
--   distinct, so email-only and user-id-only rows coexist (same pattern as
--   learner_identity_map).
-- ----------------------------------------------------------------------------
CREATE TABLE ignored_identities (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    google_user_id  TEXT,
    email           TEXT,                       -- store lowercased
    display_name    TEXT,                       -- human note: who this is
    reason          TEXT NOT NULL
        CHECK (reason IN ('service_account', 'staff', 'facilitator', 'other')),
    note            TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ignored_identity_has_key
        CHECK (google_user_id IS NOT NULL OR email IS NOT NULL),
    CONSTRAINT uq_ignored_google_user_id UNIQUE (google_user_id),
    CONSTRAINT uq_ignored_email          UNIQUE (email)
);

CREATE INDEX ix_ignored_active ON ignored_identities (is_active);

-- ----------------------------------------------------------------------------
-- Allow the new resolution provenance value on the identity map. The inline
-- CHECK from migration 001 is auto-named <table>_<column>_check.
-- ----------------------------------------------------------------------------
ALTER TABLE learner_identity_map
    DROP CONSTRAINT IF EXISTS learner_identity_map_match_method_check;

ALTER TABLE learner_identity_map
    ADD CONSTRAINT learner_identity_map_match_method_check
    CHECK (match_method IN (
        'email_exact', 'user_id_exact', 'manual', 'name_fuzzy', 'name_invite_match'
    ));

-- ----------------------------------------------------------------------------
-- Seed the known recording/service account so it never reaches review. This is
-- "Umuzi Technical" / "Technical Session Recording", present in every
-- technical@-organized session.
-- ----------------------------------------------------------------------------
INSERT INTO ignored_identities (google_user_id, email, display_name, reason, note)
VALUES (
    'users/106020620461378904250',
    'technical@umuzi.org',
    'Umuzi Technical / Technical Session Recording',
    'service_account',
    'Organizer/recording bot present in every technical@ session'
)
ON CONFLICT (google_user_id) DO NOTHING;

COMMIT;
