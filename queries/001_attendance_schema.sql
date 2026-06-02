-- ============================================================================
-- Migration 001: Meet Attendance Tracking — Schema  (v2: + session setup form)
-- ============================================================================
-- Grain model:  session (calendar event) -> conference(s) -> participant sessions
-- planned_sessions (intent, written by the Retool setup form) joins to
-- meeting_sessions (observed, written by the pipeline) on calendar_event_id.
-- All timestamps are timestamptz (UTC). EAT is a fixed UTC+3, no DST, so
-- date_service_accessed is computed as (actual_start + 3 hours)::date.
--
-- NOTE ON MIGRATION DISCIPLINE: if 001 (v1) has already been applied in any
-- environment, do NOT edit-and-rerun this file. Apply the additive changes
-- (planned_sessions table, session_type_source column, sort_order column) as a
-- separate forward migration instead.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. session_types  (lookup / dimension)
--    Codes parsed from titles AND used to populate the setup-form dropdown.
--    sort_order controls dropdown ordering; is_active hides retired types.
-- ----------------------------------------------------------------------------
CREATE TABLE session_types (
    code          TEXT PRIMARY KEY,                 -- 'SME', 'LXCI', 'TH', ...
    display_name  TEXT NOT NULL,
    description   TEXT,
    sort_order    INTEGER NOT NULL DEFAULT 100,      -- form dropdown ordering
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 2. learner_identity_map  (bridge: Google identity / email -> learner_id)
--    Seeded with email + learner_id (google_user_id NULL); pipeline backfills
--    google_user_id on first Meet appearance, then matches on it (self-healing).
--    Surrogate PK because google_user_id is NULL at seed time.
-- ----------------------------------------------------------------------------
CREATE TABLE learner_identity_map (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    google_user_id  TEXT,
    email           TEXT,                            -- lowercased + trimmed before insert
    learner_id      TEXT NOT NULL,
    match_method    TEXT NOT NULL
        CHECK (match_method IN ('email_exact','user_id_exact','manual','name_fuzzy')),
    confidence      NUMERIC(4,3),
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_confirmed  TIMESTAMPTZ,
    CONSTRAINT uq_identity_google_user_id UNIQUE (google_user_id),
    CONSTRAINT uq_identity_email          UNIQUE (email)
);

-- Optional hard FK to your learner master (same DB only):
-- ALTER TABLE learner_identity_map
--     ADD CONSTRAINT fk_identity_learner
--     FOREIGN KEY (learner_id) REFERENCES learners(learner_id);

-- ----------------------------------------------------------------------------
-- 3. planned_sessions  (INTENT — written by the Retool setup form at creation)
--    One row per session set up through the form, keyed on the calendar event id
--    returned by the Calendar API create call. Sits empty until the setup
--    interface (Phase 5) is live. meeting_sessions joins here on
--    calendar_event_id but does NOT require it: events created outside the form
--    simply have no planned row (and resolve their type via title-parse).
-- ----------------------------------------------------------------------------
CREATE TABLE planned_sessions (
    calendar_event_id       TEXT PRIMARY KEY,
    session_type_code       TEXT NOT NULL REFERENCES session_types(code),
    session_title           TEXT,                    -- constructed human-readable title
    scheduled_start         TIMESTAMPTZ NOT NULL,
    scheduled_end           TIMESTAMPTZ,
    meet_space_code         TEXT,                    -- if captured at creation
    planned_attendee_count  INTEGER,
    created_by              TEXT,                    -- form user who set up the session
    service_name            TEXT,                    -- captured at setup if applicable
    source                  TEXT NOT NULL DEFAULT 'retool_form'
        CHECK (source IN ('retool_form','manual','other')),
    created_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 4. meeting_sessions  (OBSERVED — grain = calendar event; written by pipeline)
--    One row per tracked calendar event, whether or not it ran.
--    conference_count = 0 means scheduled-but-never-ran (all invitees absent).
--    session_type_source records HOW the type was determined, which doubles as
--    a form-adoption metric ('form_metadata' vs 'title_parse').
-- ----------------------------------------------------------------------------
CREATE TABLE meeting_sessions (
    calendar_event_id        TEXT PRIMARY KEY,
    session_type_code        TEXT REFERENCES session_types(code),
    session_type_source      TEXT
        CHECK (session_type_source IN ('form_metadata','planned_table','title_parse','unknown')),
    session_title_raw        TEXT NOT NULL,
    meet_space_code          TEXT,
    organizer_email          TEXT,
    scheduled_start          TIMESTAMPTZ,
    scheduled_end            TIMESTAMPTZ,
    actual_start             TIMESTAMPTZ,
    actual_end               TIMESTAMPTZ,
    actual_duration_minutes  INTEGER,
    denominator_minutes      INTEGER,
    conference_count         INTEGER NOT NULL DEFAULT 0,
    date_service_accessed    DATE,
    service_name             TEXT,
    invited_count            INTEGER,
    ingested_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 5. meeting_conferences  (grain = conference record; child of a session)
-- ----------------------------------------------------------------------------
CREATE TABLE meeting_conferences (
    conference_record_id  TEXT PRIMARY KEY,
    calendar_event_id     TEXT NOT NULL
        REFERENCES meeting_sessions(calendar_event_id) ON DELETE CASCADE,
    meet_space_code       TEXT,
    conference_start      TIMESTAMPTZ,
    conference_end        TIMESTAMPTZ,
    duration_minutes      INTEGER,
    ingested_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 6. meeting_attendance_raw  (grain = participant session; immutable log)
-- ----------------------------------------------------------------------------
CREATE TABLE meeting_attendance_raw (
    participant_session_id    TEXT PRIMARY KEY,
    conference_record_id      TEXT NOT NULL
        REFERENCES meeting_conferences(conference_record_id) ON DELETE CASCADE,
    calendar_event_id         TEXT NOT NULL
        REFERENCES meeting_sessions(calendar_event_id) ON DELETE CASCADE,
    participant_type          TEXT NOT NULL
        CHECK (participant_type IN ('signed_in','anonymous','phone')),
    google_user_id            TEXT,
    participant_display_name  TEXT,
    participant_email         TEXT,
    session_start             TIMESTAMPTZ NOT NULL,
    session_end               TIMESTAMPTZ,
    session_duration_seconds  INTEGER,
    ingested_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 7. meeting_attendance  (grain = invited learner x session; the clean fact)
-- ----------------------------------------------------------------------------
CREATE TABLE meeting_attendance (
    id                     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    calendar_event_id      TEXT NOT NULL
        REFERENCES meeting_sessions(calendar_event_id) ON DELETE CASCADE,
    learner_id             TEXT NOT NULL,
    participant_email      TEXT,
    session_type_code      TEXT,
    date_service_accessed  DATE,
    invited                BOOLEAN NOT NULL,
    present                BOOLEAN NOT NULL,
    attended               BOOLEAN NOT NULL,
    participant_minutes    INTEGER NOT NULL DEFAULT 0,
    denominator_minutes    INTEGER,
    attendance_pct         NUMERIC(5,4),
    service_name           TEXT,
    computed_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_attendance UNIQUE (calendar_event_id, learner_id)
);

-- ----------------------------------------------------------------------------
-- 8. unmatched_participants  (review queue)
-- ----------------------------------------------------------------------------
CREATE TABLE unmatched_participants (
    id                        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conference_record_id      TEXT REFERENCES meeting_conferences(conference_record_id),
    calendar_event_id         TEXT REFERENCES meeting_sessions(calendar_event_id),
    participant_type          TEXT,
    google_user_id            TEXT,
    participant_display_name  TEXT,
    participant_email         TEXT,
    participant_minutes       INTEGER,
    status                    TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending','resolved','ignored')),
    resolved_to_learner_id    TEXT,
    reviewed_at               TIMESTAMPTZ,
    reviewed_by               TEXT,
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX uq_unmatched_event_identity
    ON unmatched_participants (
        calendar_event_id,
        COALESCE(google_user_id, participant_display_name)
    );

-- ----------------------------------------------------------------------------
-- Indexes for the common read patterns
-- ----------------------------------------------------------------------------
CREATE INDEX ix_attendance_date        ON meeting_attendance (date_service_accessed);
CREATE INDEX ix_attendance_type        ON meeting_attendance (session_type_code);
CREATE INDEX ix_attendance_learner     ON meeting_attendance (learner_id);

CREATE INDEX ix_sessions_date          ON meeting_sessions (date_service_accessed);
CREATE INDEX ix_sessions_type          ON meeting_sessions (session_type_code);
CREATE INDEX ix_sessions_type_source   ON meeting_sessions (session_type_source);

CREATE INDEX ix_planned_type           ON planned_sessions (session_type_code);
CREATE INDEX ix_planned_start          ON planned_sessions (scheduled_start);
CREATE INDEX ix_planned_created_by     ON planned_sessions (created_by);

CREATE INDEX ix_conferences_event      ON meeting_conferences (calendar_event_id);
CREATE INDEX ix_raw_conference         ON meeting_attendance_raw (conference_record_id);
CREATE INDEX ix_raw_event              ON meeting_attendance_raw (calendar_event_id);
CREATE INDEX ix_raw_user               ON meeting_attendance_raw (google_user_id);

CREATE INDEX ix_identity_learner       ON learner_identity_map (learner_id);
CREATE INDEX ix_unmatched_status       ON unmatched_participants (status);

COMMIT;
