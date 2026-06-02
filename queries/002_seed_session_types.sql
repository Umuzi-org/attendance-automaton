-- ============================================================================
-- Migration 002: Seed session_types  (v2: + sort_order)
-- ============================================================================
-- These codes are what the calendar-title parser extracts from "[CODE] Title"
-- AND what populates the Retool setup-form dropdown (ordered by sort_order,
-- filtered to is_active = TRUE). Keep codes SHORT and UPPERCASE.
-- Idempotent: safe to re-run.
-- ============================================================================

INSERT INTO session_types (code, display_name, description, sort_order) VALUES
    ('SME',  'Subject Matter Expert', 'Facilitator-led teaching session', 10),
    ('LXCI', 'LX Check-In',           'Learner Experience coach check-in', 20),
    ('TH',   'Townhall',              'All-hands / cohort townhall',       30),
    ('GIG',  'Gig Management',        'Gig management session',            40)

ON CONFLICT (code) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        description  = EXCLUDED.description,
        sort_order   = EXCLUDED.sort_order,
        is_active    = TRUE;
