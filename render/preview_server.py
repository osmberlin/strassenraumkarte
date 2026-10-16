#!/usr/bin/env python3
"""
Local preview server for render/tiles/preview.html.

Serves XYZ tiles and preview.html, lists local PBFs under data/osm, can
start ./run.sh with a bbox + data source chosen in the UI, and can overlay
a second local XYZ tile directory for comparison.

Usage (from repository root):
  ./render/preview_server.py
  # then open http://127.0.0.1:8000/preview.html
"""

from __future__ import annotations

import json
import math
import mimetypes
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

REPO_ROOT = Path(__file__).resolve().parent.parent
TILES_DIR = REPO_ROOT / "render" / "tiles"
OSM_DIR = REPO_ROOT / "data" / "osm"
RUN_SCRIPT = REPO_ROOT / "run.sh"

HOST = os.environ.get("PREVIEW_HOST", "127.0.0.1")
PORT = int(os.environ.get("PREVIEW_PORT", "8000"))

BBOX_RE = re.compile(
    r"^-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?$"
)
GEOFABRIK_RE = re.compile(
    r"^https://download\.geofabrik\.de/[A-Za-z0-9_./-]+\.osm\.pbf$"
)

_run_lock = threading.Lock()
_compare_lock = threading.Lock()
_pick_lock = threading.Lock()
_compare_root: Path | None = None
_run_state: dict = {
    "running": False,
    "pid": None,
    "started_at": None,
    "finished_at": None,
    "exit_code": None,
    "command": None,
    "lines": [],
}
_run_proc: subprocess.Popen | None = None


def _json_bytes(payload: dict, status: int = 200) -> tuple[int, bytes, str]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    return status, body, "application/json; charset=utf-8"


def list_local_pbfs() -> list[dict]:
    OSM_DIR.mkdir(parents=True, exist_ok=True)
    files = []
    for path in sorted(OSM_DIR.iterdir()):
        if not path.is_file():
            continue
        name = path.name
        if not (name.endswith(".osm.pbf") or name.endswith(".pbf")):
            continue
        # Skip temporary extracts produced by the pipeline
        if name.startswith("extract_"):
            continue
        files.append(
            {
                "name": name,
                "path": f"data/osm/{name}",
                "size": path.stat().st_size,
            }
        )
    return files


def resolve_data_source(data: str) -> tuple[str | None, str | None]:
    """Return (resolved_arg_for_run_sh, error)."""
    data = (data or "").strip()
    if not data:
        return None, "data is required"

    if data.startswith("http://") or data.startswith("https://"):
        if not GEOFABRIK_RE.match(data):
            return (
                None,
                "Only https://download.geofabrik.de/.../*.osm.pbf URLs are allowed",
            )
        return data, None

    # Local path relative to repo root, must stay under data/osm
    rel = data.lstrip("./")
    if not rel.startswith("data/osm/"):
        return None, "Local data must be under data/osm/"
    candidate = (REPO_ROOT / rel).resolve()
    try:
        candidate.relative_to(OSM_DIR.resolve())
    except ValueError:
        return None, "Local data path escapes data/osm/"
    if not candidate.is_file():
        return None, f"File not found: {rel}"
    return str(candidate.relative_to(REPO_ROOT)), None


def parse_bbox(bbox: str) -> tuple[str | None, str | None]:
    bbox = (bbox or "").strip()
    if not bbox:
        return None, "bbox is required"
    if not BBOX_RE.match(bbox):
        return None, "bbox must be xmin,ymin,xmax,ymax (WGS84)"
    parts = [float(x) for x in bbox.split(",")]
    xmin, ymin, xmax, ymax = parts
    if not (-180 <= xmin < xmax <= 180 and -90 <= ymin < ymax <= 90):
        return None, "bbox coordinates out of range or unordered"
    # Keep original formatting precision from client
    return bbox, None


def append_log(line: str) -> None:
    lines = _run_state["lines"]
    lines.append(line.rstrip("\n"))
    # Cap memory usage for long runs
    if len(lines) > 5000:
        del lines[: len(lines) - 5000]


def _reader_thread(proc: subprocess.Popen) -> None:
    assert proc.stdout is not None
    try:
        for raw in proc.stdout:
            append_log(raw.rstrip("\n"))
    finally:
        code = proc.wait()
        with _run_lock:
            _run_state["running"] = False
            _run_state["exit_code"] = code
            _run_state["finished_at"] = time.time()
            _run_state["pid"] = None
            append_log(f"[preview] run.sh exited with code {code}")


