#!/usr/bin/env python3
"""Prints the UDID of an available simulator on the newest iOS runtime.

CI images rename their simulators with every Xcode release, so the UI test
picks one at run time instead of naming a device.

With no argument it picks a plain iPhone. With a regular expression it picks
the first device whose name matches, e.g. "iPhone .* Pro Max" or
"iPad Pro 13".
"""

import json
import re
import subprocess
import sys


def runtime_version(identifier):
    # "com.apple.CoreSimulator.SimRuntime.iOS-26-5" -> (26, 5)
    match = re.search(r"iOS-(\d+)(?:-(\d+))?", identifier)
    if not match:
        return None
    return (int(match.group(1)), int(match.group(2) or 0))


def is_variant(name):
    # "iPhone 17 Pro Max", "iPhone 16 Plus", "iPhone SE", "iPhone Air",
    # "iPhone 16e", and the foldable "iPhone Duo", whose side tab bar the
    # smoke test is not written for.
    tags = ("Max", "Plus", "SE", "Air", "Duo")
    tagged = any(tag in name for tag in tags)
    return tagged or re.search(r"\de$", name) is not None


def main():
    listing = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    devices = json.loads(listing)["devices"]

    runtimes = [(runtime_version(name), name) for name in devices]
    runtimes = sorted((r for r in runtimes if r[0] is not None), reverse=True)

    pattern = sys.argv[1] if len(sys.argv) > 1 else None
    for _, name in runtimes:
        if pattern:
            matches = [
                d for d in devices[name] if re.search(pattern, d["name"])
            ]
        else:
            matches = [
                d for d in devices[name] if d["name"].startswith("iPhone")
            ]
            # Prefer a plain model over Pro Max / Plus / SE so layouts are
            # tested at the common size.
            matches.sort(key=lambda d: (is_variant(d["name"]), d["name"]))
        if matches:
            print(matches[0]["udid"])
            return 0

    wanted = pattern or "iPhone"
    print(f"no available simulator matches {wanted}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
