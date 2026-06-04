"""Reconcile a session's attendees against its invite list.

This is the join that turns "who attended" (from Meet, resolved + evaluated)
and "who was supposed to attend" (the calendar invite list) into the final rows
for two tables:

  - meeting_attendance     : one row per matched learner (invited or not)
  - unmatched_participants : one row per attendee we couldn't resolve

It is a PURE function: no DB, no API, no clock. All resolution (identity),
timing (meet_source) and the 50% rule (rules) have already happened upstream;
reconcile only joins their results against the invite list. Keeping it pure means
the four outcomes are decided in one place and tested without any fixtures.

The four outcomes, restated for whoever inherits this:
  invited + attended           -> attendance row, attended=True
  invited + present but <50%   -> attendance row, present=True, attended=False
  invited + absent             -> attendance row, present=False, attended=False
  attended + not invited       -> attendance row, invited=False (a known learner
                                  who showed up uninvited; IDC may want to know)

Attendees that resolved to a learner are joined by learner_id. Attendees that
did not resolve go to the review queue. Attendees flagged 'ignored' (the
recording bot, staff) are dropped entirely -- not counted, not queued.

INPUT CONTRACT
  invitee_learner_map : {email -> learner_id} for invitees that are known
                        learners. Built upstream by querying learner_identity_map
                        for the session's invitee emails. Non-learner invitees
                        (coaches, unseeded people) are simply absent from it.
  attendees           : list[AttendeeRecord], one per person who actually joined,
                        already carrying their identity resolution and attendance
                        evaluation.
"""

from dataclasses import dataclass


@dataclass
class AttendeeRecord:
    """One person who actually attended, fully processed upstream.

    Assembled by the pipeline from meet_source (timing), identity (resolution)
    and rules (the 50% evaluation).
    """
    google_user_id: str | None
    display_name: str
    participant_type: str          # 'signed_in' | 'anonymous' | 'phone'
    learner_id: str | None         # from identity; None if unresolved
    matched_email: str | None      # from identity; the email it resolved/matched to
    resolution_method: str         # 'cache_user_id'|'name_invite_match'|'ignored'|'unmatched'
    present: bool
    attended: bool
    attendance_pct: float
    participant_minutes: int


@dataclass
class AttendanceRow:
    """Maps to meeting_attendance (session-level fields added on persist)."""
    learner_id: str
    participant_email: str | None
    invited: bool
    present: bool
    attended: bool
    attendance_pct: float
    participant_minutes: int


@dataclass
class UnmatchedRow:
    """Maps to unmatched_participants (session-level fields added on persist)."""
    google_user_id: str | None
    display_name: str
    participant_type: str
    participant_minutes: int
    matched_email: str | None      # a hint for the reviewer if a name matched but
                                   # the person wasn't a seeded learner


@dataclass
class ReconcileResult:
    attendance_rows: list
    unmatched_rows: list


def reconcile(invitee_learner_map: dict, attendees: list) -> ReconcileResult:
    attendance_rows = []
    unmatched_rows = []

    # Index attendees who resolved to a learner; route the rest.
    attended_by_learner = {}
    for a in attendees:
        if a.resolution_method == "ignored":
            continue  # bot / staff: not counted, not queued
        if a.learner_id is not None:
            # Last write wins if a learner somehow appears twice (e.g. two
            # devices resolving to the same id) -- a single attendance row.
            attended_by_learner[a.learner_id] = a
        else:
            unmatched_rows.append(
                UnmatchedRow(
                    google_user_id=a.google_user_id,
                    display_name=a.display_name,
                    participant_type=a.participant_type,
                    participant_minutes=a.participant_minutes,
                    matched_email=a.matched_email,
                )
            )

    # Dedupe invited learners to one row each (a learner may have two invited
    # emails); keep one representative email per learner_id.
    invited = {}
    for email, learner_id in invitee_learner_map.items():
        invited.setdefault(learner_id, email)

    # 1. Every invited learner: attended or absent.
    for learner_id, email in invited.items():
        rec = attended_by_learner.get(learner_id)
        if rec is not None:
            attendance_rows.append(
                AttendanceRow(
                    learner_id=learner_id,
                    participant_email=rec.matched_email or email,
                    invited=True,
                    present=rec.present,
                    attended=rec.attended,
                    attendance_pct=rec.attendance_pct,
                    participant_minutes=rec.participant_minutes,
                )
            )
        else:
            attendance_rows.append(
                AttendanceRow(
                    learner_id=learner_id,
                    participant_email=email,
                    invited=True,
                    present=False,
                    attended=False,
                    attendance_pct=0.0,
                    participant_minutes=0,
                )
            )

    # 2. Matched learners who attended but were NOT invited.
    for learner_id, rec in attended_by_learner.items():
        if learner_id not in invited:
            attendance_rows.append(
                AttendanceRow(
                    learner_id=learner_id,
                    participant_email=rec.matched_email,
                    invited=False,
                    present=rec.present,
                    attended=rec.attended,
                    attendance_pct=rec.attendance_pct,
                    participant_minutes=rec.participant_minutes,
                )
            )

    return ReconcileResult(attendance_rows=attendance_rows, unmatched_rows=unmatched_rows)