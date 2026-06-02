"""Resolve a session's type code from a calendar event.

Two sources, in priority order:

  1. extendedProperties.private.session_type_code  -- written by the Retool
     setup form (Phase 5). Authoritative when present: it was chosen from a
     dropdown, so it cannot be a typo.
  2. The title prefix, e.g. "[SME] Module 5" -> "SME"  -- the fallback for
     events created by hand, before the form existed or when someone bypasses it.

Which source won is recorded as `source`, so meeting_sessions.session_type_source
can later tell you how many sessions came through the form vs. were hand-made
(a form-adoption metric), and so an unknown type is explicit rather than silent.

This module deliberately does NOT validate the code against the session_types
table. Validation is a database concern (the FK on meeting_sessions handles it);
here we only extract what the event claims its type is.
"""

import re
from dataclasses import dataclass

# Matches a leading bracketed, uppercase code: "[SME] ..." -> "SME".
# Anchored at the start so "[SME]" in the middle of a title is ignored.
_TITLE_PREFIX = re.compile(r"^\[([A-Z0-9-]+)\]")


@dataclass
class ResolvedType:
    code: str | None   # e.g. "SME"; None when neither source yields a code
    source: str        # 'form_metadata' | 'title_parse' | 'unknown'


def resolve_session_type(extended_properties: dict, title_raw: str) -> ResolvedType:
    """Return the session type code and where it came from.

    `extended_properties` is the raw event.extendedProperties dict (may be {}).
    `title_raw` is event.summary (may be "").
    """
    # 1. Form metadata wins if present.
    private = (extended_properties or {}).get("private", {})
    code = private.get("session_type_code")
    if code:
        return ResolvedType(code=code.strip().upper(), source="form_metadata")

    # 2. Fall back to the title prefix.
    match = _TITLE_PREFIX.match(title_raw or "")
    if match:
        return ResolvedType(code=match.group(1).upper(), source="title_parse")

    # 3. Neither -- caller decides what to do (likely skip or flag for review).
    return ResolvedType(code=None, source="unknown")