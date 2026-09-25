#!/usr/bin/env python3
"""Render a fixture-bound, read-only DevOTA macro for an observed phone profile."""

import argparse
import hashlib
import json
import re
from pathlib import Path
from urllib.parse import urlparse


PACKAGE = "io.github.chasekolozsy.cradlespeak"


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


def validate_profile(model, android_sdk, short_side_px, long_side_px, density_dpi):
    if not isinstance(model, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9 ._+-]{0,63}", model) or model != model.strip():
        raise ValueError("device model must be one exact printable Android model")
    for name, value, lower, upper in (
        ("Android SDK", android_sdk, 21, 50),
        ("short side", short_side_px, 320, 5000),
        ("long side", long_side_px, 320, 8000),
        ("density DPI", density_dpi, 120, 1000),
    ):
        if type(value) is not int or not lower <= value <= upper:
            raise ValueError(f"{name} must be an integer from {lower} to {upper}")
    if short_side_px > long_side_px:
        raise ValueError("short side cannot exceed long side")


def render(peer_url, book_id, book_title, occurrence_id, tap_description,
           lookup_text, *, model, android_sdk, short_side_px, long_side_px,
           density_dpi, sync_block_text, sync_now_text,
           choose_languages_text):
    validate_profile(model, android_sdk, short_side_px, long_side_px, density_dpi)
    parsed = urlparse(peer_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc or parsed.path not in {"", "/"} or parsed.query or parsed.fragment or parsed.username or parsed.password:
        raise ValueError("peer URL must be a bare HTTP(S) origin")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", book_id):
        raise ValueError("book ID must be a single safe route component")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,255}", occurrence_id):
        raise ValueError("occurrence ID must be an opaque printable identifier")
    for name, value in {"book title": book_title, "tap description": tap_description,
                        "lookup text": lookup_text,
                        "sync block text": sync_block_text,
                        "sync now text": sync_now_text,
                        "choose languages text": choose_languages_text}.items():
        if not value or len(value) > 300 or any(c in value for c in "\r\n"):
            raise ValueError(f"{name} must be one nonempty short line")
    peer_url = peer_url.rstrip("/")
    fixture_hash = hashlib.sha256(
        f"{peer_url}\0{book_id}\0{occurrence_id}\0{model}\0{android_sdk}\0"
        f"{short_side_px}\0{long_side_px}\0{density_dpi}\0{sync_block_text}\0"
        f"{sync_now_text}\0{choose_languages_text}\0{lookup_text}".encode()
    ).hexdigest()[:12]
    return {
        "id": f"cradle-arm64-phone-readonly-{fixture_hash}",
        "name": "Cradle ARM64 phone: CENC3 block and exact lookup (read only)",
        "priority": 2140,
        "steps": [
            device("assertDeviceProfile", "Match observed phone profile", args={
                "profile": f"observed-phone-{fixture_hash}",
                "models": [model], "androidSdk": android_sdk,
                "shortSidePx": short_side_px, "longSidePx": long_side_px,
                "densityDpi": density_dpi,
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
                       peer_url, sync_block_text, sync_now_text,
                       choose_languages_text,
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
    parser.add_argument("--device-model", required=True,
                        help="exact model from read-only android_status")
    parser.add_argument("--android-sdk", type=int, required=True)
    parser.add_argument("--short-side-px", type=int, required=True)
    parser.add_argument("--long-side-px", type=int, required=True)
    parser.add_argument("--density-dpi", type=int, required=True)
    parser.add_argument("--peer-url", required=True)
    parser.add_argument("--book-id", required=True)
    parser.add_argument("--book-title", required=True)
    parser.add_argument("--occurrence-id", required=True)
    parser.add_argument("--tap-description", required=True,
                        help="unique accessibility content description of the bound word")
    parser.add_argument("--sync-block-text", required=True,
                        help="exact visible localized full-sync incompatibility message")
    parser.add_argument("--sync-now-text", required=True,
                        help="exact visible localized label of the disabled full-sync button")
    parser.add_argument("--choose-languages-text", required=True,
                        help="exact visible localized label of the language picker")
    parser.add_argument("--lookup-text", required=True,
                        help="visible read-only lookup text expected for that occurrence")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    macro = render(args.peer_url, args.book_id, args.book_title,
                   args.occurrence_id, args.tap_description, args.lookup_text,
                   model=args.device_model, android_sdk=args.android_sdk,
                   short_side_px=args.short_side_px,
                   long_side_px=args.long_side_px, density_dpi=args.density_dpi,
                   sync_block_text=args.sync_block_text,
                   sync_now_text=args.sync_now_text,
                   choose_languages_text=args.choose_languages_text)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(macro, indent=2) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()
