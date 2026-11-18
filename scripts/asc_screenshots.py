#!/usr/bin/env python3
"""Uploads App Store screenshots to the app's editable App Store version.

Usage: asc_screenshots.py <frames-dir>

<frames-dir> holds iphone/ and ipad/, each with PNGs named so they sort in
display order (store_frames.py writes them that way). For each device the
matching screenshot set of the version's localization is emptied and
refilled, so running this again replaces the screenshots instead of adding
to them.

If <frames-dir>/header/header.png exists, it goes to the app's Asset Library
and becomes the version's product page header and search results asset,
replacing whatever held those places.

If no version can be edited, one is created for MARKETING_VERSION in
project.yml.

Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH, and optionally
BUNDLE_ID and LOCALE (default en-US).
"""

import hashlib
import os
import pathlib
import re
import sys
import time
import urllib.parse
import urllib.request

from asc_prepare import BUNDLE_ID, call, describe, fail, make_token

LOCALE = os.environ.get("LOCALE", "en-US")
DISPLAY_TYPES = {
    "iphone": "APP_IPHONE_67",
    "ipad": "APP_IPAD_PRO_3GEN_129",
}
EDITABLE = {
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
}


def api(method, path, body=None, ok=(200, 201, 204)):
    # A fresh token per call: the upload can outlast one token's 10 minutes.
    status, payload = call(make_token(), method, path, body)
    if status not in ok:
        fail(
            f"{method} {path.split('?')[0]} failed ({status}): "
            + describe(payload)
        )
    return payload


def marketing_version():
    root = pathlib.Path(__file__).resolve().parent.parent
    match = re.search(
        r'MARKETING_VERSION:\s*"?([\d.]+)', (root / "project.yml").read_text()
    )
    if not match:
        fail("MARKETING_VERSION not found in project.yml")
    return match.group(1)


def find_app():
    query = urllib.parse.urlencode({"filter[bundleId]": BUNDLE_ID})
    apps = api("GET", "/v1/apps?" + query)["data"]
    for app in apps:
        if app["attributes"].get("bundleId") == BUNDLE_ID:
            return app["id"]
    fail(f"no app record for {BUNDLE_ID}")


def editable_version(app_id):
    query = urllib.parse.urlencode({"filter[platform]": "IOS", "limit": 50})
    versions = api("GET", f"/v1/apps/{app_id}/appStoreVersions?{query}")["data"]
    for version in versions:
        attributes = version["attributes"]
        states = {
            attributes.get("appStoreState"),
            attributes.get("appVersionState"),
        }
        if states & EDITABLE:
            print(f"Using version {attributes.get('versionString')}.")
            return version["id"]
    number = marketing_version()
    print(f"No editable version; creating {number}.")
    created = api(
        "POST",
        "/v1/appStoreVersions",
        {
            "data": {
                "type": "appStoreVersions",
                "attributes": {"platform": "IOS", "versionString": number},
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}}
                },
            }
        },
    )
    return created["data"]["id"]


def localization(version_id):
    path = f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
    items = api("GET", path)["data"]
    for item in items:
        if item["attributes"].get("locale") == LOCALE:
            return item["id"]
    if not items:
        fail("the version has no localization")
    print(
        f"No {LOCALE} localization; using "
        f"{items[0]['attributes'].get('locale')}."
    )
    return items[0]["id"]


def screenshot_set(localization_id, display_type):
    path = (
        f"/v1/appStoreVersionLocalizations/{localization_id}"
        "/appScreenshotSets?limit=50"
    )
    for item in api("GET", path)["data"]:
        if item["attributes"].get("screenshotDisplayType") == display_type:
            return item["id"]
    created = api(
        "POST",
        "/v1/appScreenshotSets",
        {
            "data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": display_type},
                "relationships": {
                    "appStoreVersionLocalization": {
                        "data": {
                            "type": "appStoreVersionLocalizations",
                            "id": localization_id,
                        }
                    }
                },
            }
        },
    )
    return created["data"]["id"]


def clear(set_id):
    existing = api(
        "GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots?limit=50"
    )["data"]
    for item in existing:
        api("DELETE", f"/v1/appScreenshots/{item['id']}")
    if existing:
        print(f"  removed {len(existing)} old screenshots")


HEADER_PLACEMENTS = (
    "PRODUCT_PAGE_HEADER_ASSET",
    "APP_STORE_SEARCH_RESULTS_ASSET",
)


def put_parts(operations, data):
    for op in operations:
        chunk = data[op["offset"] : op["offset"] + op["length"]]
        request = urllib.request.Request(
            op["url"], data=chunk, method=op["method"]
        )
        for header in op.get("requestHeaders", []):
            request.add_header(header["name"], header["value"])
        with urllib.request.urlopen(request, timeout=120):
            pass


