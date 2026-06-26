#!/usr/bin/env python3
"""Serve Android APK builds described by a devota.yaml manifest."""

from __future__ import annotations

import argparse
import base64
from email import policy
from email.parser import BytesParser
import gzip
import json
import os
import platform
import re
import shutil
import socket
import sqlite3
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, unquote, urlparse

try:
    import yaml
except ImportError:  # pragma: no cover - exercised by users without PyYAML.
    yaml = None

try:
    from zeroconf import ServiceInfo, Zeroconf
except ImportError:  # pragma: no cover - exercised by users without zeroconf.
    ServiceInfo = None
    Zeroconf = None

DEFAULT_MANIFEST_NAMES = ("devota.yaml", "devota.yml", "devota.json")
MDNS_TYPE = "_devota._tcp.local."
GZIP_LOCK = threading.Lock()
PUBLIC_KEY_TYPES = {
    "ssh-ed25519",
    "ssh-rsa",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
}
TERMINAL_UPLOAD_MAX_BYTES = 25 * 1024 * 1024
TERMINAL_UPLOAD_DEFAULT_NAME = "attachment.bin"
TERMINAL_UPLOAD_NAME_MAX_CHARS = 120
DEVOTA_CACHE_DIR_ENV = "DEVOTA_CACHE_DIR"
PROJECT_STATUSES = {"active", "paused", "completed", "archived"}
PHASE_STATUSES = {"not_started", "active", "waiting_client", "completed"}
CARD_STATUSES = {"todo", "doing", "waiting_client", "review", "done"}
COMMENT_AUTHOR_TYPES = {"me", "client", "system"}
MACRO_STEP_TYPES = {"shell", "terminalKey", "tmux", "wait"}
MACRO_STEP_DEFAULT_VALUES = {
    "shell": "",
    "terminalKey": "enter",
    "tmux": "c",
    "wait": "",
}
MACRO_STORE_FORMAT = "devota-terminal-macros"
MACRO_STORE_VERSION = 1
DEFAULT_PHASE_TEMPLATE = [
    "Discovery",
    "Design",
    "Build",
    "Review",
    "Launch",
]


class ManifestError(ValueError):
    pass


def is_relative_to(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def find_manifest(repo_root: Path, explicit: str | None) -> Path:
    if explicit:
        path = Path(explicit).expanduser()
        return path if path.is_absolute() else (repo_root / path)
    for name in DEFAULT_MANIFEST_NAMES:
        path = repo_root / name
        if path.is_file():
            return path
    raise ManifestError(
        f"No DevOTA manifest found in {repo_root}. Create devota.yaml or pass --manifest."
    )


def _resolve_manifest_path(repo_root: Path, value: str) -> Path:
    path = Path(value).expanduser()
    return path.resolve() if path.is_absolute() else (repo_root / path).resolve()


def _normalize_manifest_roots(data: dict[str, Any], repo_root: Path) -> dict[str, dict[str, Any]]:
    roots: dict[str, dict[str, Any]] = {
        "default": {
            "id": "default",
            "path": ".",
            "absolute": repo_root,
        }
    }
    raw_roots = data.get("roots", {})
    if raw_roots in (None, ""):
        return roots

    if isinstance(raw_roots, dict):
        items = raw_roots.items()
    elif isinstance(raw_roots, list):
        parsed = []
        for index, root in enumerate(raw_roots, start=1):
            if not isinstance(root, dict):
                raise ManifestError(f"roots[{index}] must be a mapping")
            root_id = str(root.get("id") or "").strip()
            root_path = str(root.get("path") or "").strip()
            if not root_id or not root_path:
                raise ManifestError(f"roots[{index}] must include id and path")
            parsed.append((root_id, root_path))
        items = parsed
    else:
        raise ManifestError("roots must be a mapping or list")

    for root_id, root_spec in items:
        root_id = str(root_id).strip()
        if not root_id:
            raise ManifestError("root id must not be empty")
        if isinstance(root_spec, dict):
            root_path = str(root_spec.get("path") or "").strip()
        else:
            root_path = str(root_spec).strip()
        if not root_path:
            raise ManifestError(f"root {root_id} must define a path")
        roots[root_id] = {
            "id": root_id,
            "path": root_path,
            "absolute": _resolve_manifest_path(repo_root, root_path),
        }
    return roots


def _resolve_app_root(
    app: dict[str, Any],
    roots: dict[str, dict[str, Any]],
    repo_root: Path,
    app_id: str,
) -> dict[str, Any]:
    root_ref = str(app.get("root") or app.get("repoRoot") or "default").strip()
    if root_ref in roots:
        return roots[root_ref]
    path = _resolve_manifest_path(repo_root, root_ref)
    return {
        "id": root_ref,
        "path": root_ref,
        "absolute": path,
    }


def load_manifest(path: Path, repo_root: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ManifestError(f"Manifest not found: {path}")
    raw = path.read_text(encoding="utf-8")
    if path.suffix.lower() == ".json":
        data = json.loads(raw)
    else:
        if yaml is None:
            raise ManifestError("PyYAML is required for devota.yaml. Install with: python3 -m pip install PyYAML")
        data = yaml.safe_load(raw)
    if not isinstance(data, dict):
        raise ManifestError("Manifest must be a mapping")

    apps = data.get("apps")
    if not isinstance(apps, list) or not apps:
        raise ManifestError("Manifest must define a non-empty apps list")

    roots = _normalize_manifest_roots(data, repo_root)
    normalized = []
    seen = set()
    for index, app in enumerate(apps, start=1):
        if not isinstance(app, dict):
            raise ManifestError(f"apps[{index}] must be a mapping")
        app_id = str(app.get("id") or "").strip()
        if not app_id:
            raise ManifestError(f"apps[{index}].id is required")
        if app_id in seen:
            raise ManifestError(f"duplicate app id: {app_id}")
        seen.add(app_id)
        app_root = _resolve_app_root(app, roots, repo_root, app_id)
        app_root_path = app_root["absolute"]

        build_dirs = app.get("buildDirs")
        if not isinstance(build_dirs, list) or not build_dirs:
            raise ManifestError(f"{app_id}.buildDirs must be a non-empty list")
        resolved_dirs = []
        for rel in build_dirs:
            rel_text = str(rel).strip()
            if not rel_text:
                continue
            target = _resolve_manifest_path(app_root_path, rel_text)
            if not is_relative_to(target, app_root_path):
                raise ManifestError(f"{app_id}.buildDirs entry escapes app root: {rel_text}")
            resolved_dirs.append({"relative": rel_text, "absolute": target})

        normalized.append({
            "id": app_id,
            "label": str(app.get("label") or app_id),
            "packageName": str(app.get("packageName") or ""),
            "notes": str(app.get("notes") or ""),
            "root": app_root,
            "buildDirs": resolved_dirs,
        })

    return {
        "version": data.get("version", 1),
        "roots": roots,
        "apps": normalized,
    }


def public_app(app: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": app["id"],
        "label": app["label"],
        "packageName": app["packageName"],
        "notes": app["notes"],
        "root": app["root"]["id"],
        "rootPath": str(app["root"]["absolute"]),
        "buildDirs": [entry["relative"] for entry in app["buildDirs"]],
    }


def gzip_cache_path(repo_root: Path, rel_path: str) -> Path:
    safe = rel_path.replace("/", "__").replace("\\", "__")
    return repo_root / ".devota-cache" / "gzip" / f"{safe}.gz"


def user_devota_cache_dir() -> Path:
    override = os.environ.get(DEVOTA_CACHE_DIR_ENV)
    if override:
        return Path(override).expanduser().resolve()
    return Path.home() / ".devota-cache"


def ensure_gz(repo_root: Path, apk_path: Path, rel_path: str) -> Path:
    gz_path = gzip_cache_path(repo_root, rel_path)
    gz_path.parent.mkdir(parents=True, exist_ok=True)
    apk_mtime = apk_path.stat().st_mtime
    if gz_path.exists() and gz_path.stat().st_mtime >= apk_mtime:
        return gz_path
    with GZIP_LOCK:
        if gz_path.exists() and gz_path.stat().st_mtime >= apk_mtime:
            return gz_path
        tmp_path = gz_path.with_suffix(f"{gz_path.suffix}.{os.getpid()}.tmp")
        try:
            with open(apk_path, "rb") as f_in, gzip.open(tmp_path, "wb") as f_out:
                while chunk := f_in.read(65536):
                    f_out.write(chunk)
            tmp_path.replace(gz_path)
        finally:
            if tmp_path.exists():
                tmp_path.unlink()
    return gz_path


def scan_apks(repo_root: Path, manifest: dict[str, Any], app_id: str | None = None) -> list[dict[str, Any]]:
    builds: list[dict[str, Any]] = []
    seen: set[Path] = set()
    for app in manifest["apps"]:
        if app_id and app["id"] != app_id:
            continue
        app_root = app["root"]["absolute"]
        for build_dir in app["buildDirs"]:
            apk_dir = build_dir["absolute"]
            if not apk_dir.is_dir():
                continue
            for apk in apk_dir.rglob("*.apk"):
                real = apk.resolve()
                if real in seen or not is_relative_to(real, app_root):
                    continue
                seen.add(real)
                stat = apk.stat()
                app_rel = apk.relative_to(app_root).as_posix()
                virtual_path = f"apps/{app['id']}/{app_rel}"
                gz = ensure_gz(repo_root, apk, virtual_path)
                gz_stat = gz.stat()
                builds.append({
                    "filename": apk.name,
                    "size": stat.st_size,
                    "compressed_size": gz_stat.st_size,
                    "modified": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(stat.st_mtime)),
                    "modifiedMs": int(stat.st_mtime * 1000),
                    "path": virtual_path,
                    "sourcePath": str(real),
                    "rootPath": str(app_root),
                    "appId": app["id"],
                    "appLabel": app["label"],
                    "packageName": app["packageName"],
                    "kind": app["id"],
                })
    allowed_app_ids = {app["id"] for app in manifest["apps"]}
    builds.extend(scan_github_artifact_apks(repo_root, app_id, allowed_app_ids))
    builds.sort(key=lambda item: item["modifiedMs"], reverse=True)
    return builds


def latest_apk(repo_root: Path, manifest: dict[str, Any], app_id: str | None = None) -> dict[str, Any] | None:
    builds = scan_apks(repo_root, manifest, app_id)
    return builds[0] if builds else None


def resolve_download_target(
    repo_root: Path,
    manifest: dict[str, Any],
    rel: str,
) -> tuple[Path, str]:
    normalized = rel.lstrip("/")
    if normalized.startswith("apps/"):
        parts = normalized.split("/", 2)
        if len(parts) != 3 or not parts[1] or not parts[2]:
            raise ValueError("download path must be apps/<app-id>/<path>")
        app_id = parts[1]
        app_rel = parts[2]
        app = next((item for item in manifest["apps"] if item["id"] == app_id), None)
        if app is None:
            raise FileNotFoundError(f"unknown app id: {app_id}")
        app_root = app["root"]["absolute"]
        target = (app_root / app_rel).resolve()
        if not is_relative_to(target, app_root):
            raise PermissionError("download path escapes app root")
        return target, f"apps/{app_id}/{app_rel}"

    # Backward-compatible path resolver for older clients/manifests.
    target = (repo_root / normalized).resolve()
    if not is_relative_to(target, repo_root):
        raise PermissionError("download path escapes repo root")
    return target, normalized


def github_artifact_metadata(_apk: Path) -> dict[str, str]:
    return {
        "appId": "devota",
        "appLabel": "DevOTA",
        "packageName": "io.github.chasekolozsy.devota",
    }


def scan_github_artifact_apks(
    repo_root: Path,
    app_id: str | None = None,
    allowed_app_ids: set[str] | None = None,
) -> list[dict[str, Any]]:
    root = repo_root / ".devota-cache" / "github-artifacts"
    if not root.is_dir():
        return []
    builds = []
    for apk in root.rglob("*.apk"):
        real = apk.resolve()
        if not is_relative_to(real, repo_root):
            continue
        stat = apk.stat()
        rel = apk.relative_to(repo_root).as_posix()
        metadata = github_artifact_metadata(apk)
        if allowed_app_ids is not None and metadata["appId"] not in allowed_app_ids:
            continue
        if app_id and metadata["appId"] != app_id:
            continue
        gz = ensure_gz(repo_root, apk, rel)
        gz_stat = gz.stat()
        builds.append({
            "filename": apk.name,
            "size": stat.st_size,
            "compressed_size": gz_stat.st_size,
            "modified": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(stat.st_mtime)),
            "modifiedMs": int(stat.st_mtime * 1000),
            "path": rel,
            "appId": metadata["appId"],
            "appLabel": metadata["appLabel"],
            "packageName": metadata["packageName"],
            "kind": metadata["appId"],
            "source": "github-actions",
        })
    builds.sort(key=lambda item: item["modifiedMs"], reverse=True)
    return builds


