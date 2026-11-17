#!/usr/bin/env python3
"""Prints the UDID of an available iPhone simulator on the newest iOS runtime.

CI images rename their simulators with every Xcode release, so the UI test
picks one at run time instead of naming a device.
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
    # "iPhone 17 Pro Max", "iPhone 16 Plus", "iPhone SE", "iPhone Air", "iPhone 16e"
    return any(tag in name for tag in ("Max", "Plus", "SE", "Air")) or re.search(r"\de$", name) is not None


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

    for _, name in runtimes:
        phones = [d for d in devices[name] if d["name"].startswith("iPhone")]
        # Prefer a plain model over Pro Max / Plus / SE so layouts are tested
        # at the common size.
        phones.sort(key=lambda d: (is_variant(d["name"]), d["name"]))
        if phones:
            print(phones[0]["udid"])
            return 0

    print("no available iPhone simulator found", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
