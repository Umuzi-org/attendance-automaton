"""Credential construction — refactored from the Phase 1 smoke test.

Reads the four secrets from the environment (set from GitHub Secrets in CI, or
exported locally) and returns a refreshed Credentials object that every Google
client in this package accepts. No interactive flow ever runs here.
"""

import os

from google.oauth2.credentials import Credentials
from google.auth.transport.requests import Request

from attendance.config import SCOPES


def get_credentials(refresh_token_env: str):
    creds = Credentials(
        token=None,  # forces a refresh on first use
        refresh_token=os.environ[refresh_token_env],
        client_id=os.environ["GOOGLE_CLIENT_ID"],
        client_secret=os.environ["GOOGLE_CLIENT_SECRET"],
        token_uri=os.environ["GOOGLE_TOKEN_URI"],
        scopes=SCOPES,
    )
    creds.refresh(Request())
    return creds