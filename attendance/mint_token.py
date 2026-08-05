"""One-time local helper: mint a read-scoped refresh token for one account.

Run once per department account, signed in AS that account (see instructions
printed by the script). Uses the PIPELINE OAuth client -- never the form client.

Usage:
    export GOOGLE_CLIENT_ID=...        # pipeline client (0ue120...)
    export GOOGLE_CLIENT_SECRET=...
    python scripts/mint_token.py
"""

import os

from google_auth_oauthlib.flow import InstalledAppFlow

from attendance.config import SCOPES


def main():
    flow = InstalledAppFlow.from_client_config(
        {
            "installed": {
                "client_id": os.environ["GOOGLE_CLIENT_ID"],
                "client_secret": os.environ["GOOGLE_CLIENT_SECRET"],
                "auth_uri": "https://accounts.google.com/o/oauth2/auth",
                "token_uri": "https://oauth2.googleapis.com/token",
            }
        },
        scopes=SCOPES,
    )
    creds = flow.run_local_server(
        port=8765,
        open_browser=False,
        access_type="offline",
        prompt="consent",
    )
    print("\nRefresh token (store as a GitHub secret, then clear this terminal):\n")
    print(creds.refresh_token)


if __name__ == "__main__":
    main()