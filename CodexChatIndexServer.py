from __future__ import annotations

import argparse
import hashlib
import json
import locale
import os
import re
import socket
import subprocess
import sys
import threading
import webbrowser
from collections import OrderedDict
from contextlib import closing
from datetime import datetime
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import URLError
from urllib.parse import parse_qs, quote, urlparse
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parent
SERVE_ROOT = ROOT.parent
RUNTIME_DATA_DIR = SERVE_ROOT / "运行数据"
BUILD_SCRIPT = ROOT / "Build-CodexChatIndex.ps1"
TEMP_DIR = ROOT / "temp"
HTML_FILE = TEMP_DIR / "CodexChatIndex.html"
LOCAL_SOURCE_ID = "local-codex"
LOCAL_CLAUDE_SOURCE_ID = "local-claude"
SOURCE_DATA_ROOT = RUNTIME_DATA_DIR / "CodexChatIndex.sources"
SOURCES_FILE = RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
EXTERNAL_SOURCES_ROOT = SERVE_ROOT / "外部聊天记录"
CLAUDE_HOME = Path.home() / ".claude"
DATA_FILE = SOURCE_DATA_ROOT / LOCAL_SOURCE_ID / "CodexChatIndex.data.json"
SEARCH_FILE = SOURCE_DATA_ROOT / LOCAL_SOURCE_ID / "CodexChatIndex.search.json"
NOTES_FILE = RUNTIME_DATA_DIR / "CodexChatIndex.notes.json"
ENTRY_PATH = f"/{ROOT.name}/temp/{HTML_FILE.name}"
MAX_NOTE_LENGTH = 10000
SEARCH_INDEX_CACHE_MAX_BYTES = 32 * 1024 * 1024
SEARCH_INDEX_CACHE_MAX_ENTRIES = 4
_search_index_cache: dict[str, dict] = {}
_search_index_mtime_ns: dict[str, int] = {}
_search_index_cache_sizes: dict[str, int] = {}
_search_index_access_order: OrderedDict[str, None] = OrderedDict()
_search_index_lock = threading.Lock()
_notes_lock = threading.Lock()


def decode_process_output(data: bytes | None) -> str:
    if not data:
        return ""

    encodings: list[str] = []
    preferred = locale.getpreferredencoding(False)
    for encoding in (preferred, "utf-8", "gb18030", "cp936"):
        if encoding and encoding not in encodings:
            encodings.append(encoding)

    for encoding in encodings:
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue

    return data.decode(preferred or "utf-8", errors="replace")


def normalize_summary(summary: dict | None) -> dict:
    if not summary:
        return {}
    key_map = {
        "Mode": "mode",
        "ScannedCount": "scannedCount",
        "ParsedCount": "parsedCount",
        "ReusedCount": "reusedCount",
        "DeletedCount": "deletedCount",
        "ElapsedMs": "elapsedMs",
        "Sessions": "sessions",
        "Workspaces": "workspaces",
    }
    normalized: dict = {}
    for key, value in summary.items():
        normalized[key_map.get(key, key[:1].lower() + key[1:] if key else key)] = value
    return normalized


def parse_summary(stdout: str) -> dict:
    for line in reversed(stdout.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            parsed = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            return normalize_summary(parsed)
    return {}


def slug_source_label(label: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "-", str(label or "").strip()).strip("-").lower()
    return slug or "source"


def make_external_source_id(label: str, root: Path) -> str:
    path_hash = hashlib.sha256(str(root.resolve()).casefold().encode("utf-8", errors="ignore")).hexdigest()[:8]
    return f"external-{slug_source_label(label)}-{path_hash}"


def get_source_paths(source_id: str) -> dict[str, Path]:
    safe_id = re.sub(r"[^A-Za-z0-9._-]+", "-", str(source_id or LOCAL_SOURCE_ID)).strip("-") or LOCAL_SOURCE_ID
    root = RUNTIME_DATA_DIR / "CodexChatIndex.sources" / safe_id
    return {
        "root": root,
        "data": root / "CodexChatIndex.data.json",
        "search": root / "CodexChatIndex.search.json",
        "cache": root / "CodexChatIndex.cache.json",
        "details": root / "CodexChatIndex.sessions",
    }


def local_source() -> dict:
    codex_home = Path.home() / ".codex"
    return {
        "id": LOCAL_SOURCE_ID,
        "label": "本机 Codex",
        "type": "local-codex",
        "roots": [str(codex_home / "sessions"), str(codex_home / "archived_sessions")],
    }


def local_claude_source() -> dict:
    return {
        "id": LOCAL_CLAUDE_SOURCE_ID,
        "label": "本机 Claude",
        "type": "local-claude",
        "root": str(CLAUDE_HOME / "projects"),
        "sessionsRoot": str(CLAUDE_HOME / "sessions"),
    }


def read_sources_manifest() -> dict:
    if not SOURCES_FILE.exists():
        return {}
    try:
        parsed = json.loads(SOURCES_FILE.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def write_sources_manifest(payload: dict) -> None:
    RUNTIME_DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp_path = SOURCES_FILE.with_suffix(SOURCES_FILE.suffix + ".tmp")
    tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp_path.replace(SOURCES_FILE)


def discover_sources() -> dict:
    EXTERNAL_SOURCES_ROOT.mkdir(parents=True, exist_ok=True)
    sources: list[dict] = [local_source(), local_claude_source()]
    if EXTERNAL_SOURCES_ROOT.exists():
        for child in sorted((item for item in EXTERNAL_SOURCES_ROOT.iterdir() if item.is_dir()), key=lambda item: item.name.casefold()):
            sources.append(
                {
                    "id": make_external_source_id(child.name, child),
                    "label": child.name,
                    "type": "external-codex-jsonl",
                    "root": str(child),
                }
            )

    known_ids = {source["id"] for source in sources}
    manifest = read_sources_manifest()
    selected = str(manifest.get("selectedSourceId") or LOCAL_SOURCE_ID)
    if selected not in known_ids:
        selected = LOCAL_SOURCE_ID
    payload = {"version": 1, "selectedSourceId": selected, "sources": sources}
    write_sources_manifest(payload)
    return payload


def get_selected_source_id() -> str:
    return discover_sources().get("selectedSourceId") or LOCAL_SOURCE_ID


def set_selected_source_id(source_id: str) -> dict:
    payload = discover_sources()
    known_ids = {source["id"] for source in payload.get("sources", [])}
    selected = str(source_id or LOCAL_SOURCE_ID)
    if selected not in known_ids:
        raise ValueError("unknown sourceId")
    payload["selectedSourceId"] = selected
    write_sources_manifest(payload)
    return payload


def resolve_source_id(source_id: str | None) -> str:
    requested = str(source_id or "").strip() or get_selected_source_id()
    payload = discover_sources()
    known_ids = {source["id"] for source in payload.get("sources", [])}
    if requested not in known_ids:
        raise ValueError("unknown sourceId")
    return requested


def get_source(source_id: str) -> dict:
    payload = discover_sources()
    for source in payload.get("sources", []):
        if source.get("id") == source_id:
            return source
    raise ValueError("unknown sourceId")


def empty_source_data(source: dict, reason: str = "not-built") -> dict:
    return {
        "generatedAt": "",
        "source": source,
        "needsBuild": True,
        "emptyReason": reason,
        "totalSessions": 0,
        "totalWorkspaces": 0,
        "archived": 0,
        "imageReferences": 0,
        "workspaces": [],
    }


def run_build(refresh_mode: str = "Incremental", current_session_path: str | None = None, source_id: str = LOCAL_SOURCE_ID) -> tuple[bool, str, dict]:
    try:
        source = get_source(source_id)
    except ValueError as error:
        return False, str(error), {}
    cmd = [
        "pwsh",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(BUILD_SCRIPT),
        "-OutputPath",
        str(HTML_FILE),
        "-DataRoot",
        str(RUNTIME_DATA_DIR),
        "-SourceId",
        source_id,
        "-SourceLabel",
        str(source.get("label") or source_id),
        "-SourceType",
        str(source.get("type") or "local-codex"),
        "-RefreshMode",
        refresh_mode,
        "-JsonSummary",
    ]
    if source.get("type") == "external-codex-jsonl":
        cmd.extend(["-ExternalSourcePath", str(source.get("root") or "")])
    if source.get("type") == "local-claude":
        claude_home = Path(str(source.get("root") or CLAUDE_HOME / "projects")).parent
        cmd.extend(["-ClaudeHome", str(claude_home)])
    if current_session_path:
        cmd.extend(["-CurrentSessionPath", current_session_path])
    proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=False)
    stdout = decode_process_output(proc.stdout).strip()
    stderr = decode_process_output(proc.stderr).strip()
    if proc.returncode != 0:
        return False, stderr or stdout or "Build failed", {}
    missing: list[str] = []
    paths = get_source_paths(source_id)
    if not HTML_FILE.exists():
        missing.append(str(HTML_FILE))
    if not paths["data"].exists():
        missing.append(str(paths["data"]))
    if not paths["search"].exists():
        missing.append(str(paths["search"]))
    if missing:
        return False, "Build finished but required output is missing: " + ", ".join(missing), {}
    summary = parse_summary(stdout)
    mode = summary.get("mode") or refresh_mode
    message = stdout or f"{mode} build completed"
    return True, message, summary


def load_data(source_id: str = LOCAL_SOURCE_ID) -> dict:
    source = get_source(source_id)
    data_file = get_source_paths(source_id)["data"]
    if not data_file.exists():
        return empty_source_data(source)
    parsed = json.loads(data_file.read_text(encoding="utf-8"))
    if isinstance(parsed, dict) and not parsed.get("source"):
        parsed["source"] = source
    return parsed if isinstance(parsed, dict) else empty_source_data(source, "invalid")


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def normalize_source_id_for_notes(source_id: str | None) -> str:
    return str(source_id or LOCAL_SOURCE_ID).strip() or LOCAL_SOURCE_ID


def split_note_key(storage_key: str, item: dict) -> tuple[str, str]:
    source_id = str(item.get("sourceId") or LOCAL_SOURCE_ID).strip() or LOCAL_SOURCE_ID
    key = str(item.get("key") or storage_key or "").strip()
    return source_id, key


def source_scoped_note_alias(key: str, source_id: str) -> str:
    if key.startswith("group:") and not key.startswith(f"group:{source_id}:"):
        return "group:" + source_id + ":" + key[len("group:") :]
    if key.startswith("session:") and not key.startswith(f"session:{source_id}:"):
        return "session:" + source_id + ":" + key[len("session:") :]
    return key


def normalize_notes_payload(payload: dict | None, source_id: str | None = LOCAL_SOURCE_ID) -> dict:
    if not isinstance(payload, dict):
        payload = {}
    requested_source_id = normalize_source_id_for_notes(source_id)
    raw_notes = payload.get("notes")
    if not isinstance(raw_notes, dict):
        raw_notes = {}
    notes: dict = {}
    for storage_key, item in raw_notes.items():
        if not isinstance(item, dict):
            continue
        item_source_id, item_key = split_note_key(str(storage_key), item)
        if item_source_id != requested_source_id:
            continue
        normalized_item = dict(item)
        normalized_item["sourceId"] = item_source_id
        normalized_item["key"] = item_key
        notes[item_key] = normalized_item
        if item_source_id == LOCAL_SOURCE_ID:
            alias = source_scoped_note_alias(item_key, item_source_id)
            notes.setdefault(alias, normalized_item)
    return {
        "ok": True,
        "version": 1,
        "updatedAt": payload.get("updatedAt") or "",
        "notes": notes,
    }


def load_notes(source_id: str = LOCAL_SOURCE_ID) -> dict:
    if not NOTES_FILE.exists():
        return {"ok": True, "version": 1, "updatedAt": "", "notes": {}}
    with _notes_lock:
        parsed = json.loads(NOTES_FILE.read_text(encoding="utf-8"))
    return normalize_notes_payload(parsed, source_id)


def write_notes_payload(payload: dict) -> None:
    NOTES_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = NOTES_FILE.with_suffix(NOTES_FILE.suffix + ".tmp")
    tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp_path.replace(NOTES_FILE)


def validate_note_payload(payload: dict) -> tuple[str, str, str, str]:
    key = str(payload.get("key") or "").strip()
    if not key:
        raise ValueError("key is required")
    source_id = normalize_source_id_for_notes(str(payload.get("sourceId") or LOCAL_SOURCE_ID))
    note_type = str(payload.get("type") or "").strip()
    if note_type not in {"group", "session"}:
        raise ValueError("type must be group or session")
    note = str(payload.get("note") or "").strip()
    if not note:
        raise ValueError("note is required")
    if len(note) > MAX_NOTE_LENGTH:
        raise ValueError("note is too long")
    return key, source_id, note_type, note


def save_note(payload: dict) -> dict:
    key, source_id, note_type, note = validate_note_payload(payload)
    storage_key = source_id + "::" + key
    with _notes_lock:
        current_raw = json.loads(NOTES_FILE.read_text(encoding="utf-8")) if NOTES_FILE.exists() else {}
        raw_notes = dict((current_raw if isinstance(current_raw, dict) else {}).get("notes") or {})
        existing = raw_notes.get(storage_key) if isinstance(raw_notes.get(storage_key), dict) else {}
        timestamp = now_iso()
        item = {
            "key": key,
            "type": note_type,
            "sourceId": source_id,
            "workspace": str(payload.get("workspace") or ""),
            "title": str(payload.get("title") or ""),
            "path": str(payload.get("path") or ""),
            "sessionId": str(payload.get("sessionId") or ""),
            "note": note,
            "createdAt": existing.get("createdAt") or timestamp,
            "updatedAt": timestamp,
        }
        raw_notes[storage_key] = item
        next_payload = {"version": 1, "updatedAt": timestamp, "notes": raw_notes}
        write_notes_payload(next_payload)
    return {"ok": True, "key": key, "item": item}


def delete_note(key: str, source_id: str = LOCAL_SOURCE_ID) -> dict:
    key = str(key or "").strip()
    if not key:
        raise ValueError("key is required")
    source_id = normalize_source_id_for_notes(source_id)
    with _notes_lock:
        current_raw = json.loads(NOTES_FILE.read_text(encoding="utf-8")) if NOTES_FILE.exists() else {}
        notes = dict((current_raw if isinstance(current_raw, dict) else {}).get("notes") or {})
        for storage_key, item in list(notes.items()):
            if not isinstance(item, dict):
                continue
            item_source_id, item_key = split_note_key(str(storage_key), item)
            if item_source_id == source_id and item_key == key:
                notes.pop(storage_key, None)
        timestamp = now_iso()
        write_notes_payload({"version": 1, "updatedAt": timestamp, "notes": notes})
    return {"ok": True, "key": key}


def estimate_search_index_size(value: dict) -> int:
    return len(json.dumps(value, ensure_ascii=False))


def enforce_search_index_cache_limits() -> None:
    while (
        len(_search_index_cache) > SEARCH_INDEX_CACHE_MAX_ENTRIES
        or sum(_search_index_cache_sizes.values()) > SEARCH_INDEX_CACHE_MAX_BYTES
    ) and _search_index_access_order:
        source_id, _ = _search_index_access_order.popitem(last=False)
        _search_index_cache.pop(source_id, None)
        _search_index_mtime_ns.pop(source_id, None)
        _search_index_cache_sizes.pop(source_id, None)


def remember_search_index(source_id: str, parsed: dict, mtime_ns: int) -> dict:
    _search_index_cache[source_id] = parsed
    _search_index_mtime_ns[source_id] = mtime_ns
    _search_index_cache_sizes[source_id] = estimate_search_index_size(parsed)
    _search_index_access_order.pop(source_id, None)
    _search_index_access_order[source_id] = None
    enforce_search_index_cache_limits()
    return parsed


def load_search_index(source_id: str = LOCAL_SOURCE_ID) -> dict:
    search_file = get_source_paths(source_id)["search"]
    if not search_file.exists():
        return {"version": 1, "sessions": []}
    mtime_ns = search_file.stat().st_mtime_ns
    with _search_index_lock:
        if source_id in _search_index_cache and _search_index_mtime_ns.get(source_id) == mtime_ns:
            _search_index_access_order.pop(source_id, None)
            _search_index_access_order[source_id] = None
            return _search_index_cache[source_id]
        parsed = json.loads(search_file.read_text(encoding="utf-8"))
        return remember_search_index(source_id, parsed, mtime_ns)


def search_sessions(query: str, source_id: str = LOCAL_SOURCE_ID) -> list[dict]:
    terms = [term for term in str(query or "").casefold().split() if term]
    if not terms:
        return []

    results: list[dict] = []
    for session in load_search_index(source_id).get("sessions", []):
        text = str(session.get("searchText") or "").casefold()
        if not all(term in text for term in terms):
            continue
        results.append(
            {
                "key": session.get("key", ""),
                "id": session.get("id", ""),
                "sourceId": session.get("sourceId", source_id),
                "title": session.get("title", ""),
                "workspace": session.get("cwd", ""),
                "path": session.get("path", ""),
            }
        )
    return results


def load_current_detail_for_path(data: dict, requested_path: str | None) -> dict | None:
    if not requested_path:
        return None
    requested_path = str(requested_path).strip()
    if not requested_path:
        return None

    for workspace in data.get("workspaces", []):
        for session in workspace.get("sessions", []):
            session_path = str(session.get("path") or session.get("key") or "").strip()
            if session_path != requested_path:
                continue
            detail_href = str(session.get("detailHref") or "").strip()
            if not detail_href:
                return None
            detail_path = (ROOT / detail_href).resolve()
            try:
                detail_path.relative_to(SERVE_ROOT.resolve())
            except ValueError:
                return None
            if not detail_path.exists():
                return None
            return json.loads(detail_path.read_text(encoding="utf-8"))
    return None


def open_browser(url: str) -> bool:
    if sys.platform.startswith("win"):
        try:
            os.startfile(url)
            return True
        except OSError:
            pass
    return bool(webbrowser.open(url))


def is_address_in_use(error: OSError) -> bool:
    return getattr(error, "winerror", None) == 10048 or getattr(error, "errno", None) in {48, 98}


def is_reusable_existing_service(url: str) -> bool:
    try:
        with closing(urlopen(url, timeout=1.5)) as response:
            html = response.read().decode("utf-8", errors="replace")
    except (URLError, OSError, TimeoutError, ValueError):
        return False
    return ("语迹" in html or "Codex 聊天记录浏览器" in html) and ROOT.name in html


def has_existing_startup_index() -> bool:
    paths = get_source_paths(LOCAL_SOURCE_ID)
    return HTML_FILE.exists() and paths["data"].exists() and paths["search"].exists()


def get_session_identity(session: dict) -> str:
    return session.get("key") or session.get("path") or session.get("id") or ""


def collect_ids(data: dict) -> set[str]:
    ids: set[str] = set()
    for workspace in data.get("workspaces", []):
        for session in workspace.get("sessions", []):
            session_id = get_session_identity(session)
            if session_id:
                ids.add(session_id)
    return ids


def flatten_sessions(data: dict) -> list[dict]:
    rows: list[dict] = []
    for workspace in data.get("workspaces", []):
        cwd = workspace.get("cwd", "")
        for session in workspace.get("sessions", []):
            rows.append(
                {
                    "id": session.get("id", ""),
                    "key": session.get("key", ""),
                    "sourceId": session.get("sourceId", data.get("source", {}).get("id", LOCAL_SOURCE_ID)),
                    "title": session.get("title", ""),
                    "updatedLocal": session.get("updatedLocal", ""),
                    "workspace": cwd,
                    "path": session.get("path", ""),
                }
            )
    return rows


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(SERVE_ROOT), **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        parsed = urlparse(self.path)
        query_params = parse_qs(parsed.query)
        if parsed.path == "/api/sources":
            self._write_json(discover_sources(), HTTPStatus.OK)
            return
        if parsed.path == "/api/source-data":
            try:
                source_id = resolve_source_id(query_params.get("sourceId", [""])[0])
                self._write_json(load_data(source_id), HTTPStatus.OK)
            except ValueError as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
            return
        if parsed.path == "/api/search":
            query = query_params.get("q", [""])[0]
            try:
                source_id = resolve_source_id(query_params.get("sourceId", [""])[0])
            except ValueError as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
                return
            hits = search_sessions(query, source_id)
            self._write_json(
                {
                    "ok": True,
                    "sourceId": source_id,
                    "query": query,
                    "count": len(hits),
                    "sessionKeys": [row.get("key", "") for row in hits if row.get("key", "")],
                    "hits": hits,
                },
                HTTPStatus.OK,
            )
            return
        if parsed.path == "/api/notes":
            try:
                source_id = resolve_source_id(query_params.get("sourceId", [""])[0])
                self._write_json(load_notes(source_id), HTTPStatus.OK)
            except ValueError as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
            return

        if parsed.path in ("", "/", "/" + HTML_FILE.name, f"/{ROOT.name}/{HTML_FILE.name}"):
            self.send_response(HTTPStatus.FOUND)
            self.send_header("Location", ENTRY_PATH)
            self.end_headers()
            return
        elif self.path == "/favicon.ico":
            self.send_response(HTTPStatus.NO_CONTENT)
            self.end_headers()
            return
        return super().do_GET()

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/api/sources":
            try:
                body = self._read_json_body()
                self._write_json(set_selected_source_id(str(body.get("selectedSourceId") or "")), HTTPStatus.OK)
            except ValueError as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
            except OSError as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        if parsed.path == "/api/notes":
            try:
                body = self._read_json_body()
                source_id = resolve_source_id(str(body.get("sourceId") or ""))
                body["sourceId"] = source_id
                self._write_json(save_note(body), HTTPStatus.OK)
            except ValueError as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
            except OSError as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        routes = {
            "/api/refresh": "Incremental",
            "/api/rebuild": "Full",
            "/api/refresh-current": "Current",
        }
        if parsed.path not in routes:
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            return

        try:
            body = self._read_json_body()
        except ValueError as error:
            self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
            return

        try:
            source_id = resolve_source_id(str(body.get("sourceId") or ""))
        except ValueError as error:
            self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
            return

        before = load_data(source_id)
        before_ids = collect_ids(before)
        requested_session_path = str(body.get("path") or body.get("key") or "").strip() or None
        current_session_path = None
        if parsed.path == "/api/refresh-current":
            current_session_path = requested_session_path
            if not current_session_path:
                self._write_json({"ok": False, "error": "path is required"}, HTTPStatus.BAD_REQUEST)
                return

        ok, message, summary = run_build(routes[parsed.path], current_session_path, source_id)
        if not ok:
            payload = {"ok": False, "error": message}
            self._write_json(payload, HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        set_selected_source_id(source_id)
        after = load_data(source_id)
        added = [row for row in flatten_sessions(after) if get_session_identity(row) not in before_ids]
        current_detail = load_current_detail_for_path(after, requested_session_path)
        payload = {
            "ok": True,
            "sourceId": source_id,
            "message": message,
            "addedCount": len(added),
            "added": added,
            "data": after,
            "currentDetail": current_detail,
        }
        payload.update(summary)
        self._write_json(payload, HTTPStatus.OK)

    def do_DELETE(self):
        parsed = urlparse(self.path)
        if parsed.path != "/api/notes":
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            return
        try:
            body = self._read_json_body()
            source_id = resolve_source_id(str(body.get("sourceId") or ""))
            self._write_json(delete_note(str(body.get("key") or ""), source_id), HTTPStatus.OK)
        except ValueError as error:
            self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
        except OSError as error:
            self._write_json({"ok": False, "error": str(error)}, HTTPStatus.INTERNAL_SERVER_ERROR)

    def log_message(self, format: str, *args):
        sys.stdout.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), format % args))

    def _write_json(self, payload: dict, status: HTTPStatus):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self) -> dict:
        length = int(self.headers.get("Content-Length", "0") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError as error:
            raise ValueError("invalid JSON body") from error
        if not isinstance(payload, dict):
            raise ValueError("JSON body must be an object")
        return payload


def main() -> int:
    parser = argparse.ArgumentParser(description="Local server for CodexChatIndex.html with refresh API")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--open", action="store_true", help="Open the browser after server starts")
    args = parser.parse_args()

    if has_existing_startup_index():
        print("Using existing local-codex index. Click Refresh in the page to update.")
    else:
        ok, message, _summary = run_build("Incremental")
        if not ok:
            print(message, file=sys.stderr)
            return 1
        if message:
            print(message)

    url = f"http://{args.host}:{args.port}{quote(ENTRY_PATH, safe='/')}"
    try:
        server = ThreadingHTTPServer((args.host, args.port), Handler)
    except OSError as error:
        if is_address_in_use(error):
            if is_reusable_existing_service(url):
                print(f"Detected running Open-CodexChatIndex service at {url}")
                if args.open:
                    open_browser(url)
                return 0
            print(f"Port {args.port} is already in use by another program.", file=sys.stderr)
            return 1
        raise

    print(f"Serving {url}")

    if args.open:
        threading.Timer(0.6, lambda: open_browser(url)).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server...")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
