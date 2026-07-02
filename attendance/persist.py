"""Idempotent writes for one processed session.

The single public entry point is persist_session(): given everything the
pipeline computed for one calendar event, it writes the session, its
conferences, the raw participant log, the clean attendance rows, and any
review-queue rows -- all inside ONE transaction, so a session lands completely
or not at all.

DESIGN NOTES (the decisions worth understanding before editing):

  Transaction boundary. This module opens no connection and chooses no isolation
  level; the caller passes a connection and this function wraps its work in a
  single commit/rollback. One session = one transaction. A crash mid-session
  rolls the whole session back, and the next run redoes it cleanly -- never a
  half-written session.

  Idempotency, table by table. Every write keys on a stable identifier so reruns
  (the nightly job, the weekly safety-net, a manual replay) converge instead of
  duplicating:
    - meeting_attendance_raw : INSERT ... ON CONFLICT (participant_session_id)
      DO NOTHING. The raw log is IMMUTABLE -- a participant session is a fact
      that happened; we never rewrite it.
    - meeting_conferences / meeting_sessions : upsert on their natural PKs.
    - meeting_attendance : upsert on (calendar_event_id, learner_id) DO UPDATE.
      This is the RECOMPUTE surface -- if the threshold or floor changes and we
      replay, the verdict updates in place rather than duplicating.
    - unmatched_participants : upsert on (calendar_event_id,
      coalesce(google_user_id, display_name)) so a rerun doesn't re-queue the
      same person; a row already resolved by a human is left untouched.

  Observability gate. The pipeline must NOT call this for a session it could not
  observe (one technical@ did not organize -> zero conferences is meaningless,
  not a real no-show). persist trusts that gate: it writes the absent rows it is
  given. See pipeline.py for where that decision is made.
"""

from datetime import timezone, timedelta

from attendance.config import SAST


def _to_sast_date(dt):
    """date_service_accessed: the calendar day of a session's actual start, in
    the org timezone. Returns None when the session never ran (no actual_start)."""
    if dt is None:
        return None
    return dt.astimezone(SAST).date()


def persist_session(conn, *, session, conferences, raw_participants,
                    attendance_rows, unmatched_rows):
    """Write one fully-processed session and its children in a single transaction.

    Parameters (all already computed upstream; this module only writes):
      session          : object with calendar_event_id, session_type_code,
                         session_type_source, title_raw, meet_space_code,
                         organizer_email, scheduled_start/end, actual_start/end,
                         actual_duration_minutes, denominator_minutes,
                         conference_count, invited_count.
      conferences      : list of ConferenceInfo (meet_source) for this event.
      raw_participants : list of dicts, one per participant session, with keys:
                         participant_session_id, conference_record_id,
                         participant_type, google_user_id, display_name, email,
                         session_start, session_end, duration_seconds.
      attendance_rows  : list[reconcile.AttendanceRow].
      unmatched_rows   : list[reconcile.UnmatchedRow].
    """
    eid = session.calendar_event_id
    date_accessed = _to_sast_date(session.actual_start)

    try:
        with conn.cursor() as cur:
            _upsert_session(cur, session, date_accessed)
            _upsert_conferences(cur, eid, conferences)
            _insert_raw(cur, eid, raw_participants)
            _upsert_attendance(cur, eid, session.session_type_code,
                               date_accessed, attendance_rows)
            _upsert_unmatched(cur, eid, conferences, unmatched_rows)
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def _upsert_session(cur, s, date_accessed):
    cur.execute(
        """
        INSERT INTO meeting_sessions (
            calendar_event_id, session_type_code, session_type_source,
            session_title_raw, meet_space_code, organizer_email,
            scheduled_start, scheduled_end, actual_start, actual_end,
            actual_duration_minutes, denominator_minutes, conference_count,
            date_service_accessed, invited_count, updated_at
        ) VALUES (
            %(eid)s, %(type)s, %(type_src)s, %(title)s, %(space)s, %(org)s,
            %(ss)s, %(se)s, %(as)s, %(ae)s, %(dur)s, %(den)s, %(cc)s,
            %(date)s, %(inv)s, now()
        )
        ON CONFLICT (calendar_event_id) DO UPDATE SET
            session_type_code       = EXCLUDED.session_type_code,
            session_type_source     = EXCLUDED.session_type_source,
            session_title_raw       = EXCLUDED.session_title_raw,
            meet_space_code         = EXCLUDED.meet_space_code,
            organizer_email         = EXCLUDED.organizer_email,
            scheduled_start         = EXCLUDED.scheduled_start,
            scheduled_end           = EXCLUDED.scheduled_end,
            actual_start            = EXCLUDED.actual_start,
            actual_end              = EXCLUDED.actual_end,
            actual_duration_minutes = EXCLUDED.actual_duration_minutes,
            denominator_minutes     = EXCLUDED.denominator_minutes,
            conference_count        = EXCLUDED.conference_count,
            date_service_accessed   = EXCLUDED.date_service_accessed,
            invited_count           = EXCLUDED.invited_count,
            updated_at              = now()
        """,
        {
            "eid": s.calendar_event_id,
            "type": s.session_type_code,
            "type_src": s.session_type_source,
            "title": s.session_title_raw,
            "space": s.meet_space_code,
            "org": s.organizer_email,
            "ss": s.scheduled_start,
            "se": s.scheduled_end,
            "as": s.actual_start,
            "ae": s.actual_end,
            "dur": s.actual_duration_minutes,
            "den": s.denominator_minutes,
            "cc": s.conference_count,
            "date": date_accessed,
            "inv": s.invited_count,
        },
    )


def _upsert_conferences(cur, eid, conferences):
    for c in conferences:
        cur.execute(
            """
            INSERT INTO meeting_conferences (
                conference_record_id, calendar_event_id, meet_space_code,
                conference_start, conference_end, duration_minutes
            ) VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (conference_record_id) DO UPDATE SET
                conference_start = EXCLUDED.conference_start,
                conference_end   = EXCLUDED.conference_end,
                duration_minutes = EXCLUDED.duration_minutes
            """,
            (
                c.conference_record_id, eid, getattr(c, "meet_space_code", None),
                c.start, c.end, round(c.duration_seconds / 60),
            ),
        )


def _insert_raw(cur, eid, raw_participants):
    # Immutable log: insert-or-ignore. We never rewrite a participant session.
    for p in raw_participants:
        cur.execute(
            """
            INSERT INTO meeting_attendance_raw (
                participant_session_id, conference_record_id, calendar_event_id,
                participant_type, google_user_id, participant_display_name,
                participant_email, session_start, session_end,
                session_duration_seconds
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (participant_session_id) DO NOTHING
            """,
            (
                p["participant_session_id"], p["conference_record_id"], eid,
                p["participant_type"], p.get("google_user_id"),
                p.get("display_name"), p.get("email"),
                p["session_start"], p.get("session_end"),
                p.get("duration_seconds"),
            ),
        )


def _upsert_attendance(cur, eid, session_type_code, date_accessed, rows):
    for r in rows:
        cur.execute(
            """
            INSERT INTO meeting_attendance (
                calendar_event_id, learner_id, participant_email,
                session_type_code, date_service_accessed,
                invited, present, attended,
                participant_minutes, attendance_pct, denominator_minutes, computed_at
                -- TODO: service name is not written for now
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, now())
            ON CONFLICT (calendar_event_id, learner_id) DO UPDATE SET
                participant_email     = EXCLUDED.participant_email,
                session_type_code     = EXCLUDED.session_type_code,
                date_service_accessed = EXCLUDED.date_service_accessed,
                invited               = EXCLUDED.invited,
                present               = EXCLUDED.present,
                attended              = EXCLUDED.attended,
                participant_minutes   = EXCLUDED.participant_minutes,
                attendance_pct        = EXCLUDED.attendance_pct,
                denominator_minutes = EXCLUDED.denominator_minutes,
                computed_at           = now()
            """,
            (
                eid, r.learner_id, r.participant_email,
                session_type_code, date_accessed,
                r.invited, r.present, r.attended,
                r.participant_minutes, round(r.attendance_pct, 4),
                r.denominator_minutes
            ),
        )


def _upsert_unmatched(cur, eid, conferences, rows):
    # Best-effort conference id for context; the queue row is keyed on the event
    # plus the person, so re-running doesn't duplicate, and a row a human already
    # moved off 'pending' is left untouched.
    conf_id = conferences[0].conference_record_id if conferences else None
    for u in rows:
        cur.execute(
            """
            INSERT INTO unmatched_participants (
                conference_record_id, calendar_event_id, participant_type,
                google_user_id, participant_display_name, participant_email,
                participant_minutes, status
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, 'pending')
            ON CONFLICT (calendar_event_id, (COALESCE(google_user_id, participant_display_name)))
            DO UPDATE SET
                participant_minutes = EXCLUDED.participant_minutes
            WHERE unmatched_participants.status = 'pending'
            """,
            (
                conf_id, eid, u.participant_type, u.google_user_id,
                u.display_name, u.matched_email, u.participant_minutes,
            ),
        )