#!/usr/bin/env python3
"""Fills in the App Store listing from the metadata/ folder.

Usage: asc_metadata.py <metadata-dir>

Sets, on the editable App Store version and its LOCALE localization: the
description, promotional text, keywords, support and marketing URLs,
copyright, and the App Review notes. On the app info: subtitle, privacy
policy URL, the Utilities category, and an age rating with nothing to
declare. On the app: the
content rights declaration. If a processed build of the same version
exists, the newest one is selected for the version.

Text files are wrapped at 80 columns. Lines are joined with a space, except
that a blank line starts a new paragraph and a line starting with "•"
starts a new line. Keywords are one per line.

Environment: as for asc_screenshots.py.
"""

import pathlib
import sys
import urllib.parse

from asc_screenshots import LOCALE, api, editable_version, find_app
from asc_screenshots import localization as version_localization

LIMITS = {
    "description": 4000,
    "promotional_text": 170,
    "keywords": 100,
    "subtitle": 30,
    "copyright": 200,
    "review_notes": 4000,
}
NO_AGE_CONTENT = [
    "alcoholTobaccoOrDrugUseOrReferences",
    "contests",
    "gamblingSimulated",
    "gunsOrOtherWeapons",
    "horrorOrFearThemes",
    "matureOrSuggestiveThemes",
    "medicalOrTreatmentInformation",
    "profanityOrCrudeHumor",
    "sexualContentGraphicAndNudity",
    "sexualContentOrNudity",
    "violenceCartoonOrFantasy",
    "violenceRealistic",
    "violenceRealisticProlongedGraphicOrSadistic",
]
NO_AGE_FEATURES = [
    "advertising",
    "ageAssurance",
    "gambling",
    "healthOrWellnessTopics",
    "lootBox",
    "messagingAndChat",
    "parentalControls",
    "socialMedia",
    "unrestrictedWebAccess",
    "userGeneratedContent",
]
EDITABLE_INFO = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED"}


def reflow(text):
    paragraphs = []
    for block in text.strip().split("\n\n"):
        lines = []
        for raw in block.splitlines():
            raw = raw.strip()
            if lines and not raw.startswith("•"):
                lines[-1] += " " + raw
            else:
                lines.append(raw)
        paragraphs.append("\n".join(lines))
    return "\n\n".join(paragraphs)


def read(folder, name):
    path = folder / f"{name}.txt"
    if name == "keywords":
        value = ",".join(path.read_text().split("\n")).strip(",")
    else:
        value = reflow(path.read_text())
    if len(value) > LIMITS.get(name, 255):
        sys.exit(
            f"{path} is {len(value)} characters; the limit is "
            f"{LIMITS.get(name, 255)}"
        )
    return value


def patch(kind, item_id, attributes=None, relationships=None):
    data = {"type": kind, "id": item_id}
    if attributes:
        data["attributes"] = attributes
    if relationships:
        data["relationships"] = relationships
    api("PATCH", f"/v1/{kind}/{item_id}", {"data": data})


def app_info(app_id):
    infos = api("GET", f"/v1/apps/{app_id}/appInfos")["data"]
    for info in infos:
        attributes = info["attributes"]
        states = {attributes.get("state"), attributes.get("appStoreState")}
        if states & EDITABLE_INFO:
            return info["id"]
    return infos[0]["id"]


def info_localization(info_id):
    items = api("GET", f"/v1/appInfos/{info_id}/appInfoLocalizations")["data"]
    for item in items:
        if item["attributes"].get("locale") == LOCALE:
            return item["id"]
    return items[0]["id"]


def newest_build(app_id, version):
    query = urllib.parse.urlencode(
        {
            "filter[app]": app_id,
            "filter[preReleaseVersion.version]": version,
            "filter[processingState]": "VALID",
            "sort": "-uploadedDate",
            "limit": 1,
        }
    )
    builds = api("GET", "/v1/builds?" + query)["data"]
    return builds[0] if builds else None


def main(folder):
    text = folder / LOCALE
    app_id = find_app()
    version_id = editable_version(app_id)

    patch(
        "appStoreVersionLocalizations",
        version_localization(version_id),
        {
            "description": read(text, "description"),
            "promotionalText": read(text, "promotional_text"),
            "keywords": read(text, "keywords"),
            "supportUrl": read(text, "support_url"),
            "marketingUrl": read(text, "marketing_url"),
        },
    )
    print("Set the description, promotional text, keywords and URLs.")

    patch(
        "appStoreVersions",
        version_id,
        {"copyright": read(folder, "copyright")},
    )
    print("Set the copyright.")

    # The review detail holds the contact details, which are filled in by
    # hand in App Store Connect; only the notes come from the repo.
    detail = api(
        "GET", f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail"
    )["data"]
    if not detail:
        sys.exit("Fill in App Review Information in App Store Connect first.")
    patch(
        "appStoreReviewDetails",
        detail["id"],
        {"notes": read(text, "review_notes"), "demoAccountRequired": False},
    )
    print("Set the App Review notes.")

    info_id = app_info(app_id)
    patch(
        "appInfoLocalizations",
        info_localization(info_id),
        {
            "subtitle": read(text, "subtitle"),
            "privacyPolicyUrl": read(text, "privacy_url"),
        },
    )
    patch(
        "appInfos",
        info_id,
        relationships={
            "primaryCategory": {
                "data": {"type": "appCategories", "id": "UTILITIES"}
            }
        },
    )
    print("Set the subtitle, privacy policy URL and category.")

    rating = api("GET", f"/v1/appInfos/{info_id}/ageRatingDeclaration")
    patch(
        "ageRatingDeclarations",
        rating["data"]["id"],
        {
            **{key: "NONE" for key in NO_AGE_CONTENT},
            **{key: False for key in NO_AGE_FEATURES},
        },
    )
    print("Set the age rating.")

    patch(
        "apps",
        app_id,
        {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"},
    )
    print("Set the content rights declaration.")

    version = api("GET", f"/v1/appStoreVersions/{version_id}")["data"]
    number = version["attributes"]["versionString"]
    build = newest_build(app_id, number)
    if build:
        patch(
            "appStoreVersions",
            version_id,
            relationships={
                "build": {"data": {"type": "builds", "id": build["id"]}}
            },
        )
        print(f"Selected build {build['attributes']['version']}.")
    else:
        print(f"No processed {number} build yet; build left as it is.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(pathlib.Path(sys.argv[1]))