def advertised_ipv4_addresses(host: str) -> list[str]:
    candidates: set[str] = set()

    def add(address: str):
        if not address or address.startswith("127."):
            return
        candidates.add(address)

    if host not in ("", "0.0.0.0", "::"):
        try:
            add(socket.gethostbyname(host))
        except OSError:
            pass
    else:
        try:
            for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
                add(item[4][0])
        except OSError:
            pass
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
                probe.connect(("8.8.8.8", 80))
                add(probe.getsockname()[0])
        except OSError:
            pass
    return sorted(candidates) or ["127.0.0.1"]


def start_mdns(host: str, port: int, name: str, manifest: dict[str, Any]):
    if Zeroconf is None or ServiceInfo is None:
        print("mDNS disabled: install zeroconf to advertise DevOTA discovery.")
        return None, None
    safe_name = re.sub(r"[^A-Za-z0-9 -]+", "-", name).strip() or "DevOTA"
    addresses = [socket.inet_aton(addr) for addr in advertised_ipv4_addresses(host)]
    properties = {
        "version": "1",
        "apps": ",".join(app["id"] for app in manifest["apps"]),
    }
    info = ServiceInfo(
        MDNS_TYPE,
        f"{safe_name}.{MDNS_TYPE}",
        addresses=addresses,
        port=port,
        properties=properties,
        server=f"{socket.gethostname().split('.')[0]}.local.",
    )
    zeroconf = Zeroconf()
    zeroconf.register_service(info)
    print(f"mDNS advertising {safe_name} on {MDNS_TYPE} at port {port}")
    return zeroconf, info


def is_wsl() -> bool:
    if "WSL_DISTRO_NAME" in os.environ:
        return True
    try:
        return "microsoft" in Path("/proc/version").read_text(encoding="utf-8").lower()
    except OSError:
        return False


def command_exists(name: str) -> bool:
    paths = os.environ.get("PATH", "").split(os.pathsep)
    extensions = [""] if os.name != "nt" else os.environ.get("PATHEXT", "").split(os.pathsep)
    for path in paths:
        for ext in extensions:
            if (Path(path) / f"{name}{ext}").is_file():
                return True
    return False


def validate_public_key_line(public_key: str) -> str:
    line = " ".join(public_key.strip().split())
    if len(line) > 16 * 1024:
        raise ValueError("public key is too large")
    parts = line.split(" ")
    if len(parts) < 2:
        raise ValueError("public key must include type and base64 key data")
    key_type, key_blob = parts[0], parts[1]
    if key_type not in PUBLIC_KEY_TYPES:
        raise ValueError(f"unsupported public key type: {key_type}")
    try:
        decoded = base64.b64decode(key_blob.encode("ascii"), validate=True)
    except Exception as exc:
        raise ValueError("public key data is not valid base64") from exc
    if len(decoded) < 32 or len(decoded) > 8192:
        raise ValueError("public key data has an invalid length")
    comment = " ".join(parts[2:]) if len(parts) > 2 else "devota-phone"
    safe_comment = re.sub(r"[^A-Za-z0-9@._:+/=,-]+", "-", comment).strip("-")
    return f"{key_type} {key_blob} {safe_comment or 'devota-phone'}"


def append_authorized_key(path: Path, public_key: str) -> bool:
    path.parent.mkdir(parents=True, exist_ok=True)
    existing = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    key_identity = " ".join(public_key.split(" ")[:2])
    for line in existing:
        if " ".join(line.strip().split(" ")[:2]) == key_identity:
            return True
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        if existing and existing[-1].strip():
            handle.write("\n")
        handle.write(public_key)
        handle.write("\n")
    try:
        path.parent.chmod(0o700)
        path.chmod(0o600)
    except OSError:
        pass
    return False


