"""Local WSL smoke-test adapter; run real Windows shell with piped stdin.

Python owns the WSL interop process because Dart Process's pipe inheritance
does not reliably work with Windows executables launched from Linux.
"""
import json
import subprocess
import sys
import tempfile
from pathlib import Path

shell, command = sys.argv[1:]
if shell not in ('cmd.exe', 'powershell.exe'):
    raise SystemExit('Unsupported shell')
with tempfile.TemporaryDirectory(prefix='devota-wsl-probe-', dir='/mnt/c/Windows/Temp') as directory:
    # WSL interop escapes quotes while constructing Windows argv for /c. A
    # batch file gives CMD the original command string, like Windows sshd does.
    batch = Path(directory) / 'probe.cmd'
    batch.write_bytes(('@echo off\r\n' + command + '\r\n').encode('ascii'))
    windows_path = subprocess.check_output(['wslpath', '-w', str(batch)], text=True).strip()
    args = ['/d', '/c', windows_path] if shell == 'cmd.exe' else ['-NoProfile', '-NonInteractive', '-Command', command]
    result = subprocess.run([shell, *args], input=sys.stdin.buffer.read(),
                            cwd='/mnt/c', capture_output=True, timeout=30)
    print(json.dumps({'code': result.returncode, 'out': result.stdout.decode('utf-8', errors='replace'),
                      'err': result.stderr.decode('utf-8', errors='replace')}))
