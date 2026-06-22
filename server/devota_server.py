#!/usr/bin/env python3
"""Serve Android APK builds described by a devota.yaml manifest."""

from __future__ import annotations

import argparse
import gzip
import json
import os
import platform
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

DEFAULT_MANIFEST_NAMES = ("devota.yaml", "devota.yml", "devota.json")
GZIP_LOCK = threading.Lock()


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
    builds.sort(key=lambda item: item["modifiedMs"], reverse=True)
    return builds


def latest_apk(repo_root: Path, manifest: dict[str, Any], app_id: str | None = None) -> dict[str, Any] | None:
    builds = scan_apks(repo_root, manifest, app_id)
    return builds[0] if builds else None


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
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
