from __future__ import annotations

import argparse
import hashlib
import json
import locale
import os
import re
import secrets
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

from webdav_sync.client import WebDAVError
from webdav_sync.config import ConfigError
from webdav_sync.protocol import ProtocolError
from webdav_sync.service import (
    BuildResourceCoordinator,
    TaskBusyError,
    WebDAVSyncService,
    capabilities_for_type,
    parse_remote_source_id,
)


ROOT = Path(__file__).resolve().parent
SERVE_ROOT = ROOT.parent
RUNTIME_DATA_DIR = SERVE_ROOT / "运行数据"
BUILD_SCRIPT = ROOT / "Build-CodexChatIndex.ps1"
TEMPLATE_FILE = ROOT / "templates" / "CodexChatIndex.template.html"
TEMP_DIR = ROOT / "temp"
HTML_FILE = TEMP_DIR / "CodexChatIndex.html"
LOCAL_SOURCE_ID = "local-codex"
LOCAL_CLAUDE_SOURCE_ID = "local-claude"
SOURCE_DATA_ROOT = RUNTIME_DATA_DIR / "CodexChatIndex.sources"
IMAGE_ASSET_ROOT = RUNTIME_DATA_DIR / "CodexChatIndex.images"
IMAGE_OBJECT_ROOT = IMAGE_ASSET_ROOT / "objects"
IMAGE_MANIFEST_ROOT = IMAGE_ASSET_ROOT / "manifests"
SOURCES_FILE = RUNTIME_DATA_DIR / "CodexChatIndex.sources.json"
EXTERNAL_SOURCES_ROOT = SERVE_ROOT / "外部聊天记录"
CLAUDE_HOME = Path.home() / ".claude"
DATA_FILE = SOURCE_DATA_ROOT / LOCAL_SOURCE_ID / "CodexChatIndex.data.json"
SEARCH_FILE = SOURCE_DATA_ROOT / LOCAL_SOURCE_ID / "CodexChatIndex.search.json"
OTHER_SEARCH_FILE = SOURCE_DATA_ROOT / LOCAL_SOURCE_ID / "CodexChatIndex.search.other.json"
NOTES_FILE = RUNTIME_DATA_DIR / "CodexChatIndex.notes.json"
ENTRY_PATH = f"/{ROOT.name}/temp/{HTML_FILE.name}"
MAX_NOTE_LENGTH = 10000
MAX_LOCAL_IMAGE_BYTES = 30 * 1024 * 1024
LOCAL_IMAGE_MIME_TYPES = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".avif": "image/avif",
}
SEARCH_INDEX_CACHE_MAX_BYTES = 32 * 1024 * 1024
SEARCH_INDEX_CACHE_MAX_ENTRIES = 4
SEARCH_INDEX_VERSION = 4
SEARCH_FIELDS = {"all", "questions"}
_search_index_cache: dict[str, dict] = {}
_search_index_mtime_ns: dict[str, int] = {}
_search_index_cache_sizes: dict[str, int] = {}
_search_index_access_order: OrderedDict[str, None] = OrderedDict()
_search_index_lock = threading.Lock()
_notes_lock = threading.Lock()
_sources_lock = threading.RLock()
_webdav_service_lock = threading.RLock()
_webdav_service: WebDAVSyncService | None = None
_build_resource_coordinator = BuildResourceCoordinator()
SESSION_TOKEN = secrets.token_urlsafe(32)
MAX_JSON_BODY_BYTES = 256 * 1024


class UnsupportedImageError(Exception):
    pass


class ImageTooLargeError(Exception):
    pass


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


def get_machine_name() -> str:
    machine_name = str(os.environ.get("COMPUTERNAME") or "").strip()
    if machine_name:
        return machine_name
    try:
        return str(socket.gethostname() or "").strip()
    except OSError:
        return ""


def format_local_source_label(source_type: str, machine_name: str | None = None) -> str:
    base_label = "本机 Claude" if source_type == "local-claude" else "本机 Codex"
    resolved_machine_name = get_machine_name() if machine_name is None else str(machine_name or "").strip()
    return f"{resolved_machine_name}-{base_label}" if resolved_machine_name else base_label


def get_webdav_service() -> WebDAVSyncService:
    global _webdav_service
    with _webdav_service_lock:
        if _webdav_service is None or _webdav_service.runtime_root != RUNTIME_DATA_DIR:
            _webdav_service = WebDAVSyncService(
                RUNTIME_DATA_DIR,
                BUILD_SCRIPT,
                notes_file=NOTES_FILE,
                resource_coordinator=_build_resource_coordinator,
            )
        return _webdav_service


def get_source_paths(source_id: str) -> dict[str, Path]:
    safe_id = re.sub(r"[^A-Za-z0-9._-]+", "-", str(source_id or LOCAL_SOURCE_ID)).strip("-") or LOCAL_SOURCE_ID
    if safe_id.startswith("webdav-"):
        parse_remote_source_id(safe_id)
        root = get_webdav_service().source_index_root(safe_id)
    else:
        root = RUNTIME_DATA_DIR / "CodexChatIndex.sources" / safe_id
    return {
        "root": root,
        "data": root / "CodexChatIndex.data.json",
        "search": root / "CodexChatIndex.search.json",
        "search_other": root / "CodexChatIndex.search.other.json",
        "cache": root / "CodexChatIndex.cache.json",
        "details": root / "CodexChatIndex.sessions",
    }


def local_source() -> dict:
    codex_home = Path.home() / ".codex"
    return {
        "id": LOCAL_SOURCE_ID,
        "label": format_local_source_label("local-codex"),
        "type": "local-codex",
        "roots": [str(codex_home / "sessions"), str(codex_home / "archived_sessions")],
        "capabilities": capabilities_for_type("local-codex"),
    }


def local_claude_source() -> dict:
    return {
        "id": LOCAL_CLAUDE_SOURCE_ID,
        "label": format_local_source_label("local-claude"),
        "type": "local-claude",
        "root": str(CLAUDE_HOME / "projects"),
        "sessionsRoot": str(CLAUDE_HOME / "sessions"),
        "capabilities": capabilities_for_type("local-claude"),
    }


def read_sources_manifest() -> dict:
    with _sources_lock:
        if not SOURCES_FILE.exists():
            return {}
        try:
            parsed = json.loads(SOURCES_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return parsed if isinstance(parsed, dict) else {}


def write_sources_manifest(payload: dict) -> None:
    with _sources_lock:
        RUNTIME_DATA_DIR.mkdir(parents=True, exist_ok=True)
        tmp_path = SOURCES_FILE.with_name(
            f"{SOURCES_FILE.name}.{os.getpid()}.{threading.get_ident()}.tmp"
        )
        try:
            tmp_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
            tmp_path.replace(SOURCES_FILE)
        finally:
            try:
                tmp_path.unlink(missing_ok=True)
            except OSError:
                pass


def discover_sources(persist: bool = True) -> dict:
    with _sources_lock:
        if persist:
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
                        "capabilities": capabilities_for_type("external-codex-jsonl"),
                    }
                )

        if _webdav_service is not None:
            try:
                sources.extend(get_webdav_service().cached_remote_sources())
            except (ConfigError, OSError, ValueError):
                pass

        known_ids = {source["id"] for source in sources}
        manifest = read_sources_manifest()
        selected = str(manifest.get("selectedSourceId") or LOCAL_SOURCE_ID)
        if _webdav_service is not None:
            try:
                selected = get_webdav_service().get_selected_source_id(selected)
            except (ConfigError, OSError, ValueError):
                pass
        if selected not in known_ids:
            selected = LOCAL_SOURCE_ID
        payload = {"version": 1, "selectedSourceId": selected, "sources": sources}
        if persist:
            shared_payload = dict(payload)
            if str(selected).startswith("webdav-"):
                shared_payload["selectedSourceId"] = LOCAL_SOURCE_ID
            write_sources_manifest(shared_payload)
        return payload


def get_selected_source_id() -> str:
    return discover_sources().get("selectedSourceId") or LOCAL_SOURCE_ID


def set_selected_source_id(source_id: str) -> dict:
    with _sources_lock:
        payload = discover_sources(persist=False)
        known_ids = {source["id"] for source in payload.get("sources", [])}
        selected = str(source_id or LOCAL_SOURCE_ID)
        if selected not in known_ids:
            raise ValueError("unknown sourceId")
        payload["selectedSourceId"] = selected
        if _webdav_service is not None:
            get_webdav_service().set_selected_source_id(selected)
        shared_payload = dict(payload)
        if selected.startswith("webdav-"):
            shared_payload["selectedSourceId"] = LOCAL_SOURCE_ID
        write_sources_manifest(shared_payload)
        return payload


def resolve_source_id(source_id: str | None, persist: bool = True) -> str:
    payload = discover_sources(persist=persist)
    requested = str(source_id or "").strip() or str(payload.get("selectedSourceId") or LOCAL_SOURCE_ID)
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


def source_capability(source: dict, name: str) -> bool:
    capabilities = source.get("capabilities") if isinstance(source.get("capabilities"), dict) else {}
    return bool(capabilities.get(name))


def require_source_capability(source_id: str, name: str, message: str) -> dict:
    source = get_source(source_id)
    if not source_capability(source, name):
        raise ValueError(message)
    return source


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
    if source.get("type") in {"webdav-codex", "webdav-claude"}:
        if refresh_mode != "Full":
            return False, "云端来源只支持全量重建本机缓存索引", {}
        try:
            summary = get_webdav_service().rebuild_remote_index(source_id)
        except (ValueError, ConfigError, OSError, RuntimeError) as error:
            return False, str(error), {}
        return True, "云端来源本机缓存索引已原子重建", summary
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
    _build_resource_coordinator.begin_local_build()
    try:
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=False)
    finally:
        _build_resource_coordinator.end_local_build()
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
    if not paths["search_other"].exists():
        missing.append(str(paths["search_other"]))
    if missing:
        return False, "Build finished but required output is missing: " + ", ".join(missing), {}
    summary = parse_summary(stdout)
    mode = summary.get("mode") or refresh_mode
    if source.get("type") in {"local-codex", "local-claude"}:
        try:
            summary["imageSync"] = get_webdav_service().schedule_image_sync(str(source.get("type")))
        except Exception as error:
            summary["imageSync"] = {
                "scheduled": False,
                "pending": True,
                "reason": str(error),
            }
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


def detect_local_image_mime(image_path: Path) -> str | None:
    try:
        with image_path.open("rb") as stream:
            header = stream.read(64)
    except OSError:
        return None
    if header.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if header.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if header.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if len(header) >= 12 and header[:4] == b"RIFF" and header[8:12] == b"WEBP":
        return "image/webp"
    if len(header) >= 16 and header[4:8] == b"ftyp":
        brands = {header[offset : offset + 4] for offset in range(8, len(header) - 3, 4)}
        if brands.intersection({b"avif", b"avis"}):
            return "image/avif"
    return None


def resolve_registered_local_image(source_id: str, session_key: str, image_id: str) -> tuple[Path, str]:
    session_key = str(session_key or "").strip()
    image_id = str(image_id or "").strip()
    if not session_key or not image_id:
        raise FileNotFoundError("image reference not found")
    require_source_capability(source_id, "canResolveLocalImages", "云端来源不能读取当前电脑的本机图片")

    paths = get_source_paths(source_id)
    if not paths["data"].is_file():
        raise FileNotFoundError("source index not found")
    data = json.loads(paths["data"].read_text(encoding="utf-8"))
    session_record: dict | None = None
    for workspace in data.get("workspaces", []):
        for session in workspace.get("sessions", []):
            if str(get_session_identity(session)) == session_key:
                session_record = session
                break
        if session_record is not None:
            break
    if session_record is None:
        raise FileNotFoundError("session not found")

    detail_href = str(session_record.get("detailHref") or "").strip()
    detail_name = re.split(r"[\\/]", detail_href)[-1]
    if not detail_name or not detail_name.lower().endswith(".json"):
        raise FileNotFoundError("session detail not found")
    detail_root = paths["details"].resolve()
    detail_path = (detail_root / detail_name).resolve()
    try:
        detail_path.relative_to(detail_root)
    except ValueError as error:
        raise FileNotFoundError("session detail not found") from error
    if not detail_path.is_file():
        raise FileNotFoundError("session detail not found")

    detail = json.loads(detail_path.read_text(encoding="utf-8"))
    image_record: dict | None = None
    for event in detail.get("events", []):
        if event.get("kind") != "user":
            continue
        for image in event.get("images", []):
            if isinstance(image, dict) and image.get("type") == "local" and str(image.get("imageId") or "") == image_id:
                image_record = image
                break
        if image_record is not None:
            break
    if image_record is None:
        raise FileNotFoundError("image reference not found")

    local_path = str(image_record.get("localPath") or "").strip()
    if not local_path:
        raise FileNotFoundError("image file not found")
    try:
        image_path = Path(os.path.expandvars(local_path)).expanduser().resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise FileNotFoundError("image file not found") from error
    if not image_path.is_file():
        raise FileNotFoundError("image file not found")
    mime_type = LOCAL_IMAGE_MIME_TYPES.get(image_path.suffix.casefold())
    if not mime_type:
        raise UnsupportedImageError("unsupported image type")
    if image_path.stat().st_size > MAX_LOCAL_IMAGE_BYTES:
        raise ImageTooLargeError("image exceeds 30 MiB limit")
    if detect_local_image_mime(image_path) != mime_type:
        raise UnsupportedImageError("image content does not match its file extension")
    return image_path, mime_type


def resolve_managed_image_asset(source_id: str, asset_id: str) -> tuple[Path, str]:
    source_id = str(source_id or "").strip()
    asset_id = str(asset_id or "").strip().casefold()
    if not re.fullmatch(r"[0-9a-f]{64}", asset_id):
        raise ValueError("invalid image asset id")

    safe_source_id = re.sub(r"[^A-Za-z0-9._-]+", "-", source_id).strip("-") or LOCAL_SOURCE_ID
    manifest_path = IMAGE_MANIFEST_ROOT / f"{safe_source_id}.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        raise FileNotFoundError("image manifest not found")
    try:
        if manifest_path.stat().st_size > 64 * 1024 * 1024:
            raise UnsupportedImageError("image manifest is too large")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise FileNotFoundError("image manifest not found") from error
    if not isinstance(manifest, dict):
        raise FileNotFoundError("image manifest not found")

    asset_record: dict | None = None
    for item in manifest.get("assets") or []:
        if isinstance(item, dict) and str(item.get("assetId") or "").casefold() == asset_id:
            asset_record = item
            break
    if asset_record is None:
        raise FileNotFoundError("image asset not registered")

    declared_mime = str(asset_record.get("mimeType") or "")
    try:
        declared_size = int(asset_record.get("sizeBytes") or 0)
    except (TypeError, ValueError) as error:
        raise UnsupportedImageError("invalid image asset size") from error
    if declared_mime not in set(LOCAL_IMAGE_MIME_TYPES.values()):
        raise UnsupportedImageError("unsupported image type")
    if declared_size <= 0 or declared_size > MAX_LOCAL_IMAGE_BYTES:
        raise ImageTooLargeError("image exceeds 30 MiB limit")

    object_root = IMAGE_OBJECT_ROOT.resolve(strict=False)
    image_path = (IMAGE_OBJECT_ROOT / asset_id[:2] / f"{asset_id}.bin").resolve(strict=False)
    try:
        image_path.relative_to(object_root)
    except ValueError as error:
        raise FileNotFoundError("image asset not found") from error
    if image_path.is_symlink() or not image_path.is_file():
        raise FileNotFoundError("image asset not found")
    actual_size = image_path.stat().st_size
    if actual_size != declared_size or actual_size > MAX_LOCAL_IMAGE_BYTES:
        raise UnsupportedImageError("image asset size does not match manifest")
    detected_mime = detect_local_image_mime(image_path)
    if detected_mime != declared_mime:
        raise UnsupportedImageError("image asset content does not match manifest")
    return image_path, detected_mime


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
    if str(source_id).startswith("webdav-"):
        return get_webdav_service().load_remote_notes(source_id)
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
    if source_id.startswith("webdav-"):
        require_source_capability(source_id, "canEditNotes", "云端备注只能在来源设备编辑")
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
    if source_id.startswith("webdav-"):
        require_source_capability(source_id, "canEditNotes", "云端备注只能在来源设备编辑")
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


def remember_search_index(cache_key: str, parsed: dict, mtime_ns: int) -> dict:
    estimated_size = estimate_search_index_size(parsed)
    if estimated_size > SEARCH_INDEX_CACHE_MAX_BYTES:
        _search_index_cache.pop(cache_key, None)
        _search_index_mtime_ns.pop(cache_key, None)
        _search_index_cache_sizes.pop(cache_key, None)
        _search_index_access_order.pop(cache_key, None)
        return parsed
    _search_index_cache[cache_key] = parsed
    _search_index_mtime_ns[cache_key] = mtime_ns
    _search_index_cache_sizes[cache_key] = estimated_size
    _search_index_access_order.pop(cache_key, None)
    _search_index_access_order[cache_key] = None
    enforce_search_index_cache_limits()
    return parsed


def load_search_index(source_id: str = LOCAL_SOURCE_ID, part: str = "questions") -> dict:
    normalized_part = str(part or "questions").strip().casefold()
    if normalized_part not in {"questions", "other"}:
        raise ValueError("search index part must be 'questions' or 'other'")
    search_file = get_source_paths(source_id)["search" if normalized_part == "questions" else "search_other"]
    if not search_file.exists():
        return {"version": SEARCH_INDEX_VERSION, "part": normalized_part, "sessions": []}
    mtime_ns = search_file.stat().st_mtime_ns
    cache_key = f"{source_id}::{normalized_part}"
    with _search_index_lock:
        if cache_key in _search_index_cache and _search_index_mtime_ns.get(cache_key) == mtime_ns:
            _search_index_access_order.pop(cache_key, None)
            _search_index_access_order[cache_key] = None
            return _search_index_cache[cache_key]
        parsed = json.loads(search_file.read_text(encoding="utf-8"))
        return remember_search_index(cache_key, parsed, mtime_ns)


def search_sessions(
    query: str,
    source_id: str = LOCAL_SOURCE_ID,
    field: str = "all",
) -> list[dict]:
    normalized_field = str(field or "all").strip().casefold()
    if normalized_field not in SEARCH_FIELDS:
        raise ValueError("field must be 'all' or 'questions'")
    terms = [term for term in str(query or "").casefold().split() if term]
    if not terms:
        return []

    search_index = load_search_index(source_id, "questions")
    if search_index.get("version") != SEARCH_INDEX_VERSION or search_index.get("part") != "questions":
        raise ValueError("search index version is incompatible; refresh the source to rebuild it")
    other_text_by_key: dict[str, str] = {}
    if normalized_field == "all":
        other_index = load_search_index(source_id, "other")
        if other_index.get("version") != SEARCH_INDEX_VERSION or other_index.get("part") != "other":
            raise ValueError("search index version is incompatible; refresh the source to rebuild it")
        other_text_by_key = {
            str(session.get("key") or ""): str(session.get("otherText") or "").casefold()
            for session in other_index.get("sessions", [])
            if str(session.get("key") or "")
        }

    results: list[dict] = []
    for session in search_index.get("sessions", []):
        question_texts = [
            str(text or "").casefold()
            for text in (session.get("questionTexts") or [])
            if str(text or "")
        ]
        if normalized_field == "questions":
            matched = any(all(term in text for term in terms) for text in question_texts)
        else:
            searchable_parts = question_texts + [other_text_by_key.get(str(session.get("key") or ""), "")]
            matched = all(any(term in part for part in searchable_parts) for term in terms)
        if not matched:
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
    return HTML_FILE.exists() and paths["data"].exists() and paths["search"].exists() and paths["search_other"].exists()


def is_generated_page_stale() -> bool:
    try:
        return TEMPLATE_FILE.is_file() and TEMPLATE_FILE.stat().st_mtime_ns > HTML_FILE.stat().st_mtime_ns
    except OSError:
        return False


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


def is_mutation_request_authorized(headers, host: str, token: str = SESSION_TOKEN) -> bool:
    supplied_token = str(headers.get("X-Yuji-Session-Token") or "")
    if not supplied_token or not secrets.compare_digest(supplied_token, token):
        return False
    expected_origin = f"http://{str(host or '').strip()}"
    origin = str(headers.get("Origin") or "").rstrip("/")
    referer = str(headers.get("Referer") or "")
    return origin == expected_origin or referer == expected_origin or referer.startswith(expected_origin + "/")


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(SERVE_ROOT), **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def _stream_local_image(self, image_path: Path, mime_type: str) -> None:
        size = image_path.stat().st_size
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", mime_type)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        try:
            with image_path.open("rb") as stream:
                while True:
                    chunk = stream.read(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError):
            return

    def do_GET(self):
        parsed = urlparse(self.path)
        query_params = parse_qs(parsed.query)
        if parsed.path == "/api/session-token":
            self._write_json({"ok": True, "token": SESSION_TOKEN}, HTTPStatus.OK)
            return
        if parsed.path == "/api/session-image":
            try:
                source_id = resolve_source_id(query_params.get("sourceId", [""])[0], persist=False)
                image_path, mime_type = resolve_registered_local_image(
                    source_id,
                    query_params.get("sessionKey", [""])[0],
                    query_params.get("imageId", [""])[0],
                )
                self._stream_local_image(image_path, mime_type)
            except ValueError as error:
                self.send_error(HTTPStatus.BAD_REQUEST, str(error))
            except FileNotFoundError as error:
                self.send_error(HTTPStatus.NOT_FOUND, str(error))
            except UnsupportedImageError as error:
                self.send_error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, str(error))
            except ImageTooLargeError as error:
                self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, str(error))
            return
        if parsed.path == "/api/image-asset":
            try:
                source_id = resolve_source_id(query_params.get("sourceId", [""])[0], persist=False)
                image_path, mime_type = resolve_managed_image_asset(
                    source_id,
                    query_params.get("assetId", [""])[0],
                )
                self._stream_local_image(image_path, mime_type)
            except ValueError as error:
                self.send_error(HTTPStatus.BAD_REQUEST, str(error))
            except FileNotFoundError as error:
                self.send_error(HTTPStatus.NOT_FOUND, str(error))
            except UnsupportedImageError as error:
                self.send_error(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, str(error))
            except ImageTooLargeError as error:
                self.send_error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, str(error))
            return
        if parsed.path == "/api/sources":
            if query_params.get("refreshWebdav", [""])[0] in {"1", "true"}:
                try:
                    get_webdav_service().refresh_catalog()
                except (ConfigError, WebDAVError, ProtocolError, OSError, ValueError):
                    pass
            self._write_json(discover_sources(), HTTPStatus.OK)
            return
        if parsed.path == "/api/source-status":
            try:
                source_id = resolve_source_id(query_params.get("sourceId", [""])[0], persist=False)
                force = query_params.get("force", [""])[0] in {"1", "true"}
                self._write_json(get_webdav_service().source_status(source_id, force=force), HTTPStatus.OK)
            except (ConfigError, ValueError) as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
            return
        if parsed.path == "/api/webdav/settings":
            self._write_json(get_webdav_service().get_settings(), HTTPStatus.OK)
            return
        if parsed.path == "/api/webdav/task":
            self._write_json({"ok": True, "task": get_webdav_service().task_state()}, HTTPStatus.OK)
            return
        if parsed.path == "/api/webdav/cache":
            self._write_json({"ok": True, "cache": get_webdav_service().cache_entries()}, HTTPStatus.OK)
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
            field = query_params.get("field", ["all"])[0] or "all"
            try:
                source_id = resolve_source_id(query_params.get("sourceId", [""])[0])
                hits = search_sessions(query, source_id, field)
            except ValueError as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
                return
            self._write_json(
                {
                    "ok": True,
                    "sourceId": source_id,
                    "query": query,
                    "field": field,
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
        if not self._require_mutation_authorization():
            return

        webdav_routes = {
            "/api/webdav/settings",
            "/api/webdav/check",
            "/api/webdav/disable",
            "/api/webdav/unregister",
            "/api/webdav/upload",
            "/api/webdav/download",
            "/api/webdav/task/cancel",
        }
        if parsed.path in webdav_routes:
            try:
                body = self._read_json_body()
                service = get_webdav_service()
                if parsed.path == "/api/webdav/settings":
                    payload = service.save_settings(body)
                elif parsed.path == "/api/webdav/check":
                    payload = service.check_connection(body)
                elif parsed.path == "/api/webdav/disable":
                    payload = service.disable()
                elif parsed.path == "/api/webdav/unregister":
                    payload = service.unregister(
                        str(body.get("confirmationName") or ""),
                        clear_cache=bool(body.get("clearCache")),
                    )
                elif parsed.path == "/api/webdav/upload":
                    payload = {
                        "ok": True,
                        "task": service.start_upload(
                            str(body.get("sourceId") or ""),
                            str(body.get("confirmationToken") or ""),
                        ),
                    }
                elif parsed.path == "/api/webdav/download":
                    payload = {"ok": True, "task": service.start_download(str(body.get("sourceId") or ""))}
                else:
                    payload = {"ok": True, "task": service.cancel_task(str(body.get("taskId") or ""))}
                self._write_json(payload, HTTPStatus.OK)
            except TaskBusyError as error:
                self._write_json({"ok": False, "error": str(error), "task": error.task}, HTTPStatus.CONFLICT)
            except WebDAVError as error:
                status = HTTPStatus.TOO_MANY_REQUESTS if error.status == 429 else HTTPStatus.BAD_GATEWAY
                self._write_json(
                    {
                        "ok": False,
                        "error": str(error),
                        "httpStatus": error.status,
                        "reason": error.reason,
                        "retryAfter": error.retry_after,
                    },
                    status,
                )
            except (ConfigError, ProtocolError, ValueError) as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
            except OSError as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return

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
                payload = save_note(body)
                get_webdav_service().invalidate_source_status(source_id)
                self._write_json(payload, HTTPStatus.OK)
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

        required_capability = "canRebuild" if parsed.path == "/api/rebuild" else (
            "canQuickRefresh" if parsed.path == "/api/refresh-current" else "canRefresh"
        )
        try:
            require_source_capability(source_id, required_capability, "当前来源不支持此刷新操作")
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
        if not self._require_mutation_authorization():
            return
        if parsed.path == "/api/webdav/cache":
            try:
                body = self._read_json_body()
                self._write_json(
                    get_webdav_service().clear_cache(str(body.get("sourceId") or "")),
                    HTTPStatus.OK,
                )
            except TaskBusyError as error:
                self._write_json({"ok": False, "error": str(error), "task": error.task}, HTTPStatus.CONFLICT)
            except (ConfigError, ValueError) as error:
                self._write_json({"ok": False, "error": str(error)}, HTTPStatus.BAD_REQUEST)
            except OSError as error:
                self._write_json(
                    {"ok": False, "error": "本机云端缓存清理失败：" + str(error)},
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                )
            return
        if parsed.path != "/api/notes":
            self.send_error(HTTPStatus.NOT_FOUND, "Not found")
            return
        try:
            body = self._read_json_body()
            source_id = resolve_source_id(str(body.get("sourceId") or ""))
            payload = delete_note(str(body.get("key") or ""), source_id)
            get_webdav_service().invalidate_source_status(source_id)
            self._write_json(payload, HTTPStatus.OK)
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
        try:
            length = int(self.headers.get("Content-Length", "0") or "0")
        except ValueError as error:
            raise ValueError("invalid Content-Length") from error
        if length > MAX_JSON_BODY_BYTES:
            raise ValueError("JSON body exceeds 256 KiB limit")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ValueError("invalid JSON body") from error
        if not isinstance(payload, dict):
            raise ValueError("JSON body must be an object")
        return payload

    def _require_mutation_authorization(self) -> bool:
        if is_mutation_request_authorized(self.headers, self.headers.get("Host", "")):
            return True
        self._write_json({"ok": False, "error": "修改请求缺少有效的同源会话令牌"}, HTTPStatus.FORBIDDEN)
        return False


def main() -> int:
    parser = argparse.ArgumentParser(description="Local server for CodexChatIndex.html with refresh API")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--open", action="store_true", help="Open the browser after server starts")
    args = parser.parse_args()

    if args.host != "127.0.0.1":
        print("For security, CodexChatIndexServer only listens on 127.0.0.1.", file=sys.stderr)
        return 1

    # Initialize device-scoped runtime state only for the running application,
    # not for modules imported by isolated tests or tooling.
    get_webdav_service()

    if has_existing_startup_index() and not is_generated_page_stale():
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
