-- ============================================================================
-- Migration 001: Meet Attendance Tracking — Schema
-- ============================================================================
-- Grain model:  session (calendar event) -> conference(s) -> participant sessions
-- All timestamps are stored as timestamptz (UTC under the hood).
-- EAT is a fixed UTC+3 with no DST, so date_service_accessed is computed in the
-- pipeline as (actual_start + 3 hours)::date.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. session_types  (lookup / dimension)
--    Codes parsed from the calendar title convention, e.g. "[SME] ...".
-- ----------------------------------------------------------------------------
CREATE TABLE session_types (
    code          TEXT PRIMARY KEY,                 -- 'SME', 'LXCI', 'TH', ...
    display_name  TEXT NOT NULL,
    description   TEXT,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 2. learner_identity_map  (bridge: Google identity / email -> learner_id)
--    Seeded from the learner master with email + learner_id (google_user_id
--    NULL). The pipeline backfills google_user_id the first time a learner
--    appears in a Meet, then matches on it thereafter (self-healing).
--    Surrogate PK because google_user_id is NULL at seed time.
-- ----------------------------------------------------------------------------
CREATE TABLE learner_identity_map (
    id              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    google_user_id  TEXT,                            -- signedinUser.user: "users/{id}"
    email           TEXT,                            -- lowercased + trimmed before insert
    learner_id      TEXT NOT NULL,                   -- FK to your canonical learner table
    match_method    TEXT NOT NULL                    -- how this mapping was established
        CHECK (match_method IN ('email_exact','user_id_exact','manual','name_fuzzy')),
    confidence      NUMERIC(4,3),                    -- optional, for fuzzy matches
    first_seen      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_confirmed  TIMESTAMPTZ,
    -- NULLs are distinct in Postgres UNIQUE, so seeded rows (NULL user_id) coexist:
    CONSTRAINT uq_identity_google_user_id UNIQUE (google_user_id),
    CONSTRAINT uq_identity_email          UNIQUE (email)
);

-- Optional hard FK to your existing learner master — uncomment and adjust if it
-- lives in this same database:
-- ALTER TABLE learner_identity_map
--     ADD CONSTRAINT fk_identity_learner
--     FOREIGN KEY (learner_id) REFERENCES learners(learner_id);

-- ----------------------------------------------------------------------------
-- 3. meeting_sessions  (grain = calendar event = the business "session")
--    One row per tracked calendar event, whether or not it actually ran.
--    conference_count = 0 means scheduled-but-never-ran (all invitees absent).
-- ----------------------------------------------------------------------------
CREATE TABLE meeting_sessions (
    calendar_event_id        TEXT PRIMARY KEY,
    session_type_code        TEXT REFERENCES session_types(code),
    session_title_raw        TEXT NOT NULL,          -- original title, for debugging
    meet_space_code          TEXT,
    organizer_email          TEXT,
    scheduled_start          TIMESTAMPTZ,
    scheduled_end            TIMESTAMPTZ,
    actual_start             TIMESTAMPTZ,            -- earliest conference start
    actual_end               TIMESTAMPTZ,            -- latest conference end
    actual_duration_minutes  INTEGER,               -- summed active conference time
    denominator_minutes      INTEGER,               -- max(actual_duration_minutes, 30)
    conference_count         INTEGER NOT NULL DEFAULT 0,
    date_service_accessed    DATE,                  -- (actual_start + 3h)::date, set by pipeline
    service_name             TEXT,                  -- DEFERRED (Phase 2), nullable
    invited_count            INTEGER,
    ingested_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 4. meeting_conferences  (grain = conference record; child of a session)
--    Multiple rows per session only in the restart case; usually one.
-- ----------------------------------------------------------------------------
CREATE TABLE meeting_conferences (
    conference_record_id  TEXT PRIMARY KEY,          -- "conferenceRecords/{id}"
    calendar_event_id     TEXT NOT NULL
        REFERENCES meeting_sessions(calendar_event_id) ON DELETE CASCADE,
    meet_space_code       TEXT,
    conference_start      TIMESTAMPTZ,
    conference_end        TIMESTAMPTZ,
    duration_minutes      INTEGER,
    ingested_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 5. meeting_attendance_raw  (grain = participant session; immutable log)
--    One row per join->leave. A drop-and-rejoin produces multiple rows.
--    participant_email is usually NULL at ingest (the Meet API does not return
--    it); it is resolved downstream via the People API.
-- ----------------------------------------------------------------------------
CREATE TABLE meeting_attendance_raw (
    participant_session_id    TEXT PRIMARY KEY,       -- from Meet API
    conference_record_id      TEXT NOT NULL
        REFERENCES meeting_conferences(conference_record_id) ON DELETE CASCADE,
    calendar_event_id         TEXT NOT NULL
        REFERENCES meeting_sessions(calendar_event_id) ON DELETE CASCADE,
    participant_type          TEXT NOT NULL
        CHECK (participant_type IN ('signed_in','anonymous','phone')),
    google_user_id            TEXT,                   -- NULL for anonymous/phone
    participant_display_name  TEXT,
    participant_email         TEXT,                   -- resolved later, if at all
    session_start             TIMESTAMPTZ NOT NULL,
    session_end               TIMESTAMPTZ,
    session_duration_seconds  INTEGER,
    ingested_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- 6. meeting_attendance  (grain = invited learner x session; the clean fact)
--    The table IDC reporting and Retool query. One row per matched learner per
--    session. Unmatched attendees live in unmatched_participants until resolved,
--    so learner_id is NOT NULL here.
--      invited  : was on the calendar invite list
--      present  : joined at all
--      attended : present for >= 50% of denominator_minutes
-- ----------------------------------------------------------------------------
CREATE TABLE meeting_attendance (
    id                     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    calendar_event_id      TEXT NOT NULL
        REFERENCES meeting_sessions(calendar_event_id) ON DELETE CASCADE,
    learner_id             TEXT NOT NULL,
    participant_email      TEXT,
    session_type_code      TEXT,                      -- denormalized for query convenience
    date_service_accessed  DATE,                      -- denormalized
    invited                BOOLEAN NOT NULL,
    present                BOOLEAN NOT NULL,
    attended               BOOLEAN NOT NULL,
    participant_minutes    INTEGER NOT NULL DEFAULT 0,
    denominator_minutes    INTEGER,
    attendance_pct         NUMERIC(5,4),              -- participant_minutes / denominator_minutes
    service_name           TEXT,                      -- DEFERRED (Phase 2)
    computed_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_attendance UNIQUE (calendar_event_id, learner_id)
);

-- ----------------------------------------------------------------------------
-- 7. unmatched_participants  (review queue)
--    Attendees that could not be resolved to a learner_id. For the MVP (everyone
--    on an Umuzi account) this should stay near-empty.
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

-- Dedupe re-queuing on reruns. COALESCE handles anonymous joins (NULL user_id)
-- by falling back to display name within the same session.
CREATE UNIQUE INDEX uq_unmatched_event_identity
    ON unmatched_participants (
        calendar_event_id,
        COALESCE(google_user_id, participant_display_name)
    );

-- ----------------------------------------------------------------------------
-- Indexes for the common read patterns (IDC reporting, dashboard, review queue)
-- ----------------------------------------------------------------------------
-- meeting_attendance: the heavily-queried fact table
CREATE INDEX ix_attendance_date        ON meeting_attendance (date_service_accessed);
CREATE INDEX ix_attendance_type        ON meeting_attendance (session_type_code);
CREATE INDEX ix_attendance_learner     ON meeting_attendance (learner_id);

-- meeting_sessions
CREATE INDEX ix_sessions_date          ON meeting_sessions (date_service_accessed);
CREATE INDEX ix_sessions_type          ON meeting_sessions (session_type_code);

-- meeting_conferences / raw: rollup joins
CREATE INDEX ix_conferences_event      ON meeting_conferences (calendar_event_id);
CREATE INDEX ix_raw_conference         ON meeting_attendance_raw (conference_record_id);
CREATE INDEX ix_raw_event              ON meeting_attendance_raw (calendar_event_id);
CREATE INDEX ix_raw_user               ON meeting_attendance_raw (google_user_id);

-- identity + review queue
CREATE INDEX ix_identity_learner       ON learner_identity_map (learner_id);
CREATE INDEX ix_unmatched_status       ON unmatched_participants (status);

COMMIT;
