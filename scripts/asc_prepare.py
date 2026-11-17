#!/usr/bin/env python3
"""Gets App Store Connect ready for an upload, using the API key.

Run by the TestFlight workflow before it archives:

1. Registers the app's bundle id if it is not registered yet.
2. Works out the team id from the bundle id's prefix, unless APPLE_TEAM_ID
   was supplied, and exports it as TEAM_ID for the later steps.
3. Checks that the app record exists. Apple's API cannot create one, so if
   it is missing this stops with instructions instead of failing ten minutes
   later at upload.

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (the .p8 file), and
optionally APPLE_TEAM_ID, BUNDLE_ID, APP_NAME.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt  # PyJWT, with the cryptography extra for ES256

API = os.environ.get("ASC_API_BASE", "https://api.appstoreconnect.apple.com")
BUNDLE_ID = os.environ.get("BUNDLE_ID", "com.z19r.tihole")
APP_NAME = os.environ.get("APP_NAME", "tihole")


def fail(message):
    print(f"::error::{message}")
    sys.exit(1)


def make_token():
    with open(os.environ["ASC_KEY_PATH"]) as handle:
        private_key = handle.read()
    now = int(time.time())
    return jwt.encode(
        {
            "iss": os.environ["ASC_ISSUER_ID"],
            "iat": now,
            "exp": now + 600,
            "aud": "appstoreconnect-v1",
        },
        private_key,
        algorithm="ES256",
        headers={"kid": os.environ["ASC_KEY_ID"]},
    )


def call(token, method, path, body=None):
    """Returns (status, parsed JSON body). Never prints the token."""
    request = urllib.request.Request(API + path, method=method)
    request.add_header("Authorization", "Bearer " + token)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, data=data, timeout=60) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            return error.code, json.loads(raw)
        except ValueError:
            return error.code, {"errors": [{"detail": raw.decode(errors="replace")[:500]}]}


def describe(payload):
    errors = payload.get("errors") or []
    return "; ".join(e.get("detail") or e.get("title") or "unknown error" for e in errors) or "no detail"


def find_bundle(token):
    query = urllib.parse.urlencode({"filter[identifier]": BUNDLE_ID, "limit": 200})
    status, payload = call(token, "GET", "/v1/bundleIds?" + query)
    if status == 401:
        fail(
            "App Store Connect rejected the API key (401). Check that ASC_KEY_ID, "
            "ASC_ISSUER_ID, and ASC_PRIVATE_KEY belong to the same key."
        )
    if status != 200:
        fail(f"Could not list bundle ids ({status}): {describe(payload)}")
    # The filter also matches longer identifiers, so insist on an exact one.
    for item in payload.get("data", []):
        if item.get("attributes", {}).get("identifier") == BUNDLE_ID:
            return item
    return None


def register_bundle(token):
    status, payload = call(
        token,
        "POST",
        "/v1/bundleIds",
        {
            "data": {
                "type": "bundleIds",
                "attributes": {"identifier": BUNDLE_ID, "name": APP_NAME, "platform": "IOS"},
            }
        },
    )
    if status not in (200, 201):
        fail(f"Could not register bundle id {BUNDLE_ID} ({status}): {describe(payload)}")
    return payload["data"]


def app_exists(token):
    query = urllib.parse.urlencode({"filter[bundleId]": BUNDLE_ID})
    status, payload = call(token, "GET", "/v1/apps?" + query)
    if status != 200:
        fail(f"Could not look up the app record ({status}): {describe(payload)}")
    return any(
        item.get("attributes", {}).get("bundleId") == BUNDLE_ID
        for item in payload.get("data", [])
    )


def export(name, value):
    path = os.environ.get("GITHUB_ENV")
    if path:
        with open(path, "a") as handle:
            handle.write(f"{name}={value}\n")


def main():
    token = make_token()

    bundle = find_bundle(token)
    if bundle is None:
        print(f"Bundle id {BUNDLE_ID} is not registered yet; registering it.")
        bundle = register_bundle(token)
    else:
        print(f"Bundle id {BUNDLE_ID} is registered.")

    team_id = os.environ.get("APPLE_TEAM_ID", "").strip()
    if not team_id:
        team_id = (bundle.get("attributes", {}).get("seedId") or "").strip()
    if not team_id:
        fail("Could not work out the team id. Add it as the APPLE_TEAM_ID repository secret.")
    print(f"::add-mask::{team_id}")
    export("TEAM_ID", team_id)
    print("Team id resolved.")

    if not app_exists(token):
        fail(
            f"There is no app record for {BUNDLE_ID} yet, and Apple's API cannot create one. "
            "In App Store Connect open Apps, tap +, choose New App, pick iOS and the bundle id "
            f"{BUNDLE_ID}, then run this workflow again."
        )
    print("App record exists.")


if __name__ == "__main__":
    main()