def start_run(
    data: str,
    bbox: str,
    *,
    refresh: bool = False,
    skip_render: bool = False,
    render_only: bool = False,
    zmin: int | None = None,
    zmax: int | None = None,
    tile_format: str | None = None,
    quality: int | None = None,
    jobs: int | str | None = None,
    inside: bool = False,
) -> tuple[dict, int]:
    global _run_proc

    if render_only and skip_render:
        return {
            "ok": False,
            "error": "--render-only and --skip-render cannot be used together",
        }, 400

    bbox_ok, err = parse_bbox(bbox)
    if err:
        return {"ok": False, "error": err}, 400

    if render_only:
        cmd = [str(RUN_SCRIPT), "--render-only", "--bbox", bbox_ok]
    else:
        resolved, err = resolve_data_source(data)
        if err:
            return {"ok": False, "error": err}, 400
        cmd = [str(RUN_SCRIPT), "--data", resolved, "--bbox", bbox_ok]
        if refresh:
            cmd.append("--refresh")
        if skip_render:
            cmd.append("--skip-render")
    if zmin is not None:
        cmd.extend(["--zmin", str(zmin)])
    if zmax is not None:
        cmd.extend(["--zmax", str(zmax)])
    if tile_format is not None:
        cmd.extend(["--format", tile_format])
    if quality is not None:
        cmd.extend(["--quality", str(quality)])
    if jobs is not None:
        cmd.extend(["--jobs", str(jobs)])
    if inside:
        cmd.append("--inside")

    with _run_lock:
        if _run_state["running"]:
            return {"ok": False, "error": "A run is already in progress"}, 409
        _run_state.update(
            {
                "running": True,
                "pid": None,
                "started_at": time.time(),
                "finished_at": None,
                "exit_code": None,
                "command": " ".join(cmd),
                "lines": [
                    f"[preview] Starting: {' '.join(cmd)}",
                ],
            }
        )

    try:
        proc = subprocess.Popen(
            cmd,
            cwd=str(REPO_ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
    except OSError as exc:
        with _run_lock:
            _run_state["running"] = False
            _run_state["exit_code"] = 1
            _run_state["finished_at"] = time.time()
            append_log(f"[preview] Failed to start: {exc}")
        return {"ok": False, "error": str(exc)}, 500

    with _run_lock:
        _run_proc = proc
        _run_state["pid"] = proc.pid

    threading.Thread(target=_reader_thread, args=(proc,), daemon=True).start()
    return {
        "ok": True,
        "pid": proc.pid,
        "command": _run_state["command"],
    }, 202


def stop_run() -> tuple[dict, int]:
    global _run_proc
    with _run_lock:
        proc = _run_proc
        if not _run_state["running"] or proc is None:
            return {"ok": False, "error": "No run in progress"}, 409
        pid = proc.pid
    try:
        os.killpg(pid, signal.SIGTERM)
        append_log(f"[preview] Sent SIGTERM to process group {pid}")
    except ProcessLookupError:
        append_log("[preview] Process already gone")
    return {"ok": True}, 200


def run_status(since: int = 0) -> dict:
    with _run_lock:
        lines = _run_state["lines"]
        return {
            "running": _run_state["running"],
            "pid": _run_state["pid"],
            "started_at": _run_state["started_at"],
            "finished_at": _run_state["finished_at"],
            "exit_code": _run_state["exit_code"],
            "command": _run_state["command"],
            "since": since,
            "next": len(lines),
            "lines": lines[since:],
        }


TILE_PATH_RE = re.compile(r"^/(\d+)/(\d+)/(\d+)\.(jpg|jpeg|png|webp)$", re.IGNORECASE)
COMPARE_TILE_PATH_RE = re.compile(
    r"^/compare/(\d+)/(\d+)/(\d+)\.(jpg|jpeg|png|webp)$", re.IGNORECASE
)
TILE_FORMATS = ("webp", "jpg", "png")
DEFAULT_START_ZOOM = 17


def tile_format_info(root: Path | None = None) -> dict:
    """Count tile files, suggest preview format, and locate a start view."""
    counts = {"webp": 0, "jpg": 0, "png": 0}
    directory = TILES_DIR if root is None else root
    if directory.is_dir():
        for path in directory.rglob("*"):
            if not path.is_file():
                continue
            ext = path.suffix.lower()
            if ext == ".webp":
                counts["webp"] += 1
            elif ext in (".jpg", ".jpeg"):
                counts["jpg"] += 1
            elif ext == ".png":
                counts["png"] += 1
    # Most files wins; webp breaks ties and is the empty-dir default.
    suggested = max(TILE_FORMATS, key=lambda f: (counts[f], f == "webp"))
    payload: dict = {**counts, "suggested": suggested}
    view = tile_start_view(directory)
    if view:
        payload.update(view)
    return payload


def tile_latlon_bounds(x: int, y: int, z: int) -> tuple[float, float, float, float]:
    """Return (west, south, east, north) in WGS84 for one XYZ tile."""
    n = 2**z
    west = x / n * 360.0 - 180.0
    east = (x + 1) / n * 360.0 - 180.0

    def ty_to_lat(ty: int) -> float:
        return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * ty / n))))

    north = ty_to_lat(y)
    south = ty_to_lat(y + 1)
    return west, south, east, north