def windows_path_to_wsl(path: str) -> Path:
    if command_exists("wslpath"):
        proc = subprocess.run(
            ["wslpath", "-u", path],
            text=True,
            timeout=5,
            capture_output=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return Path(proc.stdout.strip())
    match = re.match(r"^([A-Za-z]):\\(.*)$", path)
    if not match:
        raise ValueError(f"Cannot convert Windows path: {path}")
    drive = match.group(1).lower()
    rest = match.group(2).replace("\\", "/")
    return Path("/mnt") / drive / rest


def detect_windows_user_profile(windows_user: str | None = None) -> Path:
    override = os.environ.get("DEVOTA_WINDOWS_AUTHORIZED_KEYS")
    if override:
        return Path(override).expanduser()
    if windows_user:
        safe_user = re.sub(r"[^A-Za-z0-9._ -]+", "", windows_user).strip()
        if not safe_user:
            raise ValueError("windowsUser did not contain a valid username")
        return Path("/mnt/c/Users") / safe_user / ".ssh" / "authorized_keys"
    if command_exists("powershell.exe"):
        proc = subprocess.run(
            [
                "powershell.exe",
                "-NoProfile",
                "-Command",
                "[Environment]::GetFolderPath('UserProfile')",
            ],
            text=True,
            timeout=8,
            capture_output=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return windows_path_to_wsl(proc.stdout.strip()) / ".ssh" / "authorized_keys"
    raise ValueError("Could not detect Windows user profile")


def windows_current_user_is_administrator() -> bool:
    if not command_exists("powershell.exe"):
        return False
    script = (
        "$groups = whoami /groups 2>$null; "
        "if ($groups -match 'S-1-5-32-544') { 'true'; exit 0 }; "
        "$user = [Environment]::UserName; "
        "$domain = [Environment]::UserDomainName; "
        "$computer = [Environment]::MachineName; "
        "$names = @($user, \"$domain\\$user\", \"$computer\\$user\", \".\\$user\"); "
        "$members = net localgroup Administrators 2>$null; "
        "foreach ($line in $members) { "
        "  $trim = $line.Trim(); "
        "  foreach ($name in $names) { "
        "    if ($trim -ieq $name) { 'true'; exit 0 } "
        "  } "
        "}; "
        "'false'"
    )
    proc = subprocess.run(
        ["powershell.exe", "-NoProfile", "-Command", script],
        text=True,
        timeout=8,
        capture_output=True,
    )
    return proc.returncode == 0 and "true" in proc.stdout.lower()


def repair_windows_acl(path: Path, administrators_file: bool = False) -> str | None:
    if not command_exists("powershell.exe"):
        return "powershell.exe not found; skipped Windows ACL repair"
    try:
        proc = subprocess.run(
            ["wslpath", "-w", str(path)],
            text=True,
            timeout=5,
            capture_output=True,
        )
        windows_path = proc.stdout.strip() if proc.returncode == 0 else ""
    except Exception:
        windows_path = ""
    if not windows_path:
        return "could not convert authorized_keys path to a Windows path"
    if administrators_file:
        script = r"""
$path = $args[0]
icacls $path /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" | Out-Null
"""
    else:
        script = r"""
$path = $args[0]
$dir = Split-Path -Parent $path
$user = "$env:USERDOMAIN\$env:USERNAME"
icacls $dir /inheritance:r /grant:r "${user}:F" "SYSTEM:F" "Administrators:F" | Out-Null
icacls $path /inheritance:r /grant:r "${user}:F" "SYSTEM:F" "Administrators:F" | Out-Null
"""
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-Command", script, windows_path],
        text=True,
        timeout=10,
        capture_output=True,
    )
    if result.returncode != 0:
        return result.stderr.strip() or f"icacls exited {result.returncode}"
    return None


def wsl_path_to_windows(path: Path) -> str:
    if platform.system() == "Windows":
        return str(path)
    if command_exists("wslpath"):
        proc = subprocess.run(
            ["wslpath", "-w", str(path)],
            text=True,
            timeout=5,
            capture_output=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    raise ValueError(f"Could not convert to Windows path: {path}")


def windows_temp_dir() -> Path:
    if command_exists("powershell.exe"):
        proc = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command", "[IO.Path]::GetTempPath()"],
            text=True,
            timeout=8,
            capture_output=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return windows_path_to_wsl(proc.stdout.strip())
    return detect_windows_user_profile() / "AppData" / "Local" / "Temp"


def request_elevated_windows_admin_key_install(public_key: str) -> tuple[bool, str | None]:
    if not command_exists("powershell.exe"):
        return False, "powershell.exe not found; cannot request administrator approval"
    try:
        temp_dir = windows_temp_dir() / "DevOTA"
        temp_dir.mkdir(parents=True, exist_ok=True)
        stamp = str(int(time.time() * 1000))
        key_path = temp_dir / f"devota-authorized-key-{stamp}.pub"
        script_path = temp_dir / f"install-devota-admin-key-{stamp}.ps1"
        launcher_path = temp_dir / f"launch-devota-admin-key-{stamp}.ps1"
        key_path.write_text(public_key + "\n", encoding="utf-8", newline="\n")
        script_path.write_text(
            r'''
param([Parameter(Mandatory=$true)][string]$KeyFile)
$ErrorActionPreference = "Stop"
$adminKey = Join-Path $env:ProgramData "ssh\administrators_authorized_keys"
$key = (Get-Content -Raw -Path $KeyFile).Trim()
if (-not $key) { throw "Empty key file" }
$dir = Split-Path -Parent $adminKey
New-Item -ItemType Directory -Force -Path $dir | Out-Null
if (-not (Test-Path $adminKey)) {
  New-Item -ItemType File -Force -Path $adminKey | Out-Null
}
$identity = (($key -split " ")[0..1] -join " ")
$lines = @(Get-Content -Path $adminKey -ErrorAction SilentlyContinue)
$exists = $false
foreach ($line in $lines) {
  if (((($line.Trim() -split " ")[0..1] -join " ")) -eq $identity) {
    $exists = $true
    break
  }
}
if (-not $exists) {
  Add-Content -Path $adminKey -Value $key -Encoding ascii
}
icacls $adminKey /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue $KeyFile
Remove-Item -Force -ErrorAction SilentlyContinue $PSCommandPath
'''.lstrip(),
            encoding="utf-8",
            newline="\r\n",
        )
        script_win = wsl_path_to_windows(script_path)
        key_win = wsl_path_to_windows(key_path)
        launcher_path.write_text(
            r'''
param(
  [Parameter(Mandatory=$true)][string]$InstallScript,
  [Parameter(Mandatory=$true)][string]$KeyFile
)
$ErrorActionPreference = "Stop"
Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList @(
  '-NoProfile',
  '-ExecutionPolicy',
  'Bypass',
  '-File',
  $InstallScript,
  '-KeyFile',
  $KeyFile
)
Remove-Item -Force -ErrorAction SilentlyContinue $PSCommandPath
'''.lstrip(),
            encoding="utf-8",
            newline="\r\n",
        )
        launcher_win = wsl_path_to_windows(launcher_path)
        subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                launcher_win,
                "-InstallScript",
                script_win,
                "-KeyFile",
                key_win,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )
        return True, None
    except Exception as exc:
        return False, str(exc)


def windows_admin_authorized_keys_path() -> Path:
    override = os.environ.get("DEVOTA_WINDOWS_ADMIN_AUTHORIZED_KEYS")
    if override:
        return Path(override).expanduser()
    if platform.system() == "Windows":
        program_data = Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData"))
        return program_data / "ssh" / "administrators_authorized_keys"
    return Path("/mnt/c/ProgramData/ssh/administrators_authorized_keys")


def windows_admin_authorized_keys_enabled() -> bool:
    if platform.system() == "Windows":
        config = Path(os.environ.get("PROGRAMDATA", r"C:\ProgramData")) / "ssh" / "sshd_config"
    else:
        config = Path("/mnt/c/ProgramData/ssh/sshd_config")
    try:
        text = config.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return False
    return "administrators_authorized_keys" in text


def install_authorized_key(
    target: str,
    public_key: str,
    windows_user: str | None = None,
) -> dict[str, Any]:
    requested_target = (target or "auto").lower()
    windows_admin_primary = requested_target in ("windows-admin", "admin")
    if (
        requested_target == "auto"
        and (platform.system() == "Windows" or is_wsl())
        and windows_admin_authorized_keys_enabled()
        and windows_current_user_is_administrator()
    ):
        windows_admin_primary = True

    if windows_admin_primary:
        target_name, target_path = "windows-admin", windows_admin_authorized_keys_path()
    else:
        target_name, target_path = authorized_keys_target(target, windows_user)
    paths: list[dict[str, Any]] = []
    warnings: list[str] = []
    approval_required = False

    try:
        already_present = append_authorized_key(target_path, public_key)
        if target_name == "windows":
            warning = repair_windows_acl(target_path)
            if warning:
                warnings.append(f"{target_path}: {warning}")
        elif target_name == "windows-admin":
            warning = repair_windows_acl(target_path, administrators_file=True)
            if warning:
                warnings.append(f"{target_path}: {warning}")
    except PermissionError:
        if target_name != "windows-admin":
            raise
        already_present = False
        ok, error = request_elevated_windows_admin_key_install(public_key)
        if not ok:
            raise PermissionError(
                f"administrator key file needs elevation and UAC request failed: {error}"
            )
        approval_required = True
        warnings.append(
            "Windows administrator approval requested. Accept the Windows prompt, then return to DevOTA and tap Connect."
        )
    paths.append({
        "target": target_name,
        "path": str(target_path),
        "alreadyPresent": already_present,
    })

    if target_name == "windows-admin":
        try:
            user_path = detect_windows_user_profile(windows_user)
            user_already_present = append_authorized_key(user_path, public_key)
            warning = repair_windows_acl(user_path)
            if warning:
                warnings.append(f"{user_path}: {warning}")
            paths.append({
                "target": "windows",
                "path": str(user_path),
                "alreadyPresent": user_already_present,
            })
        except Exception as exc:
            warnings.append(f"secondary user authorized_keys: {exc}")
    elif target_name == "windows" and windows_admin_authorized_keys_enabled():
        admin_path = windows_admin_authorized_keys_path()
        try:
            admin_already_present = append_authorized_key(admin_path, public_key)
            warning = repair_windows_acl(admin_path, administrators_file=True)
            if warning:
                warnings.append(f"{admin_path}: {warning}")
            paths.append({
                "target": "windows-admin",
                "path": str(admin_path),
                "alreadyPresent": admin_already_present,
            })
        except Exception as exc:
            warnings.append(f"{admin_path}: {exc}")

    return {
        "status": "ok",
        "target": target_name,
        "path": str(target_path),
        "alreadyPresent": already_present,
        "paths": paths,
        "warnings": warnings,
        "approvalRequired": approval_required,
    }


def authorized_keys_target(target: str, windows_user: str | None = None) -> tuple[str, Path]:
    normalized = (target or "auto").lower()
    if normalized in ("windows-admin", "admin"):
        return "windows-admin", windows_admin_authorized_keys_path()
    if normalized == "auto":
        normalized = "windows" if platform.system() == "Windows" or is_wsl() else "user"
    if normalized == "windows":
        if platform.system() == "Windows":
            base = Path(os.environ.get("USERPROFILE", str(Path.home())))
            return "windows", base / ".ssh" / "authorized_keys"
        return "windows", detect_windows_user_profile(windows_user)
    if normalized in ("user", "local"):
        return "user", Path.home() / ".ssh" / "authorized_keys"
    raise ValueError(f"unsupported SSH key target: {target}")


def set_host_clipboard(text: str) -> tuple[bool, str]:
    system = platform.system()
    try:
        if system == "Windows":
            proc = subprocess.run(
                ["clip"],
                input=text,
                text=True,
                encoding="utf-8",
                shell=True,
                timeout=5,
                capture_output=True,
            )
        elif system == "Darwin":
            proc = subprocess.run(
                ["pbcopy"],
                input=text,
                text=True,
                encoding="utf-8",
                timeout=5,
                capture_output=True,
            )
        else:
            if is_wsl() and command_exists("clip.exe"):
                proc = subprocess.run(
                    ["clip.exe"],
                    input=text,
                    text=True,
                    encoding="utf-8",
                    timeout=5,
                    capture_output=True,
                )
                if proc.returncode == 0:
                    return True, ""
                return False, proc.stderr or f"exit {proc.returncode}"
            for tool in (["xclip", "-selection", "clipboard"], ["xsel", "-b", "-i"]):
                try:
                    proc = subprocess.run(
                        tool,
                        input=text,
                        text=True,
                        encoding="utf-8",
                        timeout=5,
                        capture_output=True,
                    )
                    break
                except FileNotFoundError:
                    continue
            else:
                return False, "no xclip or xsel installed"
        if proc.returncode != 0:
            return False, proc.stderr or f"exit {proc.returncode}"
        return True, ""
    except Exception as exc:
        return False, str(exc)


def parse_json_request(handler: SimpleHTTPRequestHandler, max_bytes: int = 64 * 1024) -> dict[str, Any]:
    length = int(handler.headers.get("Content-Length", 0) or 0)
    if length <= 0:
        return {}
    if length > max_bytes:
        raise ValueError("request body is too large")
    raw = handler.rfile.read(length)
    try:
        payload = json.loads(raw.decode("utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("JSON body must be an object")
    return payload


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def projects_cache_dir(repo_root: Path) -> Path:
    return repo_root / ".devota-cache" / "projects"


def projects_db_path(repo_root: Path) -> Path:
    return projects_cache_dir(repo_root) / "devota-projects.sqlite3"


def email_config_path(repo_root: Path) -> Path:
    return projects_cache_dir(repo_root) / "email-config.json"


def connect_projects_db(repo_root: Path) -> sqlite3.Connection:
    path = projects_db_path(repo_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    initialize_projects_db(conn)
    return conn


def initialize_projects_db(conn: sqlite3.Connection):
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS clients (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          email TEXT NOT NULL DEFAULT '',
          notes TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS projects (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          client_id INTEGER NOT NULL REFERENCES clients(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          repo_url TEXT NOT NULL DEFAULT '',
          build_app_id TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'active',
          notes TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS phases (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          project_id INTEGER NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          phase_order INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'not_started',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS cards (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          phase_id INTEGER NOT NULL REFERENCES phases(id) ON DELETE CASCADE,
          title TEXT NOT NULL,
          body TEXT NOT NULL DEFAULT '',
          status TEXT NOT NULL DEFAULT 'todo',
          card_order INTEGER NOT NULL DEFAULT 0,
          client_action_required INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS comments (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
          author_type TEXT NOT NULL DEFAULT 'me',
          author_name TEXT NOT NULL DEFAULT '',
          author_email TEXT NOT NULL DEFAULT '',
          body TEXT NOT NULL,
          source TEXT NOT NULL DEFAULT 'manual',
          provider_message_id TEXT,
          created_at TEXT NOT NULL,
          UNIQUE(provider_message_id) ON CONFLICT IGNORE
        );
        CREATE TABLE IF NOT EXISTS mail_threads (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          card_id INTEGER NOT NULL UNIQUE REFERENCES cards(id) ON DELETE CASCADE,
          token TEXT NOT NULL UNIQUE,
          provider TEXT NOT NULL DEFAULT 'postmark',
          last_message_id TEXT NOT NULL DEFAULT '',
          subject TEXT NOT NULL DEFAULT '',
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS phase_templates (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL UNIQUE,
          phases_json TEXT NOT NULL,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        );
        """
    )
    existing = conn.execute("SELECT COUNT(*) AS count FROM phase_templates").fetchone()["count"]
    if existing == 0:
        stamp = now_iso()
        conn.execute(
            "INSERT INTO phase_templates (name, phases_json, created_at, updated_at) VALUES (?, ?, ?, ?)",
            ("App project", json.dumps(DEFAULT_PHASE_TEMPLATE), stamp, stamp),
        )
        conn.commit()


def require_text(payload: dict[str, Any], key: str, label: str | None = None) -> str:
    text = str(payload.get(key) or "").strip()
    if not text:
        raise ValueError(f"{label or key} is required")
    return text


def optional_text(payload: dict[str, Any], key: str) -> str:
    return str(payload.get(key) or "").strip()


def require_int(payload: dict[str, Any], key: str, label: str | None = None) -> int:
    value = payload.get(key)
    try:
        result = int(value)
    except Exception as exc:
        raise ValueError(f"{label or key} must be an integer") from exc
    if result <= 0:
        raise ValueError(f"{label or key} must be positive")
    return result


def normalize_status(value: Any, allowed: set[str], default: str) -> str:
    status = str(value or default).strip()
    if status not in allowed:
        raise ValueError(f"unsupported status: {status}")
    return status


def bool_int(value: Any) -> int:
    if isinstance(value, bool):
        return 1 if value else 0
    if isinstance(value, (int, float)):
        return 1 if value else 0
    return 1 if str(value or "").strip().lower() in ("1", "true", "yes", "on") else 0


def client_payload(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "name": row["name"],
        "email": row["email"],
        "notes": row["notes"],
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
    }


def project_payload(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "clientId": row["client_id"],
        "name": row["name"],
        "repoUrl": row["repo_url"],
        "buildAppId": row["build_app_id"],
        "status": row["status"],
        "notes": row["notes"],
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
    }


def phase_payload(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "projectId": row["project_id"],
        "name": row["name"],
        "order": row["phase_order"],
        "status": row["status"],
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
    }


def card_payload(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "phaseId": row["phase_id"],
        "title": row["title"],
        "body": row["body"],
        "status": row["status"],
        "order": row["card_order"],
        "clientActionRequired": bool(row["client_action_required"]),
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
    }


def comment_payload(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"],
        "cardId": row["card_id"],
        "authorType": row["author_type"],
        "authorName": row["author_name"],
        "authorEmail": row["author_email"],
        "body": row["body"],
        "source": row["source"],
        "providerMessageId": row["provider_message_id"],
        "createdAt": row["created_at"],
    }


def template_payload(row: sqlite3.Row) -> dict[str, Any]:
    try:
        phases = json.loads(row["phases_json"])
    except Exception:
        phases = []
    return {
        "id": row["id"],
        "name": row["name"],
        "phases": [str(item) for item in phases if str(item).strip()],
        "createdAt": row["created_at"],
        "updatedAt": row["updated_at"],
    }


def email_config(repo_root: Path, include_token: bool = False) -> dict[str, Any]:
    path = email_config_path(repo_root)
    data: dict[str, Any] = {}
    if path.is_file():
        try:
            loaded = json.loads(path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                data = loaded
        except Exception:
            data = {}
    defaults = {
        "provider": "postmark",
        "fromEmail": "",
        "fromName": "DevOTA",
        "inboundDomain": "",
        "messageStream": "outbound",
        "relayPullUrl": "",
        "relayToken": "",
        "postmarkServerToken": "",
    }
    merged = {**defaults, **{str(k): v for k, v in data.items()}}
    result = {
        "provider": str(merged["provider"] or "postmark"),
        "fromEmail": str(merged["fromEmail"] or ""),
        "fromName": str(merged["fromName"] or "DevOTA"),
        "inboundDomain": str(merged["inboundDomain"] or ""),
        "messageStream": str(merged["messageStream"] or "outbound"),
        "relayPullUrl": str(merged["relayPullUrl"] or ""),
        "relayTokenConfigured": bool(str(merged["relayToken"] or "")),
        "postmarkConfigured": bool(str(merged["postmarkServerToken"] or "")),
    }
    if include_token:
        result["relayToken"] = str(merged["relayToken"] or "")
        result["postmarkServerToken"] = str(merged["postmarkServerToken"] or "")
    return result


def save_email_config(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    current = email_config(repo_root, include_token=True)
    for key in (
        "provider",
        "fromEmail",
        "fromName",
        "inboundDomain",
        "messageStream",
        "relayPullUrl",
        "relayToken",
        "postmarkServerToken",
    ):
        if key in payload:
            current[key] = str(payload.get(key) or "").strip()
    path = email_config_path(repo_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(current, indent=2), encoding="utf-8")
    tmp.replace(path)
    return email_config(repo_root)


def fetch_one(conn: sqlite3.Connection, table: str, item_id: int) -> sqlite3.Row:
    row = conn.execute(f"SELECT * FROM {table} WHERE id = ?", (item_id,)).fetchone()
    if row is None:
        raise FileNotFoundError(f"{table[:-1]} not found")
    return row


def list_project_board(repo_root: Path) -> dict[str, Any]:
    with connect_projects_db(repo_root) as conn:
        clients = [client_payload(row) for row in conn.execute("SELECT * FROM clients ORDER BY name, id")]
        projects = [
            project_payload(row)
            for row in conn.execute("SELECT * FROM projects ORDER BY updated_at DESC, id DESC")
        ]
        phases = [
            phase_payload(row)
            for row in conn.execute("SELECT * FROM phases ORDER BY project_id, phase_order, id")
        ]
        cards = [
            card_payload(row)
            for row in conn.execute("SELECT * FROM cards ORDER BY phase_id, card_order, id")
        ]
        comments = [
            comment_payload(row)
            for row in conn.execute("SELECT * FROM comments ORDER BY created_at, id")
        ]
        templates = [
            template_payload(row)
            for row in conn.execute("SELECT * FROM phase_templates ORDER BY name, id")
        ]
    return {
        "status": "ok",
        "clients": clients,
        "projects": projects,
        "phases": phases,
        "cards": cards,
        "comments": comments,
        "phaseTemplates": templates,
        "emailConfig": email_config(repo_root),
    }


def create_client(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    stamp = now_iso()
    with connect_projects_db(repo_root) as conn:
        cur = conn.execute(
            "INSERT INTO clients (name, email, notes, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            (
                require_text(payload, "name", "client name"),
                optional_text(payload, "email"),
                optional_text(payload, "notes"),
                stamp,
                stamp,
            ),
        )
        conn.commit()
        return client_payload(fetch_one(conn, "clients", cur.lastrowid))


def update_client(repo_root: Path, item_id: int, payload: dict[str, Any]) -> dict[str, Any]:
    updates: dict[str, Any] = {}
    for key, column in (("name", "name"), ("email", "email"), ("notes", "notes")):
        if key in payload:
            updates[column] = str(payload.get(key) or "").strip()
    if "name" in updates and not updates["name"]:
        raise ValueError("client name is required")
    return update_row(repo_root, "clients", item_id, updates, client_payload)


def create_project(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    stamp = now_iso()
    with connect_projects_db(repo_root) as conn:
        client_id = require_int(payload, "clientId", "clientId")
        fetch_one(conn, "clients", client_id)
        status = normalize_status(payload.get("status"), PROJECT_STATUSES, "active")
        cur = conn.execute(
            """
            INSERT INTO projects (client_id, name, repo_url, build_app_id, status, notes, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                client_id,
                require_text(payload, "name", "project name"),
                optional_text(payload, "repoUrl"),
                optional_text(payload, "buildAppId"),
                status,
                optional_text(payload, "notes"),
                stamp,
                stamp,
            ),
        )
        project_id = cur.lastrowid
        if payload.get("applyTemplate", True) is not False:
            template_id = payload.get("templateId")
            if template_id:
                template = fetch_one(conn, "phase_templates", int(template_id))
            else:
                template = conn.execute("SELECT * FROM phase_templates ORDER BY id LIMIT 1").fetchone()
            phases = template_payload(template)["phases"] if template is not None else DEFAULT_PHASE_TEMPLATE
            for index, name in enumerate(phases):
                conn.execute(
                    "INSERT INTO phases (project_id, name, phase_order, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
                    (project_id, name, index, "not_started", stamp, stamp),
                )
        conn.commit()
        return project_payload(fetch_one(conn, "projects", project_id))


def update_project(repo_root: Path, item_id: int, payload: dict[str, Any]) -> dict[str, Any]:
    updates: dict[str, Any] = {}
    mapping = (
        ("clientId", "client_id"),
        ("name", "name"),
        ("repoUrl", "repo_url"),
        ("buildAppId", "build_app_id"),
        ("notes", "notes"),
    )
    for key, column in mapping:
        if key in payload:
            updates[column] = int(payload[key]) if key == "clientId" else str(payload.get(key) or "").strip()
    if "status" in payload:
        updates["status"] = normalize_status(payload.get("status"), PROJECT_STATUSES, "active")
    if "name" in updates and not updates["name"]:
        raise ValueError("project name is required")
    return update_row(repo_root, "projects", item_id, updates, project_payload)


def create_phase(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    stamp = now_iso()
    with connect_projects_db(repo_root) as conn:
        project_id = require_int(payload, "projectId", "projectId")
        fetch_one(conn, "projects", project_id)
        order = payload.get("order")
        if order in (None, ""):
            row = conn.execute("SELECT COALESCE(MAX(phase_order), -1) + 1 AS next_order FROM phases WHERE project_id = ?", (project_id,)).fetchone()
            order = row["next_order"]
        cur = conn.execute(
            "INSERT INTO phases (project_id, name, phase_order, status, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            (
                project_id,
                require_text(payload, "name", "phase name"),
                int(order),
                normalize_status(payload.get("status"), PHASE_STATUSES, "not_started"),
                stamp,
                stamp,
            ),
        )
        conn.commit()
        return phase_payload(fetch_one(conn, "phases", cur.lastrowid))


def update_phase(repo_root: Path, item_id: int, payload: dict[str, Any]) -> dict[str, Any]:
    updates: dict[str, Any] = {}
    for key, column in (("projectId", "project_id"), ("name", "name"), ("order", "phase_order")):
        if key in payload:
            updates[column] = int(payload[key]) if key in ("projectId", "order") else str(payload.get(key) or "").strip()
    if "status" in payload:
        updates["status"] = normalize_status(payload.get("status"), PHASE_STATUSES, "not_started")
    if "name" in updates and not updates["name"]:
        raise ValueError("phase name is required")
    return update_row(repo_root, "phases", item_id, updates, phase_payload)


def create_card(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    stamp = now_iso()
    with connect_projects_db(repo_root) as conn:
        phase_id = require_int(payload, "phaseId", "phaseId")
        fetch_one(conn, "phases", phase_id)
        order = payload.get("order")
        if order in (None, ""):
            row = conn.execute("SELECT COALESCE(MAX(card_order), -1) + 1 AS next_order FROM cards WHERE phase_id = ?", (phase_id,)).fetchone()
            order = row["next_order"]
        cur = conn.execute(
            """
            INSERT INTO cards (phase_id, title, body, status, card_order, client_action_required, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                phase_id,
                require_text(payload, "title", "card title"),
                optional_text(payload, "body"),
                normalize_status(payload.get("status"), CARD_STATUSES, "todo"),
                int(order),
                bool_int(payload.get("clientActionRequired")),
                stamp,
                stamp,
            ),
        )
        conn.commit()
        return card_payload(fetch_one(conn, "cards", cur.lastrowid))


def create_phase_template(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    name = require_text(payload, "name", "template name")
    phases_raw = payload.get("phases")
    if not isinstance(phases_raw, list):
        raise ValueError("phases must be a list of names")
    phases = [str(item).strip() for item in phases_raw if str(item).strip()]
    if not phases:
        raise ValueError("template must include at least one phase")
    stamp = now_iso()
    with connect_projects_db(repo_root) as conn:
        cur = conn.execute(
            "INSERT INTO phase_templates (name, phases_json, created_at, updated_at) VALUES (?, ?, ?, ?)",
            (name, json.dumps(phases), stamp, stamp),
        )
        conn.commit()
        return template_payload(fetch_one(conn, "phase_templates", cur.lastrowid))


def update_card(repo_root: Path, item_id: int, payload: dict[str, Any]) -> dict[str, Any]:
    updates: dict[str, Any] = {}
    mapping = (
        ("phaseId", "phase_id"),
        ("title", "title"),
        ("body", "body"),
        ("order", "card_order"),
        ("clientActionRequired", "client_action_required"),
    )
    for key, column in mapping:
        if key in payload:
            if key in ("phaseId", "order"):
                updates[column] = int(payload[key])
            elif key == "clientActionRequired":
                updates[column] = bool_int(payload[key])
            else:
                updates[column] = str(payload.get(key) or "").strip()
    if "status" in payload:
        updates["status"] = normalize_status(payload.get("status"), CARD_STATUSES, "todo")
    if "title" in updates and not updates["title"]:
        raise ValueError("card title is required")
    return update_row(repo_root, "cards", item_id, updates, card_payload)


def update_row(
    repo_root: Path,
    table: str,
    item_id: int,
    updates: dict[str, Any],
    serializer,
) -> dict[str, Any]:
    if not updates:
        with connect_projects_db(repo_root) as conn:
            return serializer(fetch_one(conn, table, item_id))
    updates["updated_at"] = now_iso()
    assignments = ", ".join(f"{key} = ?" for key in updates)
    values = list(updates.values())
    values.append(item_id)
    with connect_projects_db(repo_root) as conn:
        fetch_one(conn, table, item_id)
        conn.execute(f"UPDATE {table} SET {assignments} WHERE id = ?", values)
        conn.commit()
        return serializer(fetch_one(conn, table, item_id))


def create_comment(repo_root: Path, card_id: int, payload: dict[str, Any]) -> dict[str, Any]:
    stamp = now_iso()
    author_type = normalize_status(payload.get("authorType"), COMMENT_AUTHOR_TYPES, "me")
    body = require_text(payload, "body", "comment body")
    with connect_projects_db(repo_root) as conn:
        fetch_one(conn, "cards", card_id)
        cur = conn.execute(
            """
            INSERT INTO comments (card_id, author_type, author_name, author_email, body, source, provider_message_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                card_id,
                author_type,
                optional_text(payload, "authorName"),
                optional_text(payload, "authorEmail"),
                body,
                optional_text(payload, "source") or "manual",
                optional_text(payload, "providerMessageId") or None,
                stamp,
            ),
        )
        conn.execute("UPDATE cards SET updated_at = ? WHERE id = ?", (stamp, card_id))
        conn.commit()
        return comment_payload(fetch_one(conn, "comments", cur.lastrowid))


def card_context(conn: sqlite3.Connection, card_id: int) -> dict[str, sqlite3.Row]:
    row = conn.execute(
        """
        SELECT
          cards.id AS card_id,
          cards.title AS card_title,
          cards.body AS card_body,
          cards.status AS card_status,
          phases.id AS phase_id,
          phases.name AS phase_name,
          projects.id AS project_id,
          projects.name AS project_name,
          clients.id AS client_id,
          clients.name AS client_name,
          clients.email AS client_email
        FROM cards
        JOIN phases ON phases.id = cards.phase_id
        JOIN projects ON projects.id = phases.project_id
        JOIN clients ON clients.id = projects.client_id
        WHERE cards.id = ?
        """,
        (card_id,),
    ).fetchone()
    if row is None:
        raise FileNotFoundError("card not found")
    return dict(row)


def ensure_mail_thread(conn: sqlite3.Connection, card_id: int, subject: str) -> sqlite3.Row:
    existing = conn.execute("SELECT * FROM mail_threads WHERE card_id = ?", (card_id,)).fetchone()
    if existing is not None:
        if subject and existing["subject"] != subject:
            conn.execute(
                "UPDATE mail_threads SET subject = ?, updated_at = ? WHERE id = ?",
                (subject, now_iso(), existing["id"]),
            )
            return conn.execute("SELECT * FROM mail_threads WHERE id = ?", (existing["id"],)).fetchone()
        return existing
    stamp = now_iso()
    token = f"card-{card_id}-{uuid.uuid4().hex[:16]}"
    cur = conn.execute(
        "INSERT INTO mail_threads (card_id, token, subject, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
        (card_id, token, subject, stamp, stamp),
    )
    return conn.execute("SELECT * FROM mail_threads WHERE id = ?", (cur.lastrowid,)).fetchone()


def default_email_message(event: str, ctx: dict[str, Any]) -> str:
    card = ctx["card_title"]
    phase = ctx["phase_name"]
    project = ctx["project_name"]
    if event == "phase_started":
        return f"I started the {phase} phase for {project}."
    if event == "phase_completed":
        return f"I completed the {phase} phase for {project}."
    if event == "client_action":
        return f"I need your feedback or approval on {card} for {project}."
    return f"Update on {card} for {project}."


def email_preview(repo_root: Path, card_id: int, payload: dict[str, Any]) -> dict[str, Any]:
    config = email_config(repo_root, include_token=True)
    with connect_projects_db(repo_root) as conn:
        ctx = card_context(conn, card_id)
        subject = str(payload.get("subject") or f"[{ctx['project_name']}] {ctx['card_title']}").strip()
        thread = ensure_mail_thread(conn, card_id, subject)
        conn.commit()
    event = str(payload.get("event") or "update")
    message = str(payload.get("message") or "").strip() or default_email_message(event, ctx)
    reply_to = config["fromEmail"]
    if config.get("inboundDomain"):
        reply_to = f"reply+{thread['token']}@{config['inboundDomain']}"
    text_body = "\n\n".join(
        [
            f"Hi {ctx['client_name']},",
            message,
            f"Project: {ctx['project_name']}\nPhase: {ctx['phase_name']}\nCard: {ctx['card_title']}",
            "Reply to this email and your response will be added to the DevOTA card thread.",
        ]
    )
    return {
        "status": "ok",
        "cardId": card_id,
        "threadToken": thread["token"],
        "to": ctx["client_email"],
        "from": config["fromEmail"],
        "replyTo": reply_to,
        "subject": subject,
        "textBody": text_body,
        "message": message,
        "postmarkConfigured": bool(config.get("postmarkServerToken")),
    }


def postmark_send(repo_root: Path, card_id: int, payload: dict[str, Any]) -> dict[str, Any]:
    config = email_config(repo_root, include_token=True)
    token = str(config.get("postmarkServerToken") or "")
    if not token:
        raise ValueError("Postmark server token is not configured")
    preview = email_preview(repo_root, card_id, payload)
    if not preview["to"]:
        raise ValueError("client email is required before sending")
    if not preview["from"]:
        raise ValueError("from email is required before sending")

    message = {
        "From": f"{config['fromName']} <{preview['from']}>" if config.get("fromName") else preview["from"],
        "To": preview["to"],
        "Subject": preview["subject"],
        "TextBody": preview["textBody"],
        "ReplyTo": preview["replyTo"],
        "MessageStream": config.get("messageStream") or "outbound",
    }
    req = urllib.request.Request(
        "https://api.postmarkapp.com/email",
        data=json.dumps(message).encode("utf-8"),
        headers={
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Postmark-Server-Token": token,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            response_payload = json.loads(response.read().decode("utf-8") or "{}")
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Postmark returned HTTP {exc.code}: {details}") from exc

    provider_id = str(response_payload.get("MessageID") or "")
    with connect_projects_db(repo_root) as conn:
        stamp = now_iso()
        conn.execute(
            """
            INSERT INTO comments (card_id, author_type, author_name, author_email, body, source, provider_message_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                card_id,
                "me",
                config.get("fromName") or "DevOTA",
                preview["from"],
                preview["message"],
                "email",
                provider_id or None,
                stamp,
            ),
        )
        conn.execute(
            "UPDATE mail_threads SET last_message_id = ?, updated_at = ? WHERE token = ?",
            (provider_id, stamp, preview["threadToken"]),
        )
        conn.execute("UPDATE cards SET updated_at = ? WHERE id = ?", (stamp, card_id))
        conn.commit()
    return {"status": "ok", "postmark": response_payload, "preview": preview}


def inbound_body(payload: dict[str, Any]) -> str:
    for key in ("StrippedTextReply", "TextBody", "HtmlBody"):
        value = str(payload.get(key) or "").strip()
        if value:
            return value
    return "(empty email reply)"


def inbound_sender(payload: dict[str, Any]) -> tuple[str, str]:
    name = str(payload.get("FromName") or "").strip()
    from_full = payload.get("FromFull")
    email = str(payload.get("From") or "").strip()
    if isinstance(from_full, dict):
        if not email:
            email = str(from_full.get("Email") or "").strip()
        if not name:
            name = str(from_full.get("Name") or "").strip()
    return name, email


def inbound_token(payload: dict[str, Any]) -> str:
    token = str(payload.get("MailboxHash") or "").strip()
    if token:
        return token
    candidates: list[str] = []
    for key in ("OriginalRecipient", "To"):
        value = payload.get(key)
        if isinstance(value, str):
            candidates.append(value)
    for key in ("ToFull", "CcFull"):
        value = payload.get(key)
        if isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    candidates.append(str(item.get("Email") or ""))
    for value in candidates:
        match = re.search(r"\+([^@\s>]+)@", value)
        if match:
            return match.group(1)
    raise ValueError("inbound email did not include a thread token")


def import_inbound_email(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    token = inbound_token(payload)
    message_id = str(payload.get("MessageID") or payload.get("MessageId") or payload.get("messageId") or "").strip()
    body = inbound_body(payload)
    name, email = inbound_sender(payload)
    with connect_projects_db(repo_root) as conn:
        thread = conn.execute("SELECT * FROM mail_threads WHERE token = ?", (token,)).fetchone()
        if thread is None:
            raise FileNotFoundError(f"mail thread not found for token: {token}")
        card_id = int(thread["card_id"])
        if message_id:
            existing = conn.execute("SELECT * FROM comments WHERE provider_message_id = ?", (message_id,)).fetchone()
            if existing is not None:
                return {"status": "ok", "deduped": True, "comment": comment_payload(existing)}
        stamp = now_iso()
        cur = conn.execute(
            """
            INSERT INTO comments (card_id, author_type, author_name, author_email, body, source, provider_message_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (card_id, "client", name, email, body, "email", message_id or None, stamp),
        )
        conn.execute(
            "UPDATE mail_threads SET last_message_id = ?, updated_at = ? WHERE id = ?",
            (message_id, stamp, thread["id"]),
        )
        conn.execute("UPDATE cards SET updated_at = ? WHERE id = ?", (stamp, card_id))
        conn.commit()
        return {"status": "ok", "deduped": False, "comment": comment_payload(fetch_one(conn, "comments", cur.lastrowid))}


def pull_inbound_email(repo_root: Path) -> dict[str, Any]:
    config = email_config(repo_root, include_token=True)
    url = str(config.get("relayPullUrl") or "").strip()
    if not url:
        raise ValueError("relay pull URL is not configured")
    headers = {"Accept": "application/json"}
    if config.get("relayToken"):
        headers["Authorization"] = f"Bearer {config['relayToken']}"
    req = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=30) as response:
        data = json.loads(response.read().decode("utf-8") or "{}")
    events = data.get("events") if isinstance(data, dict) else data
    if not isinstance(events, list):
        raise ValueError("relay response must include an events array")
    imported = []
    errors = []
    for event in events:
        try:
            if isinstance(event, dict):
                imported.append(import_inbound_email(repo_root, event.get("payload") if isinstance(event.get("payload"), dict) else event))
        except Exception as exc:
            errors.append(str(exc))
    return {"status": "ok", "imported": imported, "errors": errors}


def handle_projects_get(repo_root: Path, path: str) -> dict[str, Any]:
    if path in ("/projects", "/projects/board"):
        return list_project_board(repo_root)
    if path == "/projects/email/config":
        return {"status": "ok", "emailConfig": email_config(repo_root)}
    with connect_projects_db(repo_root) as conn:
        if path == "/projects/clients":
            return {"status": "ok", "items": [client_payload(row) for row in conn.execute("SELECT * FROM clients ORDER BY name, id")]}
        if path == "/projects/projects":
            return {"status": "ok", "items": [project_payload(row) for row in conn.execute("SELECT * FROM projects ORDER BY updated_at DESC, id DESC")]}
        if path == "/projects/phases":
            return {"status": "ok", "items": [phase_payload(row) for row in conn.execute("SELECT * FROM phases ORDER BY project_id, phase_order, id")]}
        if path == "/projects/cards":
            return {"status": "ok", "items": [card_payload(row) for row in conn.execute("SELECT * FROM cards ORDER BY phase_id, card_order, id")]}
        if path == "/projects/templates":
            return {"status": "ok", "items": [template_payload(row) for row in conn.execute("SELECT * FROM phase_templates ORDER BY name, id")]}
        match = re.fullmatch(r"/projects/cards/(\d+)/comments", path)
        if match:
            card_id = int(match.group(1))
            fetch_one(conn, "cards", card_id)
            return {
                "status": "ok",
                "items": [
                    comment_payload(row)
                    for row in conn.execute("SELECT * FROM comments WHERE card_id = ? ORDER BY created_at, id", (card_id,))
                ],
            }
    raise FileNotFoundError("projects endpoint not found")


def handle_projects_post(repo_root: Path, path: str, payload: dict[str, Any]) -> dict[str, Any]:
    if path == "/projects/email/config":
        return {"status": "ok", "emailConfig": save_email_config(repo_root, payload)}
    if path == "/projects/clients":
        return {"status": "ok", "item": create_client(repo_root, payload)}
    if path == "/projects/projects":
        return {"status": "ok", "item": create_project(repo_root, payload)}
    if path == "/projects/phases":
        return {"status": "ok", "item": create_phase(repo_root, payload)}
    if path == "/projects/cards":
        return {"status": "ok", "item": create_card(repo_root, payload)}
    if path == "/projects/templates":
        return {"status": "ok", "item": create_phase_template(repo_root, payload)}
    if path == "/projects/mail/import":
        return import_inbound_email(repo_root, payload)
    if path == "/projects/mail/pull":
        return pull_inbound_email(repo_root)
    match = re.fullmatch(r"/projects/cards/(\d+)/comments", path)
    if match:
        return {"status": "ok", "item": create_comment(repo_root, int(match.group(1)), payload)}
    match = re.fullmatch(r"/projects/cards/(\d+)/email/preview", path)
    if match:
        return email_preview(repo_root, int(match.group(1)), payload)
    match = re.fullmatch(r"/projects/cards/(\d+)/email/send", path)
    if match:
        return postmark_send(repo_root, int(match.group(1)), payload)
    raise FileNotFoundError("projects endpoint not found")


def handle_projects_patch(repo_root: Path, path: str, payload: dict[str, Any]) -> dict[str, Any]:
    match = re.fullmatch(r"/projects/clients/(\d+)", path)
    if match:
        return {"status": "ok", "item": update_client(repo_root, int(match.group(1)), payload)}
    match = re.fullmatch(r"/projects/projects/(\d+)", path)
    if match:
        return {"status": "ok", "item": update_project(repo_root, int(match.group(1)), payload)}
    match = re.fullmatch(r"/projects/phases/(\d+)", path)
    if match:
        return {"status": "ok", "item": update_phase(repo_root, int(match.group(1)), payload)}
    match = re.fullmatch(r"/projects/cards/(\d+)", path)
    if match:
        return {"status": "ok", "item": update_card(repo_root, int(match.group(1)), payload)}
    raise FileNotFoundError("projects endpoint not found")


def _safe_terminal_upload_name(filename: str | None) -> str:
    original = (filename or TERMINAL_UPLOAD_DEFAULT_NAME).replace("\\", "/")
    safe_name = Path(original).name
    safe_name = re.sub(r"[^A-Za-z0-9._-]+", "-", safe_name).strip(".-")
    if not safe_name:
        return TERMINAL_UPLOAD_DEFAULT_NAME
    if len(safe_name) <= TERMINAL_UPLOAD_NAME_MAX_CHARS:
        return safe_name

    path = Path(safe_name)
    suffix = path.suffix[:32]
    stem = path.stem[: TERMINAL_UPLOAD_NAME_MAX_CHARS - len(suffix)]
    return f"{stem}{suffix}" if stem else TERMINAL_UPLOAD_DEFAULT_NAME


def save_terminal_upload(
    repo_root: Path,
    content_type: str,
    raw: bytes,
) -> dict[str, Any]:
    if not content_type.lower().startswith("multipart/form-data"):
        raise ValueError("terminal upload must be multipart/form-data")

    message = BytesParser(policy=policy.default).parsebytes(
        b"Content-Type: "
        + content_type.encode("utf-8")
        + b"\r\nMIME-Version: 1.0\r\n\r\n"
        + raw
    )
    if not message.is_multipart():
        raise ValueError("terminal upload body is not multipart")

    file_part = None
    for part in message.iter_parts():
        disposition = part.get_content_disposition()
        if disposition == "form-data" and part.get_param("name", header="content-disposition") == "file":
            file_part = part
            break
    if file_part is None:
        raise ValueError("terminal upload is missing file field")

    data = file_part.get_payload(decode=True)
    if not data:
        raise ValueError("terminal upload file is empty")
    if len(data) > TERMINAL_UPLOAD_MAX_BYTES:
        raise ValueError("terminal upload file is too large")

    part_content_type = file_part.get_content_type() or "application/octet-stream"
    safe_name = _safe_terminal_upload_name(file_part.get_filename())
    stamp = time.strftime("%Y%m%d-%H%M%S")
    cache_root = user_devota_cache_dir()
    dest_dir = cache_root / "terminal-uploads" / time.strftime("%Y-%m-%d")
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"{stamp}-{uuid.uuid4().hex[:8]}-{safe_name}"
    dest.write_bytes(data)
    rel = dest.relative_to(cache_root).as_posix()
    payload: dict[str, Any] = {
        "status": "ok",
        "filename": dest.name,
        "bytes": len(data),
        "contentType": part_content_type,
        "cacheRoot": str(cache_root),
        "relativePath": rel,
        "path": str(dest),
        "terminalText": f"read this file: {dest}",
    }
    if is_wsl():
        try:
            payload["windowsPath"] = wsl_path_to_windows(dest)
        except Exception:
            pass
    return payload


def backup_path(repo_root: Path) -> Path:
    return repo_root / ".devota-cache" / "phone-backup" / "profile.json"


def read_profile_backup(repo_root: Path) -> dict[str, Any]:
    path = backup_path(repo_root)
    if not path.is_file():
        raise FileNotFoundError("no DevOTA profile backup has been saved")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("format") != "devota-backup":
        raise ValueError("saved profile backup is invalid")
    return data


def write_profile_backup(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    if payload.get("format") != "devota-backup":
        raise ValueError("not a DevOTA backup")
    path = backup_path(repo_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    text = json.dumps(payload, indent=2)
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)
    return {
        "status": "ok",
        "path": str(path),
        "bytes": path.stat().st_size,
    }


def macros_path(repo_root: Path) -> Path:
    return repo_root / ".devota-cache" / "macros" / "terminal-macros.json"


def new_macro_id(prefix: str) -> str:
    return f"{prefix}-{int(time.time() * 1_000_000)}-{uuid.uuid4().hex[:8]}"


def normalize_macro_step(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("macro step must be an object")
    step_type = str(raw.get("type") or "shell")
    if step_type not in MACRO_STEP_TYPES:
        raise ValueError(f"unsupported macro step type: {step_type}")
    raw_delay = raw.get("delaySeconds", 0)
    if isinstance(raw_delay, (int, float)):
        delay = float(raw_delay)
    else:
        delay = float(str(raw_delay or "0"))
    if delay < 0:
        delay = 0
    return {
        "id": str(raw.get("id") or new_macro_id("step")),
        "type": step_type,
        "value": str(raw.get("value") if raw.get("value") is not None else MACRO_STEP_DEFAULT_VALUES[step_type]),
        "delaySeconds": delay,
    }


def normalize_macro(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ValueError("macro must be an object")
    name = str(raw.get("name") or "Macro").strip()
    if not name:
        raise ValueError("macro name is required")
    steps_raw = raw.get("steps")
    if not isinstance(steps_raw, list) or not steps_raw:
        raise ValueError("macro steps must be a non-empty list")
    return {
        "id": str(raw.get("id") or new_macro_id("macro")),
        "name": name,
        "steps": [normalize_macro_step(step) for step in steps_raw],
    }


def normalize_macro_usage_counts(raw: Any, macro_ids: set[str] | None = None) -> dict[str, int]:
    if not isinstance(raw, dict):
        return {}
    counts: dict[str, int] = {}
    for key, value in raw.items():
        macro_id = str(key)
        if macro_ids is not None and macro_id not in macro_ids:
            continue
        try:
            count = int(value)
        except (TypeError, ValueError):
            count = 0
        counts[macro_id] = max(0, count)
    return counts


def macro_store_payload(macros: list[dict[str, Any]], usage_counts: dict[str, int]) -> dict[str, Any]:
    macro_ids = {macro["id"] for macro in macros}
    return {
        "format": MACRO_STORE_FORMAT,
        "version": MACRO_STORE_VERSION,
        "updatedAt": now_iso(),
        "macros": macros,
        "usageCounts": normalize_macro_usage_counts(usage_counts, macro_ids),
    }


def write_macros_store(repo_root: Path, store: dict[str, Any]) -> dict[str, Any]:
    path = macros_path(repo_root)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(store, indent=2), encoding="utf-8")
    tmp.replace(path)
    return store


def bootstrap_macros_store(repo_root: Path) -> dict[str, Any]:
    macros: list[dict[str, Any]] = []
    usage_counts: dict[str, int] = {}
    try:
        backup = read_profile_backup(repo_root)
        shared = backup.get("sharedPreferences") if isinstance(backup, dict) else None
        if isinstance(shared, dict):
            macros_json = shared.get("macros_json")
            if isinstance(macros_json, str) and macros_json.strip():
                decoded = json.loads(macros_json)
                if isinstance(decoded, list):
                    macros = [normalize_macro(item) for item in decoded]
            counts_json = shared.get("macro_usage_counts_json")
            if isinstance(counts_json, str) and counts_json.strip():
                decoded_counts = json.loads(counts_json)
                usage_counts = normalize_macro_usage_counts(decoded_counts, {macro["id"] for macro in macros})
    except FileNotFoundError:
        pass
    return write_macros_store(repo_root, macro_store_payload(macros, usage_counts))


def read_macros_store(repo_root: Path) -> dict[str, Any]:
    path = macros_path(repo_root)
    if not path.is_file():
        return bootstrap_macros_store(repo_root)
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or data.get("format") != MACRO_STORE_FORMAT:
        raise ValueError("saved macros store is invalid")
    macros_raw = data.get("macros")
    if not isinstance(macros_raw, list):
        raise ValueError("saved macros store is missing macros")
    macros = [normalize_macro(item) for item in macros_raw]
    usage_counts = normalize_macro_usage_counts(data.get("usageCounts"), {macro["id"] for macro in macros})
    return {
        "format": MACRO_STORE_FORMAT,
        "version": int(data.get("version") or MACRO_STORE_VERSION),
        "updatedAt": str(data.get("updatedAt") or ""),
        "macros": macros,
        "usageCounts": usage_counts,
    }


def public_macros_store(store: dict[str, Any]) -> dict[str, Any]:
    return {
        "status": "ok",
        "version": store.get("version", MACRO_STORE_VERSION),
        "updatedAt": store.get("updatedAt", ""),
        "macros": store.get("macros", []),
        "usageCounts": store.get("usageCounts", {}),
    }


def list_macros(repo_root: Path) -> dict[str, Any]:
    return public_macros_store(read_macros_store(repo_root))


def create_macro(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    store = read_macros_store(repo_root)
    raw_macro = payload.get("macro") if isinstance(payload.get("macro"), dict) else payload
    macro = normalize_macro(raw_macro)
    existing_ids = {item["id"] for item in store["macros"]}
    if macro["id"] in existing_ids:
        macro["id"] = new_macro_id("macro")
        macro["steps"] = [
            {**step, "id": step["id"] or new_macro_id("step")}
            for step in macro["steps"]
        ]
    macros = [*store["macros"], macro]
    next_store = write_macros_store(repo_root, macro_store_payload(macros, store.get("usageCounts", {})))
    return {"status": "ok", "item": macro, "macros": next_store["macros"], "usageCounts": next_store["usageCounts"]}


def sync_macros(repo_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    macros_raw = payload.get("macros")
    if not isinstance(macros_raw, list):
        raise ValueError("macros must be a list")
    macros = [normalize_macro(item) for item in macros_raw]
    usage_counts = normalize_macro_usage_counts(payload.get("usageCounts"), {macro["id"] for macro in macros})
    store = write_macros_store(repo_root, macro_store_payload(macros, usage_counts))
    return public_macros_store(store)


def update_macro(repo_root: Path, macro_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    store = read_macros_store(repo_root)
    raw_update = payload.get("macro") if isinstance(payload.get("macro"), dict) else payload
    if not isinstance(raw_update, dict):
        raise ValueError("macro update must be an object")
    updated_item = None
    macros = []
    for macro in store["macros"]:
        if macro["id"] != macro_id:
            macros.append(macro)
            continue
        merged = dict(macro)
        if "name" in raw_update:
            merged["name"] = raw_update.get("name")
        if "steps" in raw_update:
            merged["steps"] = raw_update.get("steps")
        merged["id"] = macro_id
        updated_item = normalize_macro(merged)
        macros.append(updated_item)
    if updated_item is None:
        raise FileNotFoundError("macro not found")
    next_store = write_macros_store(repo_root, macro_store_payload(macros, store.get("usageCounts", {})))
    return {"status": "ok", "item": updated_item, "macros": next_store["macros"], "usageCounts": next_store["usageCounts"]}


def delete_macro(repo_root: Path, macro_id: str) -> dict[str, Any]:
    store = read_macros_store(repo_root)
    macros = [macro for macro in store["macros"] if macro["id"] != macro_id]
    if len(macros) == len(store["macros"]):
        raise FileNotFoundError("macro not found")
    usage_counts = dict(store.get("usageCounts", {}))
    usage_counts.pop(macro_id, None)
    next_store = write_macros_store(repo_root, macro_store_payload(macros, usage_counts))
    return {"status": "ok", "deletedId": macro_id, "macros": next_store["macros"], "usageCounts": next_store["usageCounts"]}


def validate_github_repo(repo: str) -> str:
    value = repo.strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
        raise ValueError("repo must look like owner/name")
    return value


def validate_github_name(value: str, label: str) -> str:
    text = value.strip()
    if not text or len(text) > 120 or not re.fullmatch(r"[A-Za-z0-9_.@/-]+", text):
        raise ValueError(f"invalid {label}")
    return text


def require_gh() -> str:
    gh = shutil.which("gh")
    if not gh:
        raise RuntimeError("GitHub CLI `gh` is not installed on the build server")
    return gh


def run_gh(args: list[str], timeout: int = 60) -> subprocess.CompletedProcess[str]:
    gh = require_gh()
    proc = subprocess.run(
        [gh, *args],
        text=True,
        timeout=timeout,
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or f"gh exited {proc.returncode}")
    return proc


def github_runs(repo: str, workflow: str, limit: int = 5) -> list[dict[str, Any]]:
    repo = validate_github_repo(repo)
    workflow = validate_github_name(workflow, "workflow")
    limit = max(1, min(limit, 20))
    proc = run_gh([
        "run",
        "list",
        "--repo",
        repo,
        "--workflow",
        workflow,
        "--limit",
        str(limit),
        "--json",
        "databaseId,status,conclusion,url,headBranch,displayTitle,createdAt,updatedAt",
    ])
    data = json.loads(proc.stdout or "[]")
    if not isinstance(data, list):
        raise RuntimeError("unexpected gh run list response")
    return [dict(item) for item in data if isinstance(item, dict)]


def dispatch_github_workflow(repo: str, workflow: str, ref: str) -> dict[str, Any]:
    repo = validate_github_repo(repo)
    workflow = validate_github_name(workflow, "workflow")
    ref = validate_github_name(ref or "main", "ref")
    run_gh(["workflow", "run", workflow, "--repo", repo, "--ref", ref], timeout=45)
    time.sleep(2)
    return {
        "status": "ok",
        "repo": repo,
        "workflow": workflow,
        "ref": ref,
        "runs": github_runs(repo, workflow, limit=5),
    }


def latest_successful_run_id(repo: str, workflow: str) -> int:
    repo = validate_github_repo(repo)
    workflow = validate_github_name(workflow, "workflow")
    proc = run_gh([
        "run",
        "list",
        "--repo",
        repo,
        "--workflow",
        workflow,
        "--status",
        "success",
        "--limit",
        "1",
        "--json",
        "databaseId",
    ])
    data = json.loads(proc.stdout or "[]")
    if not data:
        raise RuntimeError("no successful workflow runs found")
    return int(data[0]["databaseId"])


def download_github_artifact(
    repo_root: Path,
    repo: str,
    workflow: str,
    artifact_name: str,
    run_id: int | None,
) -> dict[str, Any]:
    repo = validate_github_repo(repo)
    workflow = validate_github_name(workflow, "workflow")
    artifact_name = validate_github_name(artifact_name, "artifact name")
    actual_run_id = run_id or latest_successful_run_id(repo, workflow)
    target_dir = repo_root / ".devota-cache" / "github-artifacts" / str(actual_run_id)
    if target_dir.exists():
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)
    run_gh([
        "run",
        "download",
        str(actual_run_id),
        "--repo",
        repo,
        "--name",
        artifact_name,
        "--dir",
        str(target_dir),
    ], timeout=180)
    apks = scan_github_artifact_apks(repo_root)
    run_apks = [build for build in apks if f"/{actual_run_id}/" in f"/{build['path']}"]
    return {
        "status": "ok",
        "repo": repo,
        "workflow": workflow,
        "runId": actual_run_id,
        "artifactName": artifact_name,
        "directory": str(target_dir),
        "apks": run_apks,
    }


def make_handler(repo_root: Path, manifest_path: Path, manifest: dict[str, Any]):
    class DevotaHandler(SimpleHTTPRequestHandler):
        def send_json(self, payload: object, status: int = 200):
            data = json.dumps(payload, indent=2).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        def send_download(self, rel: str, head_only: bool = False):
            if rel.endswith(".gz"):
                rel = rel[:-3]
            try:
                target, cache_key = resolve_download_target(repo_root, manifest, rel)
            except PermissionError:
                self.send_error(403, "Forbidden")
                return
            except FileNotFoundError as exc:
                self.send_error(404, str(exc))
                return
            except ValueError as exc:
                self.send_error(400, str(exc))
                return
            if not target.is_file() or target.suffix != ".apk":
                self.send_error(404, "Not found")
                return
            gz_path = ensure_gz(repo_root, target, cache_key)
            size = gz_path.stat().st_size
            self.send_response(200)
            self.send_header("Content-Type", "application/gzip")
            self.send_header("Content-Disposition", f'attachment; filename="{target.stem}.apk.gz"')
            self.send_header("Content-Length", str(size))
            self.end_headers()
            if head_only:
                return
            with open(gz_path, "rb") as f:
                while chunk := f.read(65536):
                    self.wfile.write(chunk)

        def apps_payload(self):
            builds = scan_apks(repo_root, manifest)
            by_app = {app["id"]: [] for app in manifest["apps"]}
            for build in builds:
                by_app.setdefault(build["appId"], []).append(build)
            return [
                {
                    **public_app(app),
                    "buildCount": len(by_app.get(app["id"], [])),
                    "latestBuild": by_app.get(app["id"], [None])[0],
                }
                for app in manifest["apps"]
            ]

        def do_POST(self):
            path = unquote(urlparse(self.path).path)
            if path == "/macros" or path == "/macros/sync":
                try:
                    payload = parse_json_request(self, max_bytes=512 * 1024)
                    result = sync_macros(repo_root, payload) if path == "/macros/sync" else create_macro(repo_root, payload)
                    self.send_json(result)
                except Exception as exc:
                    self.send_error(400, f"Macros request failed: {exc}")
                return

            if path.startswith("/projects"):
                try:
                    payload = parse_json_request(self, max_bytes=2 * 1024 * 1024)
                    self.send_json(handle_projects_post(repo_root, path, payload))
                except FileNotFoundError as exc:
                    self.send_error(404, str(exc))
                except Exception as exc:
                    self.send_error(400, f"Projects request failed: {exc}")
                return

            if path == "/github/workflow/run":
                try:
                    payload = parse_json_request(self)
                    result = dispatch_github_workflow(
                        str(payload.get("repo") or ""),
                        str(payload.get("workflow") or "android.yml"),
                        str(payload.get("ref") or "main"),
                    )
                    self.send_json(result)
                except Exception as exc:
                    self.send_error(400, f"GitHub workflow dispatch failed: {exc}")
                return

            if path == "/github/workflow/download":
                try:
                    payload = parse_json_request(self)
                    run_id_raw = payload.get("runId")
                    run_id = int(run_id_raw) if run_id_raw not in (None, "") else None
                    result = download_github_artifact(
                        repo_root,
                        str(payload.get("repo") or ""),
                        str(payload.get("workflow") or "android.yml"),
                        str(payload.get("artifactName") or "devota-android-debug-apks"),
                        run_id,
                    )
                    self.send_json(result)
                except Exception as exc:
                    self.send_error(400, f"GitHub artifact download failed: {exc}")
                return

            if path == "/backup/profile":
                try:
                    payload = parse_json_request(self, max_bytes=2 * 1024 * 1024)
                    self.send_json(write_profile_backup(repo_root, payload))
                except Exception as exc:
                    self.send_error(400, f"Profile backup failed: {exc}")
                return

            if path == "/terminal/upload":
                length = int(self.headers.get("Content-Length", 0) or 0)
                if length <= 0:
                    self.send_error(400, "Empty body")
                    return
                if length > TERMINAL_UPLOAD_MAX_BYTES + (1024 * 1024):
                    self.send_error(413, "Payload too large")
                    return
                try:
                    raw = self.rfile.read(length)
                    self.send_json(
                        save_terminal_upload(
                            repo_root,
                            self.headers.get("Content-Type", ""),
                            raw,
                        )
                    )
                except Exception as exc:
                    self.send_error(400, f"Terminal upload failed: {exc}")
                return

            if path == "/ssh/authorized-key":
                length = int(self.headers.get("Content-Length", 0) or 0)
                if length <= 0:
                    self.send_error(400, "Empty body")
                    return
                if length > 32 * 1024:
                    self.send_error(413, "Payload too large")
                    return
                raw = self.rfile.read(length)
                try:
                    text = raw.decode("utf-8")
                    if self.headers.get("Content-Type", "").startswith("application/json"):
                        payload = json.loads(text)
                        public_key = str(payload.get("publicKey") or "")
                        target = str(payload.get("target") or "auto")
                        windows_user = payload.get("windowsUser")
                        windows_user = str(windows_user) if windows_user else None
                    else:
                        public_key = text
                        target = "auto"
                        windows_user = None
                    public_key = validate_public_key_line(public_key)
                    self.send_json(install_authorized_key(target, public_key, windows_user))
                except Exception as exc:
                    self.send_error(400, f"SSH public key install failed: {exc}")
                return

            if path == "/clipboard":
                length = int(self.headers.get("Content-Length", 0) or 0)
                if length <= 0:
                    self.send_error(400, "Empty body")
                    return
                if length > 256 * 1024:
                    self.send_error(413, "Payload too large")
                    return
                raw = self.rfile.read(length)
                try:
                    text = raw.decode("utf-8")
                except UnicodeDecodeError:
                    self.send_error(400, "Invalid UTF-8")
                    return
                ok, err = set_host_clipboard(text)
                if not ok:
                    self.send_error(500, f"Clipboard failed: {err}")
                    return
                self.send_json({"status": "ok", "bytes": len(raw)})
                return
            self.send_error(404, "Not found. Use POST /clipboard, POST /terminal/upload, or /projects endpoints")

        def do_PATCH(self):
            path = unquote(urlparse(self.path).path)
            match = re.fullmatch(r"/macros/([^/]+)", path)
            if match:
                try:
                    payload = parse_json_request(self, max_bytes=512 * 1024)
                    self.send_json(update_macro(repo_root, match.group(1), payload))
                except FileNotFoundError as exc:
                    self.send_error(404, str(exc))
                except Exception as exc:
                    self.send_error(400, f"Macros update failed: {exc}")
                return

            if path.startswith("/projects"):
                try:
                    payload = parse_json_request(self, max_bytes=2 * 1024 * 1024)
                    self.send_json(handle_projects_patch(repo_root, path, payload))
                except FileNotFoundError as exc:
                    self.send_error(404, str(exc))
                except Exception as exc:
                    self.send_error(400, f"Projects update failed: {exc}")
                return
            self.send_error(404, "Not found. Use /projects endpoints")

        def do_DELETE(self):
            path = unquote(urlparse(self.path).path)
            match = re.fullmatch(r"/macros/([^/]+)", path)
            if match:
                try:
                    self.send_json(delete_macro(repo_root, match.group(1)))
                except FileNotFoundError as exc:
                    self.send_error(404, str(exc))
                except Exception as exc:
                    self.send_error(400, f"Macros delete failed: {exc}")
                return
            self.send_error(404, "Not found. Use /macros/<id>")

        def do_HEAD(self):
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            if path.startswith("/download/"):
                self.send_download(path[len("/download/"):], head_only=True)
                return
            if path in ("/health", "/apps", "/builds", "/latest", "/backup/profile", "/macros"):
                self.do_GET()
                return
            self.send_error(404, "Not found")

        def do_GET(self):
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            query = parse_qs(parsed.query)

            if path == "/health":
                self.send_json({
                    "status": "ok",
                    "repoRoot": str(repo_root),
                    "manifest": str(manifest_path),
                    "apps": [public_app(app) for app in manifest["apps"]],
                })
                return

            if path == "/apps":
                self.send_json(self.apps_payload())
                return

            if path == "/macros":
                try:
                    self.send_json(list_macros(repo_root))
                except Exception as exc:
                    self.send_error(500, f"Macros read failed: {exc}")
                return

            if path == "/builds":
                app_id = query.get("app", [None])[0]
                self.send_json(scan_apks(repo_root, manifest, app_id))
                return

            if path == "/latest":
                app_id = query.get("app", [None])[0]
                build = latest_apk(repo_root, manifest, app_id)
                if build is None:
                    self.send_error(404, f"No build found for app: {app_id or 'any'}")
                    return
                self.send_json(build)
                return

            if path == "/github/workflow/runs":
                try:
                    repo = query.get("repo", [""])[0]
                    workflow = query.get("workflow", ["android.yml"])[0]
                    limit = int(query.get("limit", ["5"])[0])
                    self.send_json({
                        "status": "ok",
                        "repo": validate_github_repo(repo),
                        "workflow": validate_github_name(workflow, "workflow"),
                        "runs": github_runs(repo, workflow, limit),
                    })
                except Exception as exc:
                    self.send_error(400, f"GitHub workflow list failed: {exc}")
                return

            if path == "/backup/profile":
                try:
                    self.send_json(read_profile_backup(repo_root))
                except FileNotFoundError as exc:
                    self.send_error(404, str(exc))
                except Exception as exc:
                    self.send_error(500, f"Profile backup read failed: {exc}")
                return

            if path.startswith("/projects"):
                try:
                    self.send_json(handle_projects_get(repo_root, path))
                except FileNotFoundError as exc:
                    self.send_error(404, str(exc))
                except Exception as exc:
                    self.send_error(400, f"Projects request failed: {exc}")
                return

            if path.startswith("/download/"):
                self.send_download(path[len("/download/"):])
                return

            self.send_error(404, "Not found. Use /health, /apps, /builds, /latest, /backup/profile, /projects/board, /download/<path>, POST /clipboard, or POST /terminal/upload")

        def log_message(self, format, *args):
            print(f"[{self.log_date_time_string()}] {format % args}")

    return DevotaHandler


def main():
    parser = argparse.ArgumentParser(description="Serve DevOTA Android APK builds over HTTP")
    parser.add_argument("--host", default="0.0.0.0", help="Interface to bind, for example 0.0.0.0 or 127.0.0.1")
    parser.add_argument("--port", type=int, default=8082)
    parser.add_argument("--repo-root", default=".", help="Repository containing devota.yaml and APK outputs")
    parser.add_argument("--manifest", help="Manifest path, relative to --repo-root unless absolute")
    parser.add_argument("--no-mdns", action="store_true", help="Disable LAN discovery advertisement")
    parser.add_argument("--mdns-name", default="DevOTA", help="LAN discovery service name")
    args = parser.parse_args()

    repo_root = Path(args.repo_root).expanduser().resolve()
    try:
        manifest_path = find_manifest(repo_root, args.manifest).resolve()
        manifest = load_manifest(manifest_path, repo_root)
    except Exception as exc:
        raise SystemExit(f"DevOTA server configuration error: {exc}") from exc

    handler = make_handler(repo_root, manifest_path, manifest)
    server = ThreadingHTTPServer((args.host, args.port), handler)
    print(f"DevOTA build server listening on http://{args.host}:{args.port}")
    print(f"Repo root: {repo_root}")
    print(f"Manifest: {manifest_path}")
    print(f"Apps: {', '.join(app['id'] for app in manifest['apps'])}")
    zeroconf = info = None
    if not args.no_mdns:
        zeroconf, info = start_mdns(args.host, args.port, args.mdns_name, manifest)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        if zeroconf is not None and info is not None:
            try:
                zeroconf.unregister_service(info)
            finally:
                zeroconf.close()
        server.server_close()


if __name__ == "__main__":
    main()
