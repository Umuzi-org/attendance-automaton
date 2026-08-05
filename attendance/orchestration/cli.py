"""Command-line entry point for the attendance pipeline.

Two run modes, matching the two scheduled jobs:
  nightly : a rolling lookback window (default ~36h) so late-ending sessions
            fall fully inside.
  weekly  : the prior 7 days, the idempotent safety-net re-run.
  custom  : explicit --since / --until ISO timestamps, for backfills/debugging.

Wired as the `attendance-run` console script in pyproject.toml
(attendance.orchestration.cli:main).
"""

import argparse
import logging
import os
import sys
from datetime import datetime, timedelta, timezone

import psycopg2

from attendance.config import SAST, CALENDAR_ID, ACCOUNTS
from attendance.auth import get_credentials
from attendance.orchestration import pipeline


def _utc_iso(dt):
    """pipeline/calendar expect RFC3339 UTC strings."""
    return dt.astimezone(timezone.utc).isoformat()


def _compute_window(mode, since, until, lookback_hours):
    """Return (time_min, time_max) as RFC3339 UTC strings, reasoned in SAST."""
    now = datetime.now(SAST)
    if mode == "custom":
        if not (since and until):
            raise SystemExit("custom mode requires --since and --until (ISO 8601)")
        return _utc_iso(datetime.fromisoformat(since)), _utc_iso(datetime.fromisoformat(until))
    if mode == "weekly":
        return _utc_iso(now - timedelta(days=7)), _utc_iso(now)
    # nightly (default): rolling lookback.
    return _utc_iso(now - timedelta(hours=lookback_hours)), _utc_iso(now)


def _connect():
    """Connection from DATABASE_URL (or PG* env vars psycopg2 reads natively)."""
    dsn = os.environ.get("DATABASE_URL")
    return psycopg2.connect(dsn) if dsn else psycopg2.connect()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Run the Meet attendance pipeline.")
    parser.add_argument("--mode", choices=["nightly", "weekly", "custom"], default="nightly")
    parser.add_argument("--since", help="ISO 8601 start (custom mode)")
    parser.add_argument("--until", help="ISO 8601 end (custom mode)")
    parser.add_argument("--lookback-hours", type=int, default=36,
                        help="nightly lookback window size (default 36)")
    parser.add_argument("--calendar-id", default=CALENDAR_ID)
    parser.add_argument("--log-level", default="INFO")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=getattr(logging, args.log_level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    log = logging.getLogger("attendance.cli")

    time_min, time_max = _compute_window(
        args.mode, args.since, args.until, args.lookback_hours
    )


    conn = _connect()
    totals = {}
    failed_accounts = []
    try:
        for dept_key, token_env in ACCOUNTS.items():
            try:
                creds = get_credentials(refresh_token_env=token_env)
                tally = pipeline.run(
                    conn, creds, time_min, time_max, args.calendar_id, department_key=dept_key
                )
                log.info("Account %s: %s", dept_key, tally)
                
                for k, v in tally.items():
                    totals[k] = totals.get(k, 0) + v
                    
            except Exception:
                log.exception("Account %s failed; continuing", dept_key)
                failed_accounts.append(dept_key)
    finally:
        conn.close()

    # Non-zero exit if any session errored, so the scheduled job surfaces it.
    errors = totals.get("error", 0)
    log.info("done: %s (failed accounts: %s)", totals, failed_accounts or "none")
    return 1 if errors or failed_accounts else 0


if __name__ == "__main__":
    sys.exit(main())