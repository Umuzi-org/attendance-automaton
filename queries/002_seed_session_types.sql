-- ============================================================================
-- Migration 002: Seed session_types
-- ============================================================================
-- These codes are what the calendar-title parser extracts from "[CODE] Title".
-- Confirmed three below; add the remaining Umuzi session types before go-live.
-- Keep codes SHORT and UPPERCASE so the regex ^\[([A-Z]+)\] stays trivial.
-- Idempotent: safe to re-run.
-- ============================================================================

INSERT INTO session_types (code, display_name, description) VALUES
    ('SME',  'Subject Matter Expert', 'Facilitator-led teaching session'),
    ('LXCI', 'LX Check-In',           'Learner Experience coach check-in'),
    ('TH',   'Townhall',              'All-hands / cohort townhall')
    -- Add the rest of your active types here, e.g.:
    -- , ('WS',  'Workshop',         'Hands-on workshop')
    -- , ('DEMO','Demo Day',         'Project demos')
    -- , ('1-1', 'One-on-One',       'Individual coaching')
ON CONFLICT (code) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        description  = EXCLUDED.description,
        is_active    = TRUE;
