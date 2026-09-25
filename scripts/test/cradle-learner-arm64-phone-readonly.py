#!/usr/bin/env python3
"""Render a fixture-bound, read-only DevOTA macro for the physical API36 phone."""

import argparse
import hashlib
import json
import re
from pathlib import Path
from urllib.parse import urlparse


PACKAGE = "io.github.chasekolozsy.cradlespeak"
SYNC_BLOCK = (
    "Full sync cannot transfer this protected library to this phone yet."
)


def device(action, label, *, args=None, expect=None, capture=False, delay=0):
    value = {"action": action, "label": label, "capture": capture}
    if args is not None:
        value["args"] = args
    if expect is not None:
        value["expect"] = expect
    step = {"type": "device", "value": json.dumps(value, separators=(",", ":"))}
    if delay:
        step["delaySeconds"] = delay
    return step


def render(peer_url, book_id, book_title, occurrence_id, tap_description,
           lookup_text):
    parsed = urlparse(peer_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.path not in {"", "/"} or parsed.query or parsed.fragment or parsed.username or parsed.password:
        raise ValueError("peer URL must be a bare HTTP(S) origin")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", book_id):
        raise ValueError("book ID must be a single safe route component")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,255}", occurrence_id):
        raise ValueError("occurrence ID must be an opaque printable identifier")
    for name, value in {"book title": book_title, "tap description": tap_description,
                        "lookup text": lookup_text}.items():
        if not value or len(value) > 160 or any(c in value for c in "\r\n"):
            raise ValueError(f"{name} must be one nonempty short line")
    peer_url = peer_url.rstrip("/")
    fixture_hash = hashlib.sha256(
        f"{peer_url}\0{book_id}\0{occurrence_id}".encode()
    ).hexdigest()[:12]
    return {
        "id": f"cradle-arm64-phone-readonly-{fixture_hash}",
        "name": "Cradle ARM64 phone: CENC3 block and exact lookup (read only)",
        "priority": 2140,
        "steps": [
            device("assertDeviceProfile", "Physical REVVL7 Pro API36", args={
                "profile": "revvl7pro-physical-android36-1080x2436",
                "models": ["TMRV07P5G"], "androidSdk": 36,
                "shortSidePx": 1080, "longSidePx": 2436, "densityDpi": 480,
            }),
            device("launchApp", "Open signed Cradlespeak", args={
                "packageName": PACKAGE,
            }, expect={"activePackage": PACKAGE}, capture=True, delay=4),
            device("launchIntent", "Open saved peer management", args={
                "packageName": PACKAGE, "action": "android.intent.action.VIEW",
                "uri": "cradle:///sync",
            }, delay=8),
            device("assertUi", "CENC3 full-sync block; do not press Sync now",
                   expect={"activePackage": PACKAGE, "textIncludes": [
                       peer_url, SYNC_BLOCK, "Sync now",
                       "Choose languages instead",
                   ]}, capture=True),
            device("launchIntent", "Open existing owned book; no import", args={
                "packageName": PACKAGE, "action": "android.intent.action.VIEW",
                "uri": f"cradle:///native-gateway/book/{book_id}",
            }, delay=8),
            device("assertUi", "Reader visible before exact word tap",
                   expect={"activePackage": PACKAGE,
                           "textIncludes": [book_title, tap_description]},
                   capture=True),
            device("tapUi", f"Tap unique occurrence {occurrence_id}", args={
                "packageName": PACKAGE,
                "selector": {"contentDescriptionExact": tap_description},
            }, delay=4),
            device("assertUi", f"Contextual lookup for {occurrence_id}",
                   expect={"activePackage": PACKAGE,
                           "textIncludes": [lookup_text],
                           "textExcludes": ["Contextual lookup is unavailable"]},
                   capture=True),
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--peer-url", required=True)
    parser.add_argument("--book-id", required=True)
    parser.add_argument("--book-title", required=True)
    parser.add_argument("--occurrence-id", required=True)
    parser.add_argument("--tap-description", required=True,
                        help="unique accessibility content description of the bound word")
    parser.add_argument("--lookup-text", default="JEV first choice",
                        help="visible read-only lookup text expected for that occurrence")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    macro = render(args.peer_url, args.book_id, args.book_title,
                   args.occurrence_id, args.tap_description, args.lookup_text)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(macro, indent=2) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()
