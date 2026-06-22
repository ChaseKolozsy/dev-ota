#!/usr/bin/env python3
"""Serve Android APK builds described by a devota.yaml manifest."""

from __future__ import annotations

import argparse
import base64
import gzip
import json
import os
import platform
import re
import shutil
import socket
import subprocess
import threading
import time
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

        build_dirs = app.get("buildDirs")
        if not isinstance(build_dirs, list) or not build_dirs:
            raise ManifestError(f"{app_id}.buildDirs must be a non-empty list")
        resolved_dirs = []
        for rel in build_dirs:
            rel_text = str(rel).strip()
            if not rel_text:
                continue
            target = (repo_root / rel_text).resolve()
            if not is_relative_to(target, repo_root):
                raise ManifestError(f"{app_id}.buildDirs entry escapes repo root: {rel_text}")
            resolved_dirs.append({"relative": rel_text, "absolute": target})

        normalized.append({
            "id": app_id,
            "label": str(app.get("label") or app_id),
            "packageName": str(app.get("packageName") or ""),
            "notes": str(app.get("notes") or ""),
            "buildDirs": resolved_dirs,
        })

    return {
        "version": data.get("version", 1),
        "apps": normalized,
    }


def public_app(app: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": app["id"],
        "label": app["label"],
        "packageName": app["packageName"],
        "notes": app["notes"],
        "buildDirs": [entry["relative"] for entry in app["buildDirs"]],
    }


def gzip_cache_path(repo_root: Path, rel_path: str) -> Path:
    safe = rel_path.replace("/", "__").replace("\\", "__")
    return repo_root / ".devota-cache" / "gzip" / f"{safe}.gz"


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
        for build_dir in app["buildDirs"]:
            apk_dir = build_dir["absolute"]
            if not apk_dir.is_dir():
                continue
            for apk in apk_dir.rglob("*.apk"):
                real = apk.resolve()
                if real in seen or not is_relative_to(real, repo_root):
                    continue
                seen.add(real)
                stat = apk.stat()
                rel = apk.relative_to(repo_root).as_posix()
                gz = ensure_gz(repo_root, apk, rel)
                gz_stat = gz.stat()
                builds.append({
                    "filename": apk.name,
                    "size": stat.st_size,
                    "compressed_size": gz_stat.st_size,
                    "modified": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(stat.st_mtime)),
                    "modifiedMs": int(stat.st_mtime * 1000),
                    "path": rel,
                    "appId": app["id"],
                    "appLabel": app["label"],
                    "packageName": app["packageName"],
                    "kind": app["id"],
                })
    builds.extend(scan_github_artifact_apks(repo_root, app_id))
    builds.sort(key=lambda item: item["modifiedMs"], reverse=True)
    return builds


def latest_apk(repo_root: Path, manifest: dict[str, Any], app_id: str | None = None) -> dict[str, Any] | None:
    builds = scan_apks(repo_root, manifest, app_id)
    return builds[0] if builds else None


def github_artifact_metadata(apk: Path) -> dict[str, str]:
    name = apk.name.lower()
    if "build-installer" in name or "legacy" in name or "upgrade" in name:
        return {
            "appId": "build_installer",
            "appLabel": "DevOTA Legacy Upgrade",
            "packageName": "com.arachnomind.devtools.build_installer",
        }
    return {
        "appId": "devota",
        "appLabel": "DevOTA",
        "packageName": "io.github.chasekolozsy.devota",
    }


def scan_github_artifact_apks(repo_root: Path, app_id: str | None = None) -> list[dict[str, Any]]:
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
        command = (
            "Start-Process -FilePath powershell.exe -Verb RunAs "
            f"-ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File','{script_win}','-KeyFile','{key_win}')"
        )
        proc = subprocess.run(
            ["powershell.exe", "-NoProfile", "-Command", command],
            text=True,
            timeout=12,
            capture_output=True,
        )
        if proc.returncode != 0:
            return False, proc.stderr.strip() or f"Start-Process exited {proc.returncode}"
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
            "Windows administrator approval requested. Accept the UAC prompt on the computer, then try SSH."
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
            target = (repo_root / rel).resolve()
            if not is_relative_to(target, repo_root):
                self.send_error(403, "Forbidden")
                return
            if not target.is_file() or target.suffix != ".apk":
                self.send_error(404, "Not found")
                return
            gz_path = ensure_gz(repo_root, target, target.relative_to(repo_root).as_posix())
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
            self.send_error(404, "Not found. Use POST /clipboard")

        def do_HEAD(self):
            parsed = urlparse(self.path)
            path = unquote(parsed.path)
            if path.startswith("/download/"):
                self.send_download(path[len("/download/"):], head_only=True)
                return
            if path in ("/health", "/apps", "/builds", "/latest"):
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

            if path.startswith("/download/"):
                self.send_download(path[len("/download/"):])
                return

            self.send_error(404, "Not found. Use /health, /apps, /builds, /latest, /download/<path>, or POST /clipboard")

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
