#!/usr/bin/env python3
"""Emulator-only Cradlespeak lexical UX exploration with durable UI evidence.

No data clearing. Taps resolve live accessibility nodes, never guessed bounds.
Use --secret-file for session tokens; secret inputs aren't recorded or echoed.
"""
import argparse
from pathlib import Path
import re
import subprocess
import time
import xml.etree.ElementTree as ET

p = argparse.ArgumentParser()
p.add_argument('action', choices=['inspect', 'tap', 'type', 'back', 'scroll', 'open', 'reveal'])
p.add_argument('value', nargs='?', default='')
p.add_argument('--serial', required=True)
p.add_argument('--output', required=True)
p.add_argument('--name', default='frame')
p.add_argument('--secret-file')
p.add_argument('--scroll-class', help='Exact accessibility class when several scrollers exist')
a = p.parse_args()
if not a.serial.startswith('emulator-'):
    p.error('This driver is emulator-only')
out = Path(a.output)
out.mkdir(parents=True, exist_ok=True)
adb_path = '/home/chase/Android/Sdk/platform-tools/adb'

def adb(*args):
    return subprocess.check_output([adb_path, '-s', a.serial, *args])

def tree():
    result = adb('shell', 'uiautomator', 'dump', '/sdcard/devota-lexical.xml')
    if b'dumped to:' not in result:
        raise SystemExit('Fresh UI dump unavailable; refusing stale coordinates')
    return ET.fromstring(adb('shell', 'cat', '/sdcard/devota-lexical.xml'))

def label(n):
    return n.get('text') or n.get('content-desc') or ''

def bounds(n):
    return list(map(int, re.findall(r'\d+', n.get('bounds', ''))))

def scrollers(root):
    return [n for n in root.iter('node') if n.get('scrollable') == 'true'
            and (not a.scroll_class or n.get('class') == a.scroll_class)]

if a.action == 'tap':
    nodes = [n for n in tree().iter('node') if label(n) == a.value]
    if len(nodes) != 1:
        raise SystemExit(f'Expected one matching node; got {len(nodes)}')
    x1, y1, x2, y2 = bounds(nodes[0])
    adb('shell', 'input', 'tap', str((x1+x2)//2), str((y1+y2)//2))
elif a.action == 'type':
    value = Path(a.secret_file).read_text().strip() if a.secret_file else a.value
    # Shell-quote input since adb shell joins its arguments remotely.
    import shlex
    adb('shell', 'input', 'text', shlex.quote(value.replace(' ', '%s')))
elif a.action == 'back':
    adb('shell', 'input', 'keyevent', '4')
elif a.action == 'open':
    adb('shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', a.value,
        'io.github.chasekolozsy.cradlespeak')
elif a.action == 'reveal':
    for step in range(12):
        root = tree()
        (out / f'{a.name}-scroll-{step}.png').write_bytes(adb('exec-out', 'screencap', '-p'))
        ET.ElementTree(root).write(out / f'{a.name}-scroll-{step}.xml', encoding='utf-8')
        if any(a.value in label(n) for n in root.iter('node')):
            break
        nodes = scrollers(root)
        if len(nodes) != 1:
            raise SystemExit(f'Expected one scrollable node; got {len(nodes)}')
        x1, y1, x2, y2 = bounds(nodes[0])
        adb('shell', 'input', 'swipe', str((x1+x2)//2), str(y1+(y2-y1)*3//4),
            str((x1+x2)//2), str(y1+(y2-y1)//4), '400')
    else:
        raise SystemExit('Target not found in 12 bounded scrolls')
elif a.action == 'scroll':
    nodes = scrollers(tree())
    if len(nodes) != 1:
        raise SystemExit(f'Expected one scrollable node; got {len(nodes)}')
    x1, y1, x2, y2 = bounds(nodes[0])
    adb('shell', 'input', 'swipe', str((x1+x2)//2), str(y1+(y2-y1)*3//4),
        str((x1+x2)//2), str(y1+(y2-y1)//4), '400')
time.sleep(0.6)
if not a.secret_file:
    (out / f'{a.name}.png').write_bytes(adb('exec-out', 'screencap', '-p'))
    root = tree()
    ET.ElementTree(root).write(out / f'{a.name}.xml', encoding='utf-8')
    activity = adb('shell', 'dumpsys', 'activity', 'activities').decode()
    (out / f'{a.name}-activity.txt').write_text('\n'.join(
        line for line in activity.splitlines() if 'ResumedActivity' in line))
    for n in root.iter('node'):
        if label(n) and n.get('password') != 'true':
            print(repr(label(n)), n.get('bounds'))
