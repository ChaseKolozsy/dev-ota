#!/usr/bin/env python3
"""Repeatable UI checks for the isolated Vim notification fixture APK.

All taps resolve actual UI nodes. Artifacts include screenshots, UI XML and
the local fixture oracle. Uses only the explicitly selected emulator.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time
import urllib.request
import xml.etree.ElementTree as ET

PARSER = argparse.ArgumentParser()
PARSER.add_argument("mode", choices=["inspect", "tap", "expand", "verify", "reader"])
PARSER.add_argument("label", nargs="?")
PARSER.add_argument("--serial", default="emulator-5554")
PARSER.add_argument("--output", default="/tmp/devota-terminal-notification-evidence")
PARSER.add_argument("--start-window", type=int, choices=[1, 2, 3], default=1)
ARGS = PARSER.parse_args()
if not ARGS.serial.startswith("emulator-"):
    raise SystemExit("This fixture is emulator-only")
OUT = Path(ARGS.output)
OUT.mkdir(parents=True, exist_ok=True)


def adb(*args):
    return subprocess.check_output(["adb", "-s", ARGS.serial, *args], text=True)


def tree():
    adb("shell", "uiautomator", "dump", "/sdcard/devota-terminal-test.xml")
    text = adb("shell", "cat", "/sdcard/devota-terminal-test.xml")
    return ET.fromstring(text)


def label(node):
    return node.get("text") or node.get("content-desc") or ""


def tap_node(node):
    coords = [int(n) for n in re.findall(r"\d+", node.get("bounds", ""))]
    if len(coords) != 4:
        raise AssertionError("Missing tap bounds")
    adb("shell", "input", "tap", str((coords[0] + coords[2]) // 2), str((coords[1] + coords[3]) // 2))


def tap(text, root=None):
    root = tree() if root is None else root
    matches = [n for n in root.iter("node") if label(n).lower() == text.lower()]
    if len(matches) != 1:
        raise AssertionError(f"Expected one {text!r}, got {len(matches)}")
    tap_node(matches[0])


def expand(text, only_collapse=False):
    root = tree()
    parents = {child: parent for parent in root.iter() for child in parent}
    node = next(n for n in root.iter("node") if text in label(n))
    while node in parents:
        buttons = [n for n in node.iter("node") if n.get("resource-id") == "android:id/expand_button"]
        if buttons:
            if not only_collapse or label(buttons[0]) == "Collapse":
                tap_node(buttons[0])
            return
        node = parents[node]
    raise AssertionError(f"No expand button for {text}")


def oracle():
    return json.load(urllib.request.urlopen("http://127.0.0.1:22223/", timeout=5))


def capture(name):
    root = tree()
    ET.ElementTree(root).write(OUT / f"{name}.xml", encoding="utf-8")
    adb("shell", "screencap", "-p", "/sdcard/devota-terminal-test.png")
    adb("pull", "/sdcard/devota-terminal-test.png", str(OUT / f"{name}.png"))
    (OUT / f"{name}.json").write_text(json.dumps(oracle(), indent=2))
    activity = adb("shell", "dumpsys", "activity", "activities")
    resumed = [line.strip() for line in activity.splitlines() if "ResumedActivity" in line]
    (OUT / f"{name}-activity.txt").write_text("\n".join(resumed))
    return root


def wait_file(index, expected, timeout=20):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if oracle()["files"][str(index)] == expected:
            return
        time.sleep(0.5)
    raise AssertionError(f"Window {index} contents: {oracle()['files']}")


def show_action(index, text):
    for other in (1, 2, 3):
        if other == index:
            continue
        try:
            expand(f"notification-test:{other}.0", only_collapse=True)
        except (StopIteration, AssertionError):
            pass
    until = time.monotonic() + 25
    while time.monotonic() < until:
        root = tree()
        if any(label(n).lower() == text.lower() for n in root.iter("node")):
            return root
        title = f"notification-test:{index}.0"
        if any(title in label(n) for n in root.iter("node")):
            expand(title)
        else:
            expand("DevOTA terminal")
        time.sleep(0.5)
    raise AssertionError(f"Action {text} not visible")


if ARGS.mode == "inspect":
    for n in capture("inspect").iter("node"):
        if label(n):
            print(label(n), n.get("resource-id"), n.get("bounds"))
elif ARGS.mode == "tap":
    tap(ARGS.label)
elif ARGS.mode == "expand":
    expand(ARGS.label)
elif ARGS.mode == "reader":
    urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:22223/reading-fixture", method="POST"), timeout=5).close()
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    adb("shell", "cmd", "statusbar", "expand-notifications")
    tap("Listen", show_action(1, "Listen"))
    def speaking():
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            root = tree()
            if any(label(n) == 'Speaking conclusion' for n in root.iter('node')):
                return root
            time.sleep(0.5)
        raise AssertionError('Android TTS did not report starting playback')
    speaking()
    capture('reader-speaking')
    tap('Earlier')
    speaking()
    capture('reader-earlier')
    tap('Replay')
    speaking()
    tap('Stop')
    root = capture('reader-stopped')
    assert not any(label(n).startswith('Listen ·') for n in root.iter('node'))
    resumed = [line for line in adb('shell', 'dumpsys', 'activity', 'activities').splitlines() if 'ResumedActivity' in line]
    assert resumed and all('terminaltest' not in line for line in resumed), resumed
    (OUT / 'reader-result.json').write_text(json.dumps({'passed': True, 'checks': [
        'Offline Android TTS onStart callback', 'Earlier action restarts playback',
        'Replay action', 'Stop removes playback controls', 'App remains backgrounded'],
        'limits': 'Engine callbacks and UI verified; no subjective listening or physical phone test.'}, indent=2))
    print(f'PASS: reader notification controls; evidence: {OUT}')
else:
    assert adb("shell", "getprop", "ro.build.version.sdk").strip() == "36"
    assert "1080x2436" in adb("shell", "wm", "size")
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    adb("shell", "cmd", "statusbar", "expand-notifications")
    for index in (1, 2):
        if index < ARGS.start_window:
            assert oracle()["files"][str(index)] == f"fixture\nhello {index}\n"
            continue
        tap(f"Hello {index}", show_action(index, f"Hello {index}"))
        wait_file(index, f"fixture\nhello {index}\n")
        capture(f"window-{index}-submitted")
        resumed = [line for line in adb("shell", "dumpsys", "activity", "activities").splitlines() if "ResumedActivity" in line]
        assert resumed and all("terminaltest" not in line for line in resumed), resumed
    request = urllib.request.Request("http://127.0.0.1:22223/drop-second-enter", method="POST")
    urllib.request.urlopen(request, timeout=5).close()
    tap("Hello 3", show_action(3, "Hello 3"))
    until = time.monotonic() + 20
    while time.monotonic() < until and oracle()["counts"]["enterDropped"] != 1:
        time.sleep(0.5)
    assert oracle()["counts"]["enterDropped"] == 1
    assert oracle()["files"]["3"] is None
    capture("window-3-enter-dropped")
    # Expand window 3 and pick its recovery action, even when other windows
    # also have Send Enter buttons visible.
    show_action(3, "Hello 3")
    root = tree()
    parents = {child: parent for parent in root.iter() for child in parent}
    node = next(n for n in root.iter("node") if "notification-test:3.0" in label(n))
    while node in parents:
        matches = [n for n in node.iter("node") if label(n).lower() == "send enter"]
        if matches:
            assert any("submission unconfirmed" in label(n) for n in node.iter("node"))
            tap_node(matches[0])
            break
        node = parents[node]
    else:
        raise AssertionError("Window 3 recovery action missing")
    wait_file(3, "fixture\nhello 3\n")
    capture("window-3-enter-recovered")
    result = oracle()
    assert result["counts"]["enterSent"] == 6, result
    assert result["counts"]["enterDropped"] == 1, result
    urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:22223/disconnect", method="POST"), timeout=5).close()
    time.sleep(3)
    root = capture("disconnected")
    assert not any(label(n).lower() in ("hello 1", "hello 2", "hello 3", "send enter") for n in root.iter("node"))
    (OUT / "result.json").write_text(json.dumps({"passed": True, "checks": [
        "Three independent Vim panes", "Notification actions while app backgrounded",
        "Two normal submissions", "Dropped Enter leaves submission unconfirmed",
        "Pane-specific Enter recovery", "No duplicate submissions", "Disconnected actions removed"],
        "oracle": result}, indent=2))
    print(f"PASS: notification macros and Enter recovery; evidence: {OUT}")
