"""Apply the attendance rule to one participant's aggregated time.

This module is intentionally tiny and pure: no I/O, no API calls, no clock. It
takes the seconds a participant spent in-call (already summed across conferences
by meet_source) and the session's denominator (already floored by meet_source),
and decides whether that counts as "attended".

Keeping the rule in one pure function means the policy lives in exactly one
place: change ATTENDANCE_THRESHOLD in config and every consumer changes with it,
and the function is trivially unit-testable without mocking Google.

Definitions, restated so an inheritor doesn't have to reverse-engineer them:
  participant_seconds : total in-call time for one person, summed across all
                        kept conferences of the session (rejoins included).
  denominator_seconds : max(actual session duration, DENOMINATOR_FLOOR_SECONDS).
                        Already floored upstream; 0 means the session never ran.
  attended            : present for >= ATTENDANCE_THRESHOLD of the denominator.
"""

from dataclasses import dataclass

from attendance.config import ATTENDANCE_THRESHOLD

@dataclass
class AttendanceResult:
    present: bool            # joined at all (any time > 0)
    attended: bool           # met the threshold
    attendance_pct: float    # participant_seconds / denominator_seconds, 0.0..1.0+
    participant_minutes: int  # rounded, for human-facing storage/reporting


def evaluate_attendance(participant_seconds: int, denominator_seconds: int) -> AttendanceResult:
    """Decide attendance for one participant in one session.

    A denominator of 0 (session never ran, or no kept conferences) yields a
    not-present, not-attended result with 0% -- division is guarded rather than
    allowed to raise, because "no session" is a normal state, not an error.
    """
    present = participant_seconds > 0

    if denominator_seconds <= 0:
        return AttendanceResult(
            present=present,
            attended=False,
            attendance_pct=0.0,
            participant_minutes=round(participant_seconds / 60),
        )

    pct = min(1.0, participant_seconds / denominator_seconds)
    return AttendanceResult(
        present=present,
        attended=pct >= ATTENDANCE_THRESHOLD,
        attendance_pct=pct,
        participant_minutes=round(participant_seconds / 60),
    )