def list_zoom_levels(root: Path) -> list[int]:
    zooms: list[int] = []
    try:
        for child in root.iterdir():
            try:
                if child.is_dir() and _dir_name_is_zoom(child.name):
                    zooms.append(int(child.name))
            except OSError:
                continue
    except OSError:
        return []
    zooms.sort()
    return zooms


def scan_zoom_extent(root: Path, z: int) -> dict | None:
    """Bounding box and centre of all tiles present at zoom z."""
    zdir = root / str(z)
    if not zdir.is_dir():
        return None
    x_min: int | None = None
    x_max: int | None = None
    y_min: int | None = None
    y_max: int | None = None
    count = 0
    try:
        xdirs = list(zdir.iterdir())
    except OSError:
        return None
    for xdir in xdirs:
        try:
            if not xdir.is_dir() or not xdir.name.isdigit():
                continue
        except OSError:
            continue
        x = int(xdir.name)
        try:
            files = xdir.iterdir()
        except OSError:
            continue
        for f in files:
            try:
                if not f.is_file():
                    continue
            except OSError:
                continue
            if f.suffix.lower() not in (".webp", ".jpg", ".jpeg", ".png"):
                continue
            if not f.stem.isdigit():
                continue
            y = int(f.stem)
            if x_min is None:
                x_min = x_max = x
                y_min = y_max = y
            else:
                x_min = min(x_min, x)
                x_max = max(x_max, x)
                y_min = min(y_min, y)
                y_max = max(y_max, y)
            count += 1
    if count == 0 or x_min is None or x_max is None or y_min is None or y_max is None:
        return None
    west, _, _, north = tile_latlon_bounds(x_min, y_min, z)
    _, south, east, _ = tile_latlon_bounds(x_max, y_max, z)
    return {
        "zoom": z,
        "center": [(south + north) / 2.0, (west + east) / 2.0],
        "bounds": [west, south, east, north],
        "tiles": count,
    }


def tile_start_view(
    root: Path, preferred_zoom: int = DEFAULT_START_ZOOM
) -> dict | None:
    """
    Start view at preferred zoom if that zoom has tiles, else the closest
    zoom that does. Centre is the geographic middle of the tile bbox.
    """
    zooms = list_zoom_levels(root)
    if not zooms:
        return None
    ordered: list[int] = []
    if preferred_zoom in zooms:
        ordered.append(preferred_zoom)
    for z in sorted(zooms, key=lambda zoom: (abs(zoom - preferred_zoom), zoom)):
        if z not in ordered:
            ordered.append(z)
    for z in ordered:
        ext = scan_zoom_extent(root, z)
        if ext:
            return {**ext, "zooms": zooms}
    return None


def _is_under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


def resolve_tile_file(root: Path, z: str, x: str, y: str, ext: str) -> Path | None:
    """Resolve z/x/y.ext under root, with format fallback. z/x/y are digits only."""
    ext = ext.lower()
    if ext == "jpeg":
        ext = "jpg"
    suffixes = [ext] + [s for s in TILE_FORMATS if s != ext]
    try:
        root_resolved = root.resolve()
    except OSError:
        return None
    for suffix in suffixes:
        candidate = root / z / x / f"{y}.{suffix}"
        try:
            if not candidate.is_file():
                continue
            resolved = candidate.resolve()
        except OSError:
            continue
        if _is_under(resolved, root_resolved):
            return resolved
    return None


def resolve_tile_path(url_path: str) -> Path | None:
    """
    Resolve z/x/y.ext under TILES_DIR.

    If the requested extension is missing, fall back across webp/jpg/png so
    mixed-format directories still display after a format switch.
    """
    m = TILE_PATH_RE.match(url_path)
    if not m:
        return None
    z, x, y, ext = m.groups()
    return resolve_tile_file(TILES_DIR, z, x, y, ext)


def resolve_compare_tile_path(url_path: str) -> Path | None:
    m = COMPARE_TILE_PATH_RE.match(url_path)
    if not m:
        return None
    with _compare_lock:
        root = _compare_root
    if root is None:
        return None
    z, x, y, ext = m.groups()
    return resolve_tile_file(root, z, x, y, ext)


def _dir_name_is_zoom(name: str) -> bool:
    return name.isdigit() and 0 <= int(name) <= 30


def quick_tile_info(root: Path) -> dict:
    """Cheap XYZ-layout hint without walking the whole tree."""
    counts = {"webp": 0, "jpg": 0, "png": 0}
    zoom_levels: list[int] = []
    sampled = 0
    try:
        children = list(root.iterdir())
    except OSError:
        children = []
    for child in children:
        try:
            if not child.is_dir() or not _dir_name_is_zoom(child.name):
                continue
        except OSError:
            continue
        zoom_levels.append(int(child.name))
        if sampled >= 40:
            continue
        try:
            xdirs = [p for p in child.iterdir() if p.is_dir()]
        except OSError:
            continue
        for xdir in xdirs[:4]:
            try:
                files = xdir.iterdir()
            except OSError:
                continue
            for f in files:
                try:
                    if not f.is_file():
                        continue
                except OSError:
                    continue
                ext = f.suffix.lower()
                if ext == ".webp":
                    counts["webp"] += 1
                elif ext in (".jpg", ".jpeg"):
                    counts["jpg"] += 1
                elif ext == ".png":
                    counts["png"] += 1
                else:
                    continue
                sampled += 1
                if sampled >= 40:
                    break
            if sampled >= 40:
                break
    zoom_levels.sort()
    looks = bool(zoom_levels)
    suggested = max(TILE_FORMATS, key=lambda f: (counts[f], f == "webp"))
    return {
        "looks_like_tiles": looks,
        "zoom_levels": zoom_levels,
        "sample_counts": counts,
        "suggested": suggested if looks else None,
    }


def fs_shortcuts() -> list[dict]:
    items = []
    home = Path.home()
    if home.is_dir():
        items.append({"id": "home", "label": "Home", "path": str(home)})
    render_dir = REPO_ROOT / "render"
    if render_dir.is_dir():
        items.append({"id": "render", "label": "render/", "path": str(render_dir)})
    if TILES_DIR.is_dir():
        items.append(
            {"id": "tiles", "label": "Aktuelle Kacheln", "path": str(TILES_DIR)}
        )
    items.append({"id": "repo", "label": "Projekt", "path": str(REPO_ROOT)})
    return items


def default_browse_path() -> Path:
    render_dir = REPO_ROOT / "render"
    if render_dir.is_dir():
        return render_dir
    home = Path.home()
    if home.is_dir():
        return home
    return Path("/")


def browse_fs(raw_path: str | None) -> tuple[dict, int]:
    raw = (raw_path or "").strip()
    if raw:
        path = Path(raw).expanduser()
    else:
        path = default_browse_path()
    try:
        path = path.resolve()
    except OSError as exc:
        return {"ok": False, "error": str(exc)}, 400
    if not path.exists():
        return {"ok": False, "error": f"Pfad nicht gefunden: {path}"}, 404
    if not path.is_dir():
        return {"ok": False, "error": f"Kein Verzeichnis: {path}"}, 400

    parent = str(path.parent) if path.parent != path else None
    dirs: list[dict] = []
    read_error = None
    try:
        children = list(path.iterdir())
    except PermissionError:
        children = []
        read_error = "Keine Berechtigung zum Lesen dieses Verzeichnisses"
    except OSError as exc:
        children = []
        read_error = str(exc)

    for child in sorted(children, key=lambda p: p.name.lower()):
        try:
            if not child.is_dir():
                continue
        except OSError:
            continue
        dirs.append({"name": child.name, "path": str(child)})

    payload = {
        "ok": True,
        "path": str(path),
        "parent": parent,
        "dirs": dirs,
        "shortcuts": fs_shortcuts(),
        **quick_tile_info(path),
    }
    if read_error:
        payload["error"] = read_error
    return payload, 200


def compare_info() -> dict:
    with _compare_lock:
        root = _compare_root
    if root is None:
        return {"ok": True, "path": None, "suggested": None, "looks_like_tiles": False}
    info = quick_tile_info(root)
    return {"ok": True, "path": str(root), **info}


def set_compare_dir(raw_path: str | None) -> tuple[dict, int]:
    global _compare_root
    if raw_path is None or str(raw_path).strip() == "":
        with _compare_lock:
            _compare_root = None
        return {"ok": True, "path": None, "suggested": None, "looks_like_tiles": False}, 200

    path = Path(str(raw_path).strip()).expanduser()
    try:
        path = path.resolve()
    except OSError as exc:
        return {"ok": False, "error": str(exc)}, 400
    if not path.exists():
        return {"ok": False, "error": f"Pfad nicht gefunden: {path}"}, 404
    if not path.is_dir():
        return {"ok": False, "error": f"Kein Verzeichnis: {path}"}, 400

    info = quick_tile_info(path)
    with _compare_lock:
        _compare_root = path
    payload = {"ok": True, "path": str(path), **info}
    if not info["looks_like_tiles"]:
        payload["warning"] = (
            "Keine XYZ-Kacheln (z/x/y.{webp|jpg|png}) in diesem Verzeichnis gefunden"
        )
    return payload, 200


class _DialogCancel(Exception):
    """User closed the native folder dialog without a choice."""


class _DialogUnavailable(Exception):
    """No GUI folder dialog could be shown."""


def _normalize_start_dir(raw: str | None) -> str:
    if raw and str(raw).strip():
        p = Path(str(raw).strip()).expanduser()
        try:
            if p.is_dir():
                return str(p.resolve())
            if p.parent.is_dir():
                return str(p.parent.resolve())
        except OSError:
            pass
    with _compare_lock:
        root = _compare_root
    if root is not None:
        try:
            if root.is_dir():
                return str(root)
        except OSError:
            pass
    return str(default_browse_path())


def _dialog_filename(start: str) -> str:
    return start if start.endswith(os.sep) else start + os.sep


def _run_folder_dialog(cmd: list[str]) -> str:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            env=os.environ.copy(),
        )
    except OSError as exc:
        raise _DialogUnavailable(str(exc)) from exc
    err = (proc.stderr or "").strip()
    err_l = err.lower()
    if proc.returncode != 0:
        if any(
            s in err_l
            for s in (
                "cannot open display",
                "no display",
                "no module named",
                "importerror",
            )
        ):
            raise _DialogUnavailable(err or "dialog unavailable")
        raise _DialogCancel
    lines = [ln.strip() for ln in (proc.stdout or "").splitlines() if ln.strip()]
    if not lines:
        raise _DialogCancel
    return lines[-1]


def _pick_zenity(start: str) -> str:
    exe = shutil.which("zenity")
    if not exe:
        raise _DialogUnavailable("zenity not found")
    return _run_folder_dialog(
        [
            exe,
            "--file-selection",
            "--directory",
            "--title=Kachelverzeichnis wählen",
            f"--filename={_dialog_filename(start)}",
        ]
    )


def _pick_kdialog(start: str) -> str:
    exe = shutil.which("kdialog")
    if not exe:
        raise _DialogUnavailable("kdialog not found")
    return _run_folder_dialog(
        [exe, "--getexistingdirectory", start, "Kachelverzeichnis wählen"]
    )


def _pick_yad(start: str) -> str:
    exe = shutil.which("yad")
    if not exe:
        raise _DialogUnavailable("yad not found")
    return _run_folder_dialog(
        [
            exe,
            "--file-selection",
            "--directory",
            "--title=Kachelverzeichnis wählen",
            f"--filename={_dialog_filename(start)}",
        ]
    )


_TK_PICK_SCRIPT = """
import sys
from tkinter import Tk, filedialog
start = sys.argv[1] if len(sys.argv) > 1 else ""
root = Tk()
root.withdraw()
try:
    root.attributes("-topmost", True)
except Exception:
    pass
path = filedialog.askdirectory(
    initialdir=start or None,
    title="Kachelverzeichnis wählen",
    mustexist=True,
)
try:
    root.destroy()
except Exception:
    pass
if path:
    sys.stdout.write(path)
"""


def _pick_tk(start: str) -> str:
    return _run_folder_dialog([sys.executable, "-c", _TK_PICK_SCRIPT, start])


def pick_directory(start: str | None) -> tuple[dict, int]:
    """Open a native OS folder dialog; return the chosen path (localhost only)."""
    if not _pick_lock.acquire(blocking=False):
        return {"ok": False, "error": "Ein Verzeichnisdialog ist bereits geöffnet"}, 409
    try:
        start_dir = _normalize_start_dir(start)
        for picker in (_pick_zenity, _pick_kdialog, _pick_yad, _pick_tk):
            try:
                path = picker(start_dir)
                return {"ok": True, "cancelled": False, "path": path}, 200
            except _DialogCancel:
                return {"ok": True, "cancelled": True, "path": None}, 200
            except _DialogUnavailable:
                continue
        return {
            "ok": False,
            "fallback": True,
            "error": "Kein Systemdialog verfügbar (zenity, kdialog oder tkinter).",
        }, 501
    finally:
        _pick_lock.release()


def tile_content_type(path: Path) -> str:
    if path.suffix.lower() == ".webp":
        return "image/webp"
    return mimetypes.guess_type(str(path))[0] or "application/octet-stream"


class PreviewHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(TILES_DIR), **kwargs)

    def log_message(self, fmt: str, *args) -> None:
        # Quieter default: skip tile GETs noise somewhat by only logging API / errors
        path = args[0] if args else ""
        if isinstance(path, str) and ("/api/" in path or "preview" in path):
            super().log_message(fmt, *args)

    def _send(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def _client_is_local(self) -> bool:
        addr = self.client_address[0]
        return addr in ("127.0.0.1", "::1", "localhost")

    def _reject_nonlocal_fs(self) -> bool:
        if self._client_is_local():
            return False
        status, body, ctype = _json_bytes(
            {"ok": False, "error": "Filesystem API is only available from localhost"},
            403,
        )
        self._send(status, body, ctype)
        return True

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/pbfs":
            status, body, ctype = _json_bytes({"files": list_local_pbfs()})
            self._send(status, body, ctype)
            return
        if parsed.path == "/api/tiles/info":
            status, body, ctype = _json_bytes(tile_format_info())
            self._send(status, body, ctype)
            return
        if parsed.path == "/api/fs/browse":
            if self._reject_nonlocal_fs():
                return
            qs = parse_qs(parsed.query)
            raw_path = qs.get("path", [""])[0] or ""
            result, code = browse_fs(raw_path)
            status, body, ctype = _json_bytes(result, code)
            self._send(status, body, ctype)
            return
        if parsed.path in ("/api/compare", "/api/compare/info"):
            status, body, ctype = _json_bytes(compare_info())
            self._send(status, body, ctype)
            return
        if parsed.path == "/api/run/status":
            qs = parsed.query
            since = 0
            for part in qs.split("&"):
                if part.startswith("since="):
                    try:
                        since = max(0, int(part.split("=", 1)[1]))
                    except ValueError:
                        since = 0
            status, body, ctype = _json_bytes(run_status(since))
            self._send(status, body, ctype)
            return
        if parsed.path.startswith("/compare/"):
            tile_path = resolve_compare_tile_path(parsed.path)
            if tile_path is not None:
                ctype = tile_content_type(tile_path)
                data = tile_path.read_bytes()
                self._send(200, data, ctype)
                return
            self.send_error(404, "Compare tile not found")
            return
        tile_path = resolve_tile_path(parsed.path)
        if tile_path is not None:
            ctype = tile_content_type(tile_path)
            data = tile_path.read_bytes()
            self._send(200, data, ctype)
            return
        if parsed.path in ("/", "/preview.html"):
            # Always serve preview from tiles dir
            self.path = "/preview.html"
        return super().do_GET()

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        try:
            payload = self._read_json()
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            status, body, ctype = _json_bytes({"ok": False, "error": str(exc)}, 400)
            self._send(status, body, ctype)
            return

        if parsed.path == "/api/run":
            zmin = payload.get("zmin")
            zmax = payload.get("zmax")
            if zmin is not None:
                try:
                    zmin = int(zmin)
                except (TypeError, ValueError):
                    status, body, ctype = _json_bytes(
                        {"ok": False, "error": "zmin must be an integer"}, 400
                    )
                    self._send(status, body, ctype)
                    return
            if zmax is not None:
                try:
                    zmax = int(zmax)
                except (TypeError, ValueError):
                    status, body, ctype = _json_bytes(
                        {"ok": False, "error": "zmax must be an integer"}, 400
                    )
                    self._send(status, body, ctype)
                    return
            tile_format = payload.get("format")
            if tile_format is not None:
                tile_format = str(tile_format).lower()
                if tile_format == "jpeg":
                    tile_format = "jpg"
                if tile_format not in ("webp", "png", "jpg"):
                    status, body, ctype = _json_bytes(
                        {"ok": False, "error": "format must be webp, png or jpg"}, 400
                    )
                    self._send(status, body, ctype)
                    return
            quality = payload.get("quality")
            if quality is not None:
                try:
                    quality = int(quality)
                except (TypeError, ValueError):
                    status, body, ctype = _json_bytes(
                        {"ok": False, "error": "quality must be an integer"}, 400
                    )
                    self._send(status, body, ctype)
                    return
                if quality < 0 or quality > 100:
                    status, body, ctype = _json_bytes(
                        {"ok": False, "error": "quality must be 0-100"}, 400
                    )
                    self._send(status, body, ctype)
                    return
            jobs = payload.get("jobs")
            if jobs is not None and jobs != "":
                if isinstance(jobs, str) and jobs.strip().lower() == "dynamic":
                    jobs = "dynamic"
                else:
                    try:
                        jobs = int(jobs)
                    except (TypeError, ValueError):
                        status, body, ctype = _json_bytes(
                            {"ok": False, "error": "jobs must be 'dynamic' or an integer >= 1"},
                            400,
                        )
                        self._send(status, body, ctype)
                        return
                    if jobs < 1:
                        status, body, ctype = _json_bytes(
                            {"ok": False, "error": "jobs must be 'dynamic' or >= 1"},
                            400,
                        )
                        self._send(status, body, ctype)
                        return
            else:
                jobs = None
            result, code = start_run(
                str(payload.get("data", "")),
                str(payload.get("bbox", "")),
                refresh=bool(payload.get("refresh", False)),
                skip_render=bool(payload.get("skip_render", False)),
                render_only=bool(payload.get("render_only", False)),
                zmin=zmin,
                zmax=zmax,
                tile_format=tile_format,
                quality=quality,
                jobs=jobs,
                inside=bool(payload.get("inside", False)),
            )
            status, body, ctype = _json_bytes(result, code)
            self._send(status, body, ctype)
            return

        if parsed.path == "/api/run/stop":
            result, code = stop_run()
            status, body, ctype = _json_bytes(result, code)
            self._send(status, body, ctype)
            return

        if parsed.path == "/api/compare":
            if self._reject_nonlocal_fs():
                return
            result, code = set_compare_dir(payload.get("path"))
            status, body, ctype = _json_bytes(result, code)
            self._send(status, body, ctype)
            return

        if parsed.path == "/api/fs/pick":
            if self._reject_nonlocal_fs():
                return
            result, code = pick_directory(
                payload.get("start") or payload.get("path")
            )
            status, body, ctype = _json_bytes(result, code)
            self._send(status, body, ctype)
            return

        status, body, ctype = _json_bytes({"ok": False, "error": "Not found"}, 404)
        self._send(status, body, ctype)

    def end_headers(self) -> None:
        # Allow opening from another local origin if needed
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()


def main() -> None:
    mimetypes.add_type("application/json", ".json")
    if not TILES_DIR.is_dir():
        raise SystemExit(f"Tiles directory missing: {TILES_DIR}")
    if not RUN_SCRIPT.is_file():
        raise SystemExit(f"run.sh missing: {RUN_SCRIPT}")

    server = ThreadingHTTPServer((HOST, PORT), PreviewHandler)
    print(f"Preview: http://{HOST}:{PORT}/preview.html")
    print(f"Tiles:   {TILES_DIR}")
    print(f"PBFs:    {OSM_DIR}")
    print(
        "API:     GET /api/pbfs  GET /api/fs/browse  POST /api/fs/pick  POST /api/compare  "
        "POST /api/run  GET /api/run/status  POST /api/run/stop"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
