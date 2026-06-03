"""Resolve a Meet participant to a learner_id -- WITHOUT the directory API.

External directory sharing is disabled on this Workspace, so People/Directory
lookups return nothing for other users. Instead we bridge users/{id} -> email
using data we already hold for every technical@-organized session: the Meet
participant's display name and the calendar INVITE LIST for that same session.

The waterfall, in order, stopping at the first hit:

  1. Cache hit on google_user_id -- the steady state. Once a participant has
     been resolved once, this O(1) lookup catches them forever.
  2. Ignore list -- known service accounts / staff (e.g. the recording bot) are
     skipped so they never clutter the review queue.
  3. Invite-scoped name match -- normalize the display name to a token set and
     match it against THIS session's invitee email local-parts. Scoping to the
     ~8 invitees (not the whole org) is what makes a name signal safe: a false
     match would have to ALSO be invited to this exact session. On a unique
     match we write google_user_id -> email -> learner_id back to the identity
     map (the self-healing cache), so step 1 catches them next time.
  4. No confident match -> caller routes to unmatched_participants for a human
     to resolve once. After that, the cache (step 1) takes over.

This name-match resolver is the MVP bridge. Once the Retool setup form writes
attendee emails into the event's extendedProperties, resolution becomes exact
and this logic degrades to a pure backstop rather than the primary path.
"""

import re
from dataclasses import dataclass

from attendance.config import NAME_MATCH_CONFIDENCE


@dataclass
class IdentityResolution:
    learner_id: str | None
    matched_email: str | None
    method: str   # 'cache_user_id' | 'name_invite_match' | 'ignored' | 'unmatched'


@dataclass
class IgnoreList:
    """Loaded once per run. Service accounts / staff to skip during resolution."""
    user_ids: set
    emails: set


def load_ignore_list(cur) -> IgnoreList:
    cur.execute("SELECT google_user_id, email FROM ignored_identities WHERE is_active")
    user_ids, emails = set(), set()
    for guid, email in cur.fetchall():
        if guid:
            user_ids.add(guid)
        if email:
            emails.add(email.strip().lower())
    return IgnoreList(user_ids=user_ids, emails=emails)


def _name_tokens(value: str) -> frozenset:
    """Order-independent, case-insensitive token set. Splits on whitespace and
    dots so 'June Makhubela' and 'june.makhubela' both -> {june, makhubela}."""
    return frozenset(t for t in re.split(r"[\s.]+", (value or "").strip().lower()) if t)


def match_display_name_to_invitee(display_name: str, invitee_emails) -> str | None:
    """Return the single invitee email whose local-part name tokens equal the
    display name's tokens, or None for zero or multiple candidates.

    Requiring a UNIQUE match is deliberate: ambiguity goes to review rather than
    being guessed. invitee_emails should already be org-domain and lowercased.
    """
    target = _name_tokens(display_name)
    if not target:
        return None
    candidates = [e for e in invitee_emails if _name_tokens(e.split("@", 1)[0]) == target]
    return candidates[0] if len(candidates) == 1 else None


# --- DB helpers. Caller owns the connection/transaction; this never commits. ---

def _lookup_by_user_id(cur, google_user_id: str):
    cur.execute(
        "SELECT learner_id, email FROM learner_identity_map WHERE google_user_id = %s",
        (google_user_id,),
    )
    return cur.fetchone()  # (learner_id, email) or None


def _lookup_by_email(cur, email: str):
    cur.execute(
        "SELECT learner_id FROM learner_identity_map WHERE email = %s",
        (email,),
    )
    row = cur.fetchone()
    return row[0] if row else None


def _cache_user_id(cur, google_user_id: str, email: str, learner_id: str) -> None:
    """Bind the freshly-matched google_user_id onto the existing email row so
    future runs hit the cache. Idempotent; keyed on the seeded email."""
    cur.execute(
        """
        UPDATE learner_identity_map
           SET google_user_id = %s,
               match_method   = 'name_invite_match',
               confidence     = %s,
               last_confirmed = now()
         WHERE email = %s
           AND (google_user_id IS NULL OR google_user_id = %s)
        """,
        (google_user_id, NAME_MATCH_CONFIDENCE, email, google_user_id),
    )


def resolve_participant(cur, ignore: IgnoreList, google_user_id: str | None,
                        display_name: str, session_invitees) -> IdentityResolution:
    """Run the waterfall for one participant of one session.

    google_user_id  : 'users/{id}', or None for anonymous/phone (-> unmatched).
    display_name    : the Meet display name, used for the name match.
    session_invitees: org-domain invitee emails for THIS session (lowercased).
    """
    if not google_user_id:
        return IdentityResolution(None, None, "unmatched")

    # 1. Cache hit.
    cached = _lookup_by_user_id(cur, google_user_id)
    if cached:
        return IdentityResolution(cached[0], cached[1], "cache_user_id")

    # 2. Known service account / staff -> skip, do not queue for review.
    if google_user_id in ignore.user_ids:
        return IdentityResolution(None, None, "ignored")

    # 3. Invite-scoped name match.
    email = match_display_name_to_invitee(display_name, session_invitees)
    if email:
        if email in ignore.emails:
            return IdentityResolution(None, email, "ignored")
        learner_id = _lookup_by_email(cur, email)
        if learner_id:
            _cache_user_id(cur, google_user_id, email, learner_id)
            return IdentityResolution(learner_id, email, "name_invite_match")
        # Matched a real invitee, but that person isn't in the learner map yet
        # (e.g. a new joiner not seeded). Capture the email for the review queue.
        return IdentityResolution(None, email, "unmatched")

    # 4. No confident match.
    return IdentityResolution(None, None, "unmatched")