"""Calendar side of the pipeline.

Fetches candidate sessions from the technical@ calendar and extracts everything
the rest of the pipeline needs from the event itself: the invite list (source of
truth for who should attend), the Meet code (to jump to the conference), the
organizer flag (whether WE organized it — see organized_by_us), and any
extendedProperties the Retool form will eventually write.
"""

from dataclasses import dataclass, field
from datetime import datetime

from googleapiclient.discovery import build

from config import ORG_DOMAIN, SAST


@dataclass
class Invitee:
    email: str
    response_status: str
    is_org_domain: bool


@dataclass
class CandidateSession:
    calendar_event_id: str
    title_raw: str
    organizer_email: str
    organized_by_us: bool          # organizer.self — gates "zero conferences = no-show"
    scheduled_start: datetime | None # use python 3.10.x or above to compile this correctly
    scheduled_end: datetime | None
    meeting_code: str | None
    invitees: list[Invitee] = field(default_factory=list)
    extended_properties: dict = field(default_factory=dict)

    @property
    def org_invitees(self):
        """MVP-relevant invitees: those on the org domain."""
        return [i for i in self.invitees if i.is_org_domain]


def build_calendar_service(creds):
    return build("calendar", "v3", credentials=creds)


def _parse_dt(node):
    if not node:
        return None
    if raw := node.get("dateTime"):
        return datetime.fromisoformat(raw)                     # timed -> tz-aware
    if raw := node.get("date"):
        return datetime.fromisoformat(raw).replace(tzinfo=SAST) 
    return None


def _extract_meeting_code(event):
    conf = event.get("conferenceData", {})
    # Primary: conferenceId carries the code directly (confirmed by the probe).
    code = conf.get("conferenceId")
    if code:
        return code
    # Fallback: parse from the video entry point URI.
    for ep in conf.get("entryPoints", []):
        if ep.get("entryPointType") == "video":
            return ep.get("uri", "").rsplit("/", 1)[-1] or None
    return None


def _extract_invitees(event):
    invitees = []
    for a in event.get("attendees", []):
        if a.get("resource"):          # skip meeting rooms / equipment
            continue
        email = (a.get("email") or "").strip().lower()
        if not email:
            continue
        invitees.append(
            Invitee(
                email=email,
                response_status=a.get("responseStatus", "needsAction"),
                is_org_domain=email.endswith("@" + ORG_DOMAIN),
            )
        )
    return invitees


def fetch_candidate_sessions(service, time_min, time_max, calendar_id):
    """Return all events in [time_min, time_max] as CandidateSession objects.

    time_min / time_max are RFC3339 UTC strings. Paginated for safety.
    """
    sessions = []
    page_token = None
    while True:
        resp = (
            service.events()
            .list(
                calendarId=calendar_id,
                timeMin=time_min,
                timeMax=time_max,
                singleEvents=True,
                orderBy="startTime",
                pageToken=page_token,
            )
            .execute()
        )
        for ev in resp.get("items", []):
            organizer = ev.get("organizer", {})
            sessions.append(
                CandidateSession(
                    calendar_event_id=ev.get("id"),
                    title_raw=ev.get("summary", ""),
                    organizer_email=(organizer.get("email") or "").strip().lower(),
                    organized_by_us=bool(organizer.get("self")),
                    scheduled_start=_parse_dt(ev.get("start")),
                    scheduled_end=_parse_dt(ev.get("end")),
                    meeting_code=_extract_meeting_code(ev),
                    invitees=_extract_invitees(ev),
                    extended_properties=ev.get("extendedProperties", {}),
                )
            )
        page_token = resp.get("nextPageToken")
        if not page_token:
            break
    return sessions