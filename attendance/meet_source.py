"""Meet side of the pipeline.

For a given meeting code, resolves the conference record(s), drops noise
conferences (fewer than MIN_PARTICIPANTS_FOR_REAL_CONFERENCE distinct people),
and aggregates each participant's total in-call time across the kept conferences.
The 50% threshold itself lives in attendance.py — this module only produces the
raw seconds and the denominator. All method chains here were validated by probe.py.
"""

from dataclasses import dataclass, field
from datetime import datetime

from googleapiclient.discovery import build

from attendance.config import (
    MIN_PARTICIPANTS_FOR_REAL_CONFERENCE,
    DENOMINATOR_FLOOR_SECONDS,
    DENOMINATOR_GRACE_SECONDS
)


@dataclass
class ParticipantTime:
    key: str                       # google_user_id, or participant resource name for anon/phone
    google_user_id: str | None     # "users/{id}" for signed-in; None otherwise
    display_name: str
    participant_type: str          # 'signed_in' | 'anonymous' | 'phone' | 'unknown'
    total_seconds: int = 0


@dataclass
class ConferenceInfo:
    conference_record_id: str      # "conferenceRecords/{id}"
    start: datetime
    end: datetime
    duration_seconds: int
    participant_count: int


@dataclass
class SessionConferences:
    meeting_code: str
    kept_conferences: list[ConferenceInfo] = field(default_factory=list)
    all_conference_count: int = 0          # before the noise filter
    actual_duration_seconds: int = 0       # sum of kept durations, unfloored
    denominator_seconds: int = 0           # max(actual, floor); 0 if it never ran
    participants: dict = field(default_factory=dict)  # key -> ParticipantTime

    @property
    def ran(self):
        return len(self.kept_conferences) > 0


def build_meet_service(creds):
    return build("meet", "v2", credentials=creds)


def _parse_ts(s):
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)


def _paginate(request_fn, items_key):
    page_token = None
    while True:
        resp = request_fn(page_token)
        for item in resp.get(items_key, []):
            yield item
        page_token = resp.get("nextPageToken")
        if not page_token:
            break


def _classify(participant):
    """Return (type, google_user_id, display_name) for a participant record."""
    if "signedinUser" in participant:
        u = participant["signedinUser"]
        return "signed_in", u.get("user"), u.get("displayName", "")
    if "anonymousUser" in participant:
        return "anonymous", None, participant["anonymousUser"].get("displayName", "")
    if "phoneUser" in participant:
        return "phone", None, participant["phoneUser"].get("displayName", "")
    return "unknown", None, ""


def get_session_conferences(meet, meeting_code, scheduled_seconds=None):
    result = SessionConferences(meeting_code=meeting_code)

    records = list(
        _paginate(
            lambda tok: meet.conferenceRecords()
            .list(filter=f'space.meeting_code="{meeting_code}"', pageToken=tok)
            .execute(),
            "conferenceRecords",
        )
    )
    result.all_conference_count = len(records)

    for rec in records:
        rec_name = rec["name"]
        participants = list(
            _paginate(
                lambda tok, rn=rec_name: meet.conferenceRecords()
                .participants()
                .list(parent=rn, pageToken=tok)
                .execute(),
                "participants",
            )
        )

        # Noise filter: a real session has a group; a link-popper is alone.
        if len(participants) < MIN_PARTICIPANTS_FOR_REAL_CONFERENCE:
            continue

        start = _parse_ts(rec["startTime"])
        end = _parse_ts(rec["endTime"])
        result.kept_conferences.append(
            ConferenceInfo(
                conference_record_id=rec_name,
                start=start,
                end=end,
                duration_seconds=int((end - start).total_seconds()),
                participant_count=len(participants),
            )
        )

        # Aggregate each participant's session time across all kept conferences.
        for p in participants:
            ptype, guid, dname = _classify(p)
            key = guid or p["name"]
            pt = result.participants.get(key)
            if pt is None:
                pt = ParticipantTime(
                    key=key,
                    google_user_id=guid,
                    display_name=dname,
                    participant_type=ptype,
                )
                result.participants[key] = pt

            for sess in _paginate(
                lambda tok, pn=p["name"]: meet.conferenceRecords()
                .participants()
                .participantSessions()
                .list(parent=pn, pageToken=tok)
                .execute(),
                "participantSessions",
            ):
                s_start = _parse_ts(sess["startTime"])
                s_end = _parse_ts(sess["endTime"]) if sess.get("endTime") else s_start
                pt.total_seconds += int((s_end - s_start).total_seconds())

    result.actual_duration_seconds = sum(
        c.duration_seconds for c in result.kept_conferences
    )
    if not result.ran:
        result.denominator_seconds = 0
        return result
    
    # start from the real conference duration
    denominator = result.actual_duration_seconds
    
    # Cap at scheduled + grace when a trustworthy schedule exists. This clips a
    # lingering recording (technical account left in the call) out of the math:
    # a 60-min session whose recording ran 112 min is still measured against ~60.
    # No schedule -> fall back to actual duration (prior behaviour).
    if scheduled_seconds and scheduled_seconds > 0:
        denominator = min(denominator, scheduled_seconds + DENOMINATOR_GRACE_SECONDS)
      
    # Floor guards degenerate short conferences. Applied last so the floor always
    # wins: a 10-min scheduled session still gets the 30-min floor, not 25.  
    result.denominator_seconds = max(denominator, DENOMINATOR_FLOOR_SECONDS)  
    
    return result