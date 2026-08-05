"""The orchestration: turn a time window into persisted attendance.

This is the only module that imports the others and wires them in order. Every
domain module (calendar_source, meet_source, session_type, identity, rules,
reconcile, persist) stays unaware of the rest; this is where they meet.

Per run:
    window -> candidate sessions (calendar)
    for each session:
        resolve type -> resolve conferences -> OBSERVABILITY GATE
        -> pull participants + time -> assemble attendees (identity + rules)
        -> build invitee->learner map -> reconcile -> persist (one txn)

THE OBSERVABILITY GATE is the one decision that must not be gotten wrong. The
Meet API only returns conference records for sessions technical@ organized. So
"zero conferences" means one of two very different things:
    - we organized it and nobody (really) showed   -> a true no-show; persist
      the session with every invitee marked absent.
    - we did NOT organize it                       -> we simply cannot see it;
      persisting absences here would be FALSE DATA. Skip it, do not write.
The gate distinguishes them using calendar_source's organized_by_us flag. Get
this wrong and you fabricate absences for sessions you were never able to watch.
"""

import logging

from attendance import calendar_source, meet_source, session_type, identity, rules, reconcile, persist

log = logging.getLogger("attendance.pipeline")

class _SessionRecord:
    """Plain attribute bag matching persist.persist_session's `session` contract."""
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _seconds_to_minutes(seconds):
    return round((seconds or 0) / 60)


def _build_invitee_learner_map(cur, invitee_emails):
    """Resolve this session's invitee emails to learner_ids in one query.
    Non-learner invitees (coaches, unseeded people) simply won't appear."""
    if not invitee_emails:
        return {}
    cur.execute(
        "SELECT email, learner_id FROM learner_identity_map WHERE email = ANY(%s)",
        (list(invitee_emails),),
    )
    return {email: learner_id for email, learner_id in cur.fetchall()}


def _raw_rows_for_session(conferences_obj):
    """Flatten meet_source's per-participant aggregate back into one raw row per
    participant per conference. meet_source already summed sessions for the
    attendance verdict; the raw log keeps the per-conference granularity."""
    rows = []
    for conf in conferences_obj.kept_conferences:
        for pt in conferences_obj.participants.values():
            # A participant only contributes a raw row to conferences they were
            # actually in. meet_source aggregates time across kept conferences,
            # so we record one row per (participant, conference) with the
            # participant's total; this preserves the FK to the conference while
            # keeping the immutable log populated. (For exact per-conference
            # splits, see the note in meet_source -- aggregate is sufficient
            # for the raw audit trail in the MVP.)
            rows.append({
                "participant_session_id": f"{conf.conference_record_id}::{pt.key}",
                "conference_record_id": conf.conference_record_id,
                "participant_type": pt.participant_type,
                "google_user_id": pt.google_user_id,
                "display_name": pt.display_name,
                "email": None,  # Meet never gives us this; resolved separately
                "session_start": conf.start,
                "session_end": conf.end,
                "duration_seconds": pt.total_seconds,
            })
    return rows

def _session_record(candidate, rtype, conferences_obj, department_key=None):
    """Build the flat object persist.persist_session expects, merging the
    calendar facts (scheduled, organizer, type) with the observed facts
    (actual times, durations, conference count)."""
    ran = conferences_obj is not None and conferences_obj.ran

    actual_start = actual_end = None
    actual_minutes = denom_minutes = 0
    conf_count = 0
    space = candidate.meeting_code
    if ran:
        starts = [c.start for c in conferences_obj.kept_conferences]
        ends = [c.end for c in conferences_obj.kept_conferences]
        actual_start, actual_end = min(starts), max(ends)
        actual_minutes = _seconds_to_minutes(conferences_obj.actual_duration_seconds)
        denom_minutes = _seconds_to_minutes(conferences_obj.denominator_seconds)
        conf_count = len(conferences_obj.kept_conferences)

    return _SessionRecord(
        calendar_event_id=candidate.calendar_event_id,
        session_type_code=rtype.code,
        session_type_source=rtype.source,
        session_title_raw=candidate.title_raw,
        meet_space_code=space,
        organizer_email=candidate.organizer_email,
        scheduled_start=candidate.scheduled_start,
        scheduled_end=candidate.scheduled_end,
        actual_start=actual_start,
        actual_end=actual_end,
        actual_duration_minutes=actual_minutes,
        denominator_minutes=denom_minutes,
        conference_count=conf_count,
        invited_count=len(candidate.org_invitees),
        department_key=department_key
    )

def _persist_no_show(conn, candidate, rtype, department_key=None):
    """Write a session we organized that never really ran: all invitees absent."""
    with conn.cursor() as cur:
        invitee_emails = [i.email for i in candidate.org_invitees]
        invitee_learner_map = _build_invitee_learner_map(cur, invitee_emails)
        session_record = _session_record(candidate ,rtype,conferences_obj=None, department_key=department_key)
    result = reconcile.reconcile(invitee_learner_map, attendees=[], denominator_minutes=session_record.denominator_minutes)
    persist.persist_session(
        conn,
        session=session_record,
        conferences=[],
        raw_participants=[],
        attendance_rows=result.attendance_rows,
        unmatched_rows=result.unmatched_rows,
    )


def process_session(conn, meet_service, ignore, candidate, department_key):
    """Process one CandidateSession end to end. Returns a short status string."""
    eid = candidate.calendar_event_id

    # Resolve the session type (extendedProperties -> title parse).
    rtype = session_type.resolve_session_type(
        candidate.extended_properties, candidate.title_raw
    )
    if rtype.code is None:
        log.info("skip %s: no session type (title=%r)", eid, candidate.title_raw)
        return "skipped_no_type"
    if not candidate.meeting_code:
        log.info("skip %s: no Meet link", eid)
        return "skipped_no_meet"

    # Resolve to conference record(s).
    scheduled_seconds = None
    if candidate.scheduled_start and candidate.scheduled_end:
        scheduled_seconds = int(
            (candidate.scheduled_end - candidate.scheduled_start).total_seconds()
        )
    
    confs = meet_source.get_session_conferences(meet_service, candidate.meeting_code, scheduled_seconds=scheduled_seconds)

    # ---- OBSERVABILITY GATE -------------------------------------------------
    if not confs.ran:
        if candidate.organized_by_us:
            # True no-show: write the session with everyone absent.
            log.info("no-show %s: organized by us, zero real conferences", eid)
            _persist_no_show(conn, candidate, rtype, department_key=department_key)
            return "no_show"
        # Not ours -> we genuinely cannot see it. Do NOT fabricate absences.
        log.info("skip %s: not organized by us and no conferences (unobservable)", eid)
        return "skipped_unobservable"
    # -------------------------------------------------------------------------

    # Assemble attendees: identity resolution + attendance evaluation per person.
    invitee_emails = [i.email for i in candidate.org_invitees]
    attendees = []
    with conn.cursor() as cur:
        for pt in confs.participants.values():
            res = identity.resolve_participant(
                cur, ignore, pt.google_user_id, pt.display_name, invitee_emails
            )
            verdict = rules.evaluate_attendance(pt.total_seconds, confs.denominator_seconds)
            attendees.append(reconcile.AttendeeRecord(
                google_user_id=pt.google_user_id,
                display_name=pt.display_name,
                participant_type=pt.participant_type,
                learner_id=res.learner_id,
                matched_email=res.matched_email,
                resolution_method=res.method,
                present=verdict.present,
                attended=verdict.attended,
                attendance_pct=verdict.attendance_pct,
                participant_minutes=verdict.participant_minutes,
            ))
        invitee_learner_map = _build_invitee_learner_map(cur, invitee_emails)

    session_record = _session_record(candidate=candidate, rtype=rtype, conferences_obj=confs, department_key=department_key)
    
    result = reconcile.reconcile(invitee_learner_map, attendees,
                                 denominator_minutes=session_record.denominator_minutes)

    # Stamp the observed session facts onto the candidate for persistence.
    persist.persist_session(
        conn,
        session=session_record,
        conferences=confs.kept_conferences,
        raw_participants=_raw_rows_for_session(confs),
        attendance_rows=result.attendance_rows,
        unmatched_rows=result.unmatched_rows,
    )
    log.info(
        "ok %s: %d attended-rows, %d to review",
        eid, len(result.attendance_rows), len(result.unmatched_rows),
    )
    return "processed"



def run(conn, creds, time_min, time_max, calendar_id, department_key):
    """Process every candidate session in [time_min, time_max]. Returns a tally
    of outcomes for the run summary / logging."""
    cal_service = calendar_source.build_calendar_service(creds)
    meet_service = meet_source.build_meet_service(creds)

    with conn.cursor() as cur:
        ignore = identity.load_ignore_list(cur)

    candidates = calendar_source.fetch_candidate_sessions(
        cal_service, time_min, time_max, calendar_id
    )
    log.info("window %s..%s: %d candidate sessions", time_min, time_max, len(candidates))

    tally = {}
    for candidate in candidates:
        try:
            status = process_session(conn, meet_service, ignore, candidate, department_key=department_key)
        except Exception:
            log.exception("FAILED session %s", candidate.calendar_event_id)
            status = "error"
        tally[status] = tally.get(status, 0) + 1
    log.info("run complete: %s", tally)
    return tally