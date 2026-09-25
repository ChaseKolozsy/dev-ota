#!/usr/bin/env python3
"""Bounded read-only ADB meminfo samples for a locally ADB-connected phone."""

import argparse
import json
import os
import re
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path


PACKAGE = "io.github.chasekolozsy.cradlespeak"


def adb(serial, *args):
    return subprocess.run(
        ["adb", "-s", serial, *args], capture_output=True, text=True,
        timeout=20, check=True,
    ).stdout


def pss_kib(meminfo):
    match = re.search(r"(?m)^\s*TOTAL PSS:\s*([0-9,]+)", meminfo)
    if not match:
        match = re.search(r"(?m)^\s*TOTAL\s+([0-9,]+)\s+", meminfo)
    return int(match.group(1).replace(",", "")) if match else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serial", required=True, help="exact ADB serial of the physical phone")
    parser.add_argument("--device-model", required=True,
                        help="exact model observed for the same phone")
    parser.add_argument("--android-sdk", type=int, required=True)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--duration-seconds", type=int, default=180)
    parser.add_argument("--interval-seconds", type=int, default=5)
    args = parser.parse_args()
    if not 5 <= args.duration_seconds <= 600 or not 2 <= args.interval_seconds <= 30:
        parser.error("duration must be 5–600 seconds and interval 2–30 seconds")
    if not args.device_model.strip() or args.device_model != args.device_model.strip() or not 21 <= args.android_sdk <= 50:
        parser.error("supply a valid exact model and Android SDK")
    model = adb(args.serial, "shell", "getprop", "ro.product.model").strip()
    sdk = adb(args.serial, "shell", "getprop", "ro.build.version.sdk").strip()
    if (model, sdk) != (args.device_model, str(args.android_sdk)):
        parser.error(f"ADB profile differs from the supplied phone model/SDK: got {model}/{sdk}")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(args.output_dir, 0o700)
    summary = args.output_dir / "meminfo-samples.jsonl"
    fd = os.open(summary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    deadline = time.monotonic() + args.duration_seconds
    count = 0
    with os.fdopen(fd, "w") as out:
        while True:
            count += 1
            stamp = datetime.now(timezone.utc).isoformat()
            raw = adb(args.serial, "shell", "dumpsys", "meminfo", PACKAGE)
            raw_name = f"meminfo-{count:03d}.txt"
            raw_path = args.output_dir / raw_name
            raw_fd = os.open(raw_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(raw_fd, "w") as raw_out:
                raw_out.write(raw)
            out.write(json.dumps({"time_utc": stamp, "model": model, "sdk": sdk,
                                  "package": PACKAGE, "pss_kib": pss_kib(raw),
                                  "raw_file": raw_name}) + "\n")
            out.flush()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            time.sleep(min(args.interval_seconds, remaining))
    print(summary)


if __name__ == "__main__":
    main()