def upload_header(app_id, localization_id, path):
    library = api("GET", f"/v1/apps/{app_id}/assetLibrary")["data"]["id"]
    data = path.read_bytes()
    image = api(
        "POST",
        "/v1/appAssetLibraryImages",
        {
            "data": {
                "type": "appAssetLibraryImages",
                "attributes": {
                    "category": "CREATIVE_ASSETS",
                    "fileName": path.name,
                    "fileSize": len(data),
                },
                "relationships": {
                    "assetLibrary": {
                        "data": {"type": "appAssetLibraries", "id": library}
                    }
                },
            }
        },
    )["data"]
    put_parts(image["attributes"]["uploadOperations"], data)
    api(
        "PATCH",
        f"/v1/appAssetLibraryImages/{image['id']}",
        {
            "data": {
                "type": "appAssetLibraryImages",
                "id": image["id"],
                "attributes": {"uploaded": True},
            }
        },
    )
    for _ in range(60):
        attributes = api("GET", f"/v1/appAssetLibraryImages/{image['id']}")[
            "data"
        ]["attributes"]
        state = attributes.get("state")
        if state == "FAILED":
            fail(f"App Store Connect rejected {path.name}: {attributes}")
        if state not in ("AWAITING_UPLOAD", "UPLOAD_COMPLETE"):
            break
        time.sleep(5)
    else:
        fail(f"{path.name} was still processing after 5 minutes")
    print(f"  {path.name} is in the Asset Library ({state})")

    placed = api(
        "GET",
        f"/v1/appStoreVersionLocalizations/{localization_id}/placements",
    )["data"]
    for item in placed:
        if item["attributes"].get("placementType") in HEADER_PLACEMENTS:
            api("DELETE", f"/v1/appAssetLibraryPlacements/{item['id']}")
    for placement in HEADER_PLACEMENTS:
        api(
            "POST",
            "/v1/appAssetLibraryPlacements",
            {
                "data": {
                    "type": "appAssetLibraryPlacements",
                    "attributes": {"placementType": placement},
                    "relationships": {
                        "image": {
                            "data": {
                                "type": "appAssetLibraryImages",
                                "id": image["id"],
                            }
                        },
                        "appStoreVersionLocalization": {
                            "data": {
                                "type": "appStoreVersionLocalizations",
                                "id": localization_id,
                            }
                        },
                    },
                }
            },
        )
        print(f"  placed as {placement}")


def upload(set_id, path):
    data = path.read_bytes()
    reserved = api(
        "POST",
        "/v1/appScreenshots",
        {
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileName": path.name, "fileSize": len(data)},
                "relationships": {
                    "appScreenshotSet": {
                        "data": {"type": "appScreenshotSets", "id": set_id}
                    }
                },
            }
        },
    )["data"]
    put_parts(reserved["attributes"]["uploadOperations"], data)
    api(
        "PATCH",
        f"/v1/appScreenshots/{reserved['id']}",
        {
            "data": {
                "type": "appScreenshots",
                "id": reserved["id"],
                "attributes": {
                    "uploaded": True,
                    "sourceFileChecksum": hashlib.md5(data).hexdigest(),
                },
            }
        },
    )
    return reserved["id"]


def wait_until_processed(screenshot_id, name):
    for _ in range(60):
        state = api("GET", f"/v1/appScreenshots/{screenshot_id}")["data"][
            "attributes"
        ]
        delivery = state.get("assetDeliveryState") or {}
        if delivery.get("state") == "COMPLETE":
            return
        if delivery.get("state") == "FAILED":
            errors = "; ".join(
                e.get("description", "") for e in delivery.get("errors", [])
            )
            fail(f"App Store Connect rejected {name}: {errors or 'no detail'}")
        time.sleep(5)
    fail(f"{name} was still processing after 5 minutes")


def main(frames):
    app_id = find_app()
    version_id = editable_version(app_id)
    localization_id = localization(version_id)
    for device, display_type in DISPLAY_TYPES.items():
        files = sorted((frames / device).glob("*.png"))
        if not files:
            fail(f"no screenshots in {frames / device}")
        print(f"{device}: {len(files)} screenshots -> {display_type}")
        set_id = screenshot_set(localization_id, display_type)
        clear(set_id)
        for path in files:
            wait_until_processed(upload(set_id, path), path.name)
            print(f"  uploaded {path.name}")
    header = frames / "header" / "header.png"
    if header.exists():
        print("header and search results:")
        upload_header(app_id, localization_id, header)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(pathlib.Path(sys.argv[1]))
