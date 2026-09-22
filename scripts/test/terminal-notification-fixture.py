#!/usr/bin/env python3
"""Loopback-only SSH fixture. Run with uv run --with paramiko this_file.py.

Owns one temporary tmux server and three Vim windows; cleanup kills only that
server. The HTTP oracle exposes test results and an explicit dropped-Enter
fault, never production sessions. No agent, model, or credentials are used.
"""
import json
from pathlib import Path
import re
import signal
import socket
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import paramiko

ROOT = Path(tempfile.mkdtemp(prefix="devota-terminal-notification-"))
TMUX = ["tmux", "-S", str(ROOT / "tmux.sock"), "-f", "/dev/null"]
LOCK = threading.Lock()
COUNTS = {"commands": 0, "enterSent": 0, "enterDropped": 0}
DROP_COUNTDOWN = 0
FAIL_DISCOVERY = False
CHANNELS = []


def tmux(*args):
    return subprocess.check_output([*TMUX, *args], text=True)


def execute(channel, raw):
    global DROP_COUNTDOWN
    command = raw.decode()
    if FAIL_DISCOVERY and command.startswith('tmux list-panes'):
        channel.sendall_stderr(b'tmux: command not found (injected setup failure)\n')
        channel.send_exit_status(127)
        channel.close()
        return
    # Only the test controller's tmux and paste-buffer command grammar is used.
    # SSH listener is loopback-only and accepts fixture credentials exclusively.
    with LOCK:
        COUNTS["commands"] += 1
        if re.search(r"send-keys -H -t '%\d+' d$", command):
            if DROP_COUNTDOWN:
                DROP_COUNTDOWN -= 1
                if DROP_COUNTDOWN == 0:
                    COUNTS["enterDropped"] += 1
                    channel.send_exit_status(0)
                    channel.close()
                    return
            COUNTS["enterSent"] += 1
    import shlex
    command = re.sub(r"\btmux(?= )", shlex.join(TMUX), command)
    try:
        result = subprocess.run(command, shell=True, capture_output=True, timeout=8)
        if result.returncode:
            print(json.dumps({"failure": result.returncode, "stderr": result.stderr.decode(), "command": command}), flush=True)
        if result.stdout:
            channel.sendall(result.stdout)
        if result.stderr:
            channel.sendall_stderr(result.stderr)
        channel.send_exit_status(result.returncode)
    except Exception as error:
        channel.sendall_stderr(str(error).encode())
        channel.send_exit_status(1)
    finally:
        channel.close()


class Server(paramiko.ServerInterface):
    def check_channel_pty_request(self, channel, *args):
        return True

    def check_channel_window_change_request(self, channel, *args):
        return True

    def check_channel_shell_request(self, channel):
        threading.Timer(0.05, channel.sendall, args=(b'Isolated SSH setup fixture. No agent is running.\r\n',)).start()
        return True

    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if (username, password) == ("fixture", "fixture-only") else paramiko.AUTH_FAILED

    def get_allowed_auths(self, username):
        return "password"

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_exec_request(self, channel, command):
        # Return CHANNEL_SUCCESS before a fast command can close its channel.
        threading.Timer(0.05, execute, args=(channel, command)).start()
        return True


KEY = paramiko.RSAKey.generate(2048)


def connection(sock):
    transport = paramiko.Transport(sock)
    CHANNELS.append(transport)
    transport.add_server_key(KEY)
    transport.start_server(server=Server())
    while transport.is_active():
        channel = transport.accept(1)
        if channel is not None:
            CHANNELS.append(channel)


class Oracle(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        result = {"directory": str(ROOT), "counts": COUNTS,
                  "files": {str(i): (ROOT / f"window{i}.txt").read_text() if (ROOT / f"window{i}.txt").exists() else None for i in range(1, 4)},
                  "panes": tmux("list-panes", "-a", "-F", "#{pane_id}:#{window_index}").splitlines()}
        body = json.dumps(result).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        global DROP_COUNTDOWN, FAIL_DISCOVERY
        if self.path == "/drop-second-enter":
            DROP_COUNTDOWN = 2
        elif self.path == '/fail-discovery':
            FAIL_DISCOVERY = True
        elif self.path == '/restore-discovery':
            FAIL_DISCOVERY = False
        elif self.path == "/disconnect":
            for channel in list(CHANNELS):
                channel.close()
        elif self.path == "/reading-fixture":
            pane = tmux('list-panes', '-a', '-F', '#{pane_id}').splitlines()[0]
            tmux('send-keys', '-t', pane, '-l', ':set nomore')
            tmux('send-keys', '-t', pane, 'Enter')
            # Real terminal history, not an agent invocation. Enough paragraphs
            # to exercise starting near the end and moving the reading cursor.
            tmux('send-keys', '-t', pane, '-l', ':for i in range(1, 40) | echo "Paragraph " . i . ". The synthetic check is complete. All sample checks passed. This is a read aloud fixture." | endfor')
            tmux('send-keys', '-t', pane, 'Enter')
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()


def cleanup(*_):
    subprocess.run([*TMUX, "kill-server"], capture_output=True)
    raise SystemExit(0)


if __name__ == "__main__":
    import shlex
    for i in range(1, 4):
        cmd = shlex.join(["vim", "-e", "-Nu", "NONE", "-n", "-i", "NONE", "-c",
                          "set noshowmode noruler laststatus=0", "-c", "call setline(1, 'fixture')", str(ROOT / f"window{i}.txt")])
        if i == 1:
            tmux("new-session", "-d", "-s", "notification-test", "-x", "80", "-y", "24", cmd)
            tmux("move-window", "-s", "notification-test:0", "-t", "notification-test:1")
        else:
            tmux("new-window", "-t", f"notification-test:{i}", cmd)
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", 22223), Oracle).serve_forever, daemon=True).start()
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 22222))
    listener.listen()
    print(json.dumps({"ssh": 22222, "oracle": 22223, "directory": str(ROOT)}), flush=True)
    while True:
        sock, _ = listener.accept()
        threading.Thread(target=connection, args=(sock,), daemon=True).start()
