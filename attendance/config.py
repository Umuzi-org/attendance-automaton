"""Central configuration and tunable constants for the attendance pipeline."""

from datetime import timezone, timedelta

# OAuth scopes for the read-only pipeline credential (the technical@ account).
SCOPES = [
    "https://www.googleapis.com/auth/calendar.events.readonly",
    "https://www.googleapis.com/auth/meetings.space.readonly",
    "https://www.googleapis.com/auth/directory.readonly",
]

# Calendar holding the tracked sessions. 'primary' = the technical@ account's
# own calendar.
CALENDAR_ID = "primary"


SAST = timezone(timedelta(hours=2))

# MVP scope: only participants on this domain resolve to learners. Anyone else
# flows to the review queue (the V2 external-learner case).
ORG_DOMAIN = "umuzi.org"

# A conference record counts as a real session only with at least this many
# distinct participants. Drops link-poppers and accidental joins; keeps
# legitimate 1:1s (coach + learner = 2). Tunable after the one-month review.
MIN_PARTICIPANTS_FOR_REAL_CONFERENCE = 2

# Attendance rule. attended = participant_seconds / denominator_seconds >= THRESHOLD.
ATTENDANCE_THRESHOLD = 0.5

# Denominator floor: the denominator is never less than this, guarding against
# degenerate short conferences. Note: sessions genuinely shorter than 30 min
# become hard to "attend" — watch this against real 1:1 durations and adjust.
DENOMINATOR_FLOOR_SECONDS = 30 * 60