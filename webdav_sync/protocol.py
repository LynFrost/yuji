from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import tempfile
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Callable, Iterable


MIB = 1024 * 1024
OBJECT_THRESHOLD = 1 * MIB
CHUNK_SIZE = 64 * MIB
PROTOCOL = "YujiSync/v1"
SCHEMA_VERSION = 1
BUFFER_SIZE = 256 * 1024
MAX_NOTES_OBJECT_BYTES = 64 * MIB
VALID_SOURCE_TYPES = {"local-codex", "local-claude"}
VALID_ROOT_KINDS = {"sessions", "archived_sessions", "projects", "sessions_metadata", "claude_desktop"}
VALID_RECORD_FORMATS = {"jsonl", "json"}
VALID_ENTRYPOINTS = {"", "cli", "claude-desktop-3p"}


class ProtocolError(ValueError):
    pass


@dataclass
class SnapshotResult:
    source_type: str
    source_signature: object
    logical_files: list[dict]
    objects: dict[str, Path]
    chat_revision_id: str
    logical_bytes: int


def canonical_json_bytes(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _run_checkpoint(checkpoint: Callable[[], None] | None) -> None:
    if checkpoint:
        checkpoint()


def sha256_file(path: Path, checkpoint: Callable[[], None] | None = None) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            _run_checkpoint(checkpoint)
            chunk = stream.read(BUFFER_SIZE)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def validate_digest(value: str, field: str = "SHA-256") -> str:
    candidate = str(value or "")
    if len(candidate) != 64 or any(character not in "0123456789abcdef" for character in candidate):
        raise ProtocolError(f"{field} 格式无效")
    return candidate


def reject_required_features(document: dict, label: str) -> None:
    features = document.get("requiredFeatures")
    if features is None:
        return
    if not isinstance(features, list) or features:
        raise ProtocolError(f"{label} 包含当前版本不支持的 requiredFeatures")


def validate_logical_path(value: str) -> str:
    candidate = str(value or "").replace("\\", "/")
    if not candidate or "\x00" in candidate:
        raise ProtocolError("逻辑路径为空或包含 NUL")
    if candidate.startswith("/") or candidate.startswith("//") or PureWindowsPath(candidate).drive:
        raise ProtocolError("逻辑路径不能是绝对路径、UNC 或盘符路径")
    path = PurePosixPath(candidate)
    if any(part in {"", ".", ".."} for part in path.parts):
        raise ProtocolError("逻辑路径不能包含空段、. 或 ..")
    normalized = path.as_posix()
    if not normalized or normalized.startswith("../"):
        raise ProtocolError("逻辑路径逃逸")
    return normalized


def _normalized_source_meta(item: dict) -> dict:
    root_kind = str(item.get("rootKind") or "")
    record_format = str(item.get("recordFormat") or "")
    entrypoint = str(item.get("entrypoint") or "")
    if root_kind not in VALID_ROOT_KINDS:
        raise ProtocolError(f"不支持的 rootKind：{root_kind}")
    if record_format not in VALID_RECORD_FORMATS:
        raise ProtocolError(f"不支持的 recordFormat：{record_format}")
    if entrypoint not in VALID_ENTRYPOINTS:
        raise ProtocolError(f"不支持的 Claude entrypoint：{entrypoint}")
    return {"rootKind": root_kind, "recordFormat": record_format, "entrypoint": entrypoint}


def _chat_revision_rows(logical_files: Iterable[dict]) -> list[dict]:
    rows: list[dict] = []
    for item in logical_files:
        rows.append(
            {
                "logicalPath": validate_logical_path(str(item.get("logicalPath") or "")),
                "originPath": str(item.get("originPath") or ""),
                "size": int(item.get("size") or 0),
                "sha256": validate_digest(str(item.get("sha256") or ""), "逻辑文件 SHA-256"),
                "archived": bool(item.get("archived")),
                "sourceMeta": _normalized_source_meta(dict(item.get("sourceMeta") or item)),
            }
        )
    return sorted(rows, key=lambda item: item["logicalPath"])


def chat_revision_id(logical_files: Iterable[dict]) -> str:
    return sha256_bytes(canonical_json_bytes(_chat_revision_rows(logical_files)))


def build_notes_document(device_id: str, source_type: str, notes: dict) -> dict:
    if source_type not in VALID_SOURCE_TYPES:
        raise ProtocolError("备注来源类型无效")
    selected: dict[str, dict] = {}
    for storage_key, item in sorted((notes or {}).items(), key=lambda pair: str(pair[0])):
        if not isinstance(item, dict) or str(item.get("sourceId") or "local-codex") != source_type:
            continue
        selected[str(storage_key)] = dict(item)
    return {
        "schemaVersion": 1,
        "deviceId": str(uuid.UUID(str(device_id))),
        "sourceType": source_type,
        "notes": selected,
    }


def notes_revision_id(document: dict) -> str:
    return sha256_bytes(canonical_json_bytes(document))


def manifest_revision_id(manifest: dict) -> str:
    return sha256_bytes(canonical_json_bytes(manifest))


def _copy_exact(source: Path, target: Path, length: int, checkpoint: Callable[[], None] | None = None) -> None:
    remaining = length
    with source.open("rb") as input_stream, target.open("wb") as output_stream:
        while remaining:
            _run_checkpoint(checkpoint)
            chunk = input_stream.read(min(BUFFER_SIZE, remaining))
            if not chunk:
                raise ProtocolError(f"源文件发生短读：{source}")
            output_stream.write(chunk)
            remaining -= len(chunk)


def _trim_jsonl_to_complete_line(path: Path, checkpoint: Callable[[], None] | None = None) -> None:
    size = path.stat().st_size
    if not size:
        return
    with path.open("r+b") as stream:
        offset = size
        last_newline = -1
        while offset > 0 and last_newline < 0:
            _run_checkpoint(checkpoint)
            read_size = min(BUFFER_SIZE, offset)
            offset -= read_size
            stream.seek(offset)
            chunk = stream.read(read_size)
            position = chunk.rfind(b"\n")
            if position >= 0:
                last_newline = offset + position
        stream.truncate(last_newline + 1 if last_newline >= 0 else 0)


def _snapshot_file(
    source: Path,
    record_format: str,
    target: Path,
    declared_size: int | None = None,
    checkpoint: Callable[[], None] | None = None,
) -> tuple[int, str]:
    if source.is_symlink() or not source.is_file():
        raise ProtocolError(f"同步源不是普通文件或属于符号链接：{source}")
    target.parent.mkdir(parents=True, exist_ok=True)
    attempts = 2 if record_format == "json" else 1
    for attempt in range(attempts):
        _run_checkpoint(checkpoint)
        before = source.stat()
        snapshot_length = before.st_size
        if record_format == "jsonl" and declared_size is not None:
            if declared_size < 0 or before.st_size < declared_size:
                raise ProtocolError(f"JSONL 在任务扫描后被截短：{source}")
            snapshot_length = declared_size
        _copy_exact(source, target, snapshot_length, checkpoint)
        if record_format == "jsonl":
            _trim_jsonl_to_complete_line(target, checkpoint)
        after = source.stat()
        if record_format != "json" or (before.st_size == after.st_size and before.st_mtime_ns == after.st_mtime_ns):
            return target.stat().st_size, sha256_file(target, checkpoint)
        if attempt + 1 == attempts:
            raise ProtocolError(f"Claude JSON 元信息在读取期间持续变化：{source}")
    raise ProtocolError(f"无法读取同步源：{source}")


def _store_object(
    source: Path,
    objects_root: Path,
    objects: dict[str, Path],
    checkpoint: Callable[[], None] | None = None,
) -> tuple[str, int]:
    digest = sha256_file(source, checkpoint)
    size = source.stat().st_size
    target = objects_root / digest[:2] / f"{digest}.bin"
    if not target.exists():
        target.parent.mkdir(parents=True, exist_ok=True)
        _copy_exact(source, target, size, checkpoint)
    objects[digest] = target
    return digest, size


def _zip_segment(
    entries: list[dict],
    objects_root: Path,
    objects: dict[str, Path],
    temp_root: Path,
    checkpoint: Callable[[], None] | None = None,
) -> tuple[str, int]:
    temporary = temp_root / f"pack-{uuid.uuid4().hex}.zip"
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=1, strict_timestamps=True) as archive:
        for entry in entries:
            _run_checkpoint(checkpoint)
            info = zipfile.ZipInfo(entry["logicalPath"], date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 0
            info.external_attr = 0o600 << 16
            with entry["snapshotPath"].open("rb") as source, archive.open(info, "w", force_zip64=True) as output:
                while True:
                    _run_checkpoint(checkpoint)
                    chunk = source.read(BUFFER_SIZE)
                    if not chunk:
                        break
                    output.write(chunk)
    digest, size = _store_object(temporary, objects_root, objects, checkpoint)
    temporary.unlink(missing_ok=True)
    return digest, size


def create_snapshot(
    inventory: dict,
    staging_root: Path,
    *,
    checkpoint: Callable[[], None] | None = None,
) -> SnapshotResult:
    _run_checkpoint(checkpoint)
    if not isinstance(inventory, dict) or not bool(inventory.get("scanComplete")):
        raise ProtocolError("同步 inventory 扫描不完整")
    if list(inventory.get("errors") or []):
        raise ProtocolError("同步 inventory 包含未处理扫描错误")
    source_type = str(inventory.get("sourceType") or "")
    if source_type not in VALID_SOURCE_TYPES:
        raise ProtocolError("只允许本机 Codex 或本机 Claude 创建上传快照")

    staging_root = Path(staging_root)
    snapshots_root = staging_root / "snapshots"
    objects_root = staging_root / "objects"
    temp_root = staging_root / "temp"
    temp_root.mkdir(parents=True, exist_ok=True)
    objects: dict[str, Path] = {}
    prepared: list[dict] = []
    seen: set[str] = set()

    for index, raw_item in enumerate(inventory.get("files") or []):
        _run_checkpoint(checkpoint)
        if not isinstance(raw_item, dict):
            raise ProtocolError("同步 inventory 文件项无效")
        logical_path = validate_logical_path(str(raw_item.get("logicalPath") or ""))
        if logical_path in seen:
            raise ProtocolError(f"重复逻辑路径：{logical_path}")
        seen.add(logical_path)
        source_meta = _normalized_source_meta(raw_item)
        source_path = Path(str(raw_item.get("absolutePath") or ""))
        snapshot_path = snapshots_root / f"{index:08d}.bin"
        declared_size = int(raw_item["sizeBytes"]) if "sizeBytes" in raw_item else None
        size, digest = _snapshot_file(
            source_path,
            source_meta["recordFormat"],
            snapshot_path,
            declared_size,
            checkpoint,
        )
        prepared.append(
            {
                "logicalPath": logical_path,
                "originPath": str(raw_item.get("originPath") or source_path),
                "size": size,
                "sha256": digest,
                "archived": bool(raw_item.get("archived")),
                "sourceMeta": source_meta,
                "snapshotPath": snapshot_path,
            }
        )

    small_buckets: dict[str, list[dict]] = {}
    for item in prepared:
        if item["size"] < OBJECT_THRESHOLD:
            bucket = hashlib.sha256(item["logicalPath"].encode("utf-8")).hexdigest()[:2]
            small_buckets.setdefault(bucket, []).append(item)

    for bucket in sorted(small_buckets):
        _run_checkpoint(checkpoint)
        entries = sorted(small_buckets[bucket], key=lambda item: item["logicalPath"])
        segment: list[dict] = []
        segment_size = 0
        segments: list[list[dict]] = []
        for entry in entries:
            if segment and segment_size + entry["size"] > CHUNK_SIZE:
                segments.append(segment)
                segment = []
                segment_size = 0
            segment.append(entry)
            segment_size += entry["size"]
        if segment:
            segments.append(segment)
        for segment in segments:
            digest, object_size = _zip_segment(segment, objects_root, objects, temp_root, checkpoint)
            for entry in segment:
                entry["storage"] = {
                    "type": "pack-entry",
                    "objectSha256": digest,
                    "objectSize": object_size,
                    "entry": entry["logicalPath"],
                }

    for item in prepared:
        _run_checkpoint(checkpoint)
        if "storage" in item:
            continue
        if item["size"] <= CHUNK_SIZE:
            digest, size = _store_object(item["snapshotPath"], objects_root, objects, checkpoint)
            item["storage"] = {"type": "object", "sha256": digest, "size": size}
            continue
        chunks: list[dict] = []
        with item["snapshotPath"].open("rb") as source:
            index = 0
            while True:
                chunk_path = temp_root / f"chunk-{uuid.uuid4().hex}.bin"
                written = 0
                with chunk_path.open("wb") as output:
                    while written < CHUNK_SIZE:
                        _run_checkpoint(checkpoint)
                        chunk = source.read(min(BUFFER_SIZE, CHUNK_SIZE - written))
                        if not chunk:
                            break
                        output.write(chunk)
                        written += len(chunk)
                if not written:
                    chunk_path.unlink(missing_ok=True)
                    break
                digest, size = _store_object(chunk_path, objects_root, objects, checkpoint)
                chunk_path.unlink(missing_ok=True)
                chunks.append({"index": index, "sha256": digest, "size": size})
                index += 1
        item["storage"] = {"type": "chunks", "chunks": chunks}

    logical_files: list[dict] = []
    for item in sorted(prepared, key=lambda value: value["logicalPath"]):
        logical_files.append({key: value for key, value in item.items() if key != "snapshotPath"})
    return SnapshotResult(
        source_type=source_type,
        source_signature=inventory.get("sourceSignature"),
        logical_files=logical_files,
        objects=objects,
        chat_revision_id=chat_revision_id(logical_files),
        logical_bytes=sum(item["size"] for item in logical_files),
    )


def create_full_manifest(device_id: str, snapshot: SnapshotResult, notes_document: dict) -> tuple[dict, bytes, str]:
    notes_bytes = canonical_json_bytes(notes_document)
    notes_digest = sha256_bytes(notes_bytes)
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "protocol": PROTOCOL,
        "deviceId": str(uuid.UUID(str(device_id))),
        "sourceType": snapshot.source_type,
        "chatRevisionId": snapshot.chat_revision_id,
        "notesRevisionId": notes_digest,
        "logicalFileCount": len(snapshot.logical_files),
        "logicalBytes": snapshot.logical_bytes,
        "logicalFiles": sorted(snapshot.logical_files, key=lambda item: item["logicalPath"]),
        "notes": {
            "path": f"notes/{notes_digest}.json",
            "size": len(notes_bytes),
            "sha256": notes_digest,
        },
    }
    return manifest, notes_bytes, manifest_revision_id(manifest)


def validate_full_manifest(manifest: dict, *, device_id: str = "", source_type: str = "") -> dict:
    if not isinstance(manifest, dict):
        raise ProtocolError("完整 manifest 不是对象")
    if int(manifest.get("schemaVersion") or 0) != SCHEMA_VERSION or manifest.get("protocol") != PROTOCOL:
        raise ProtocolError("不支持的云端协议或 schemaVersion")
    reject_required_features(manifest, "完整 manifest")
    if manifest.get("requiredFeatures"):
        raise ProtocolError("云端清单要求当前版本不支持的功能")
    actual_device = str(uuid.UUID(str(manifest.get("deviceId") or "")))
    actual_source = str(manifest.get("sourceType") or "")
    if device_id and actual_device != str(uuid.UUID(device_id)):
        raise ProtocolError("manifest deviceId 与来源目录不一致")
    if source_type and actual_source != source_type:
        raise ProtocolError("manifest sourceType 与当前来源不一致")
    if actual_source not in VALID_SOURCE_TYPES:
        raise ProtocolError("manifest sourceType 无效")
    validate_digest(str(manifest.get("chatRevisionId") or ""), "chatRevisionId")
    notes_revision = validate_digest(str(manifest.get("notesRevisionId") or ""), "notesRevisionId")
    notes = manifest.get("notes")
    if not isinstance(notes, dict):
        raise ProtocolError("manifest notes 无效")
    if str(notes.get("path") or "") != f"notes/{notes_revision}.json":
        raise ProtocolError("manifest notes.path 与 notesRevisionId 不一致")
    if validate_digest(str(notes.get("sha256") or ""), "notes SHA-256") != notes_revision:
        raise ProtocolError("manifest notes.sha256 与 notesRevisionId 不一致")
    notes_size = int(notes.get("size") or 0)
    if notes_size < 0 or notes_size > MAX_NOTES_OBJECT_BYTES:
        raise ProtocolError("manifest notes.size 超出允许范围")
    logical_files = list(manifest.get("logicalFiles") or [])
    if int(manifest.get("logicalFileCount") or 0) != len(logical_files):
        raise ProtocolError("manifest logicalFileCount 不一致")
    if logical_files != sorted(logical_files, key=lambda item: str(item.get("logicalPath") or "")):
        raise ProtocolError("manifest logicalFiles 未按 logicalPath 排序")
    normalized_paths = [validate_logical_path(str(item.get("logicalPath") or "")) for item in logical_files]
    if len(set(normalized_paths)) != len(normalized_paths) or len({path.casefold() for path in normalized_paths}) != len(normalized_paths):
        raise ProtocolError("manifest logicalPath 重复")
    _chat_revision_rows(logical_files)
    if chat_revision_id(logical_files) != manifest["chatRevisionId"]:
        raise ProtocolError("manifest chatRevisionId 校验失败")
    if sum(int(item.get("size") or 0) for item in logical_files) != int(manifest.get("logicalBytes") or 0):
        raise ProtocolError("manifest logicalBytes 不一致")
    return manifest


def validate_current_pointer(pointer: dict, *, device_id: str, source_type: str) -> dict:
    if not isinstance(pointer, dict):
        raise ProtocolError("manifest.json 当前指针不是对象")
    if int(pointer.get("schemaVersion") or 0) != SCHEMA_VERSION or pointer.get("protocol") != PROTOCOL:
        raise ProtocolError("不支持的 manifest.json 当前指针")
    reject_required_features(pointer, "当前指针")
    if str(pointer.get("deviceId") or "") != str(uuid.UUID(device_id)):
        raise ProtocolError("当前指针 deviceId 不一致")
    if str(pointer.get("sourceType") or "") != source_type:
        raise ProtocolError("当前指针 sourceType 不一致")
    revision = validate_digest(str(pointer.get("manifestRevisionId") or ""), "manifestRevisionId")
    if pointer.get("manifestPath") != f"manifests/{revision}.json":
        raise ProtocolError("manifestPath 与 manifestRevisionId 不一致")
    validate_digest(str(pointer.get("chatRevisionId") or ""), "chatRevisionId")
    validate_digest(str(pointer.get("notesRevisionId") or ""), "notesRevisionId")
    return pointer


def referenced_object_digests(manifest: dict) -> set[str]:
    values: set[str] = set()
    for item in manifest.get("logicalFiles") or []:
        storage = dict(item.get("storage") or {})
        storage_type = storage.get("type")
        if storage_type == "object":
            values.add(validate_digest(str(storage.get("sha256") or ""), "object SHA-256"))
        elif storage_type == "pack-entry":
            values.add(validate_digest(str(storage.get("objectSha256") or ""), "pack SHA-256"))
        elif storage_type == "chunks":
            chunks = list(storage.get("chunks") or [])
            if chunks != sorted(chunks, key=lambda chunk: int(chunk.get("index", -1))):
                raise ProtocolError("chunks 未按数字序号排序")
            values.update(validate_digest(str(chunk.get("sha256") or ""), "chunk SHA-256") for chunk in chunks)
        else:
            raise ProtocolError("未知 storage 类型")
    return values


def _verify_object(
    path: Path,
    digest: str,
    expected_size: int | None = None,
    checkpoint: Callable[[], None] | None = None,
) -> None:
    if not path.is_file() or path.is_symlink():
        raise ProtocolError(f"对象缺失：{digest}")
    if expected_size is not None and path.stat().st_size != expected_size:
        raise ProtocolError(f"对象大小不一致：{digest}")
    if sha256_file(path, checkpoint) != digest:
        raise ProtocolError(f"对象 SHA-256 不一致：{digest}")


def _safe_output_path(root: Path, logical_path: str) -> Path:
    normalized = validate_logical_path(logical_path)
    target = root.joinpath(*PurePosixPath(normalized).parts)
    resolved_root = root.resolve()
    resolved_parent = target.parent.resolve()
    try:
        resolved_parent.relative_to(resolved_root)
    except ValueError as error:
        raise ProtocolError("解包路径逃逸 staging 根目录") from error
    return target


def materialize_snapshot(
    manifest: dict,
    objects: dict[str, Path],
    destination: Path,
    *,
    checkpoint: Callable[[], None] | None = None,
) -> dict[str, str]:
    _run_checkpoint(checkpoint)
    manifest = validate_full_manifest(manifest)
    destination = Path(destination)
    temporary = destination.with_name(f".{destination.name}.{uuid.uuid4().hex}.staging")
    if destination.exists():
        raise ProtocolError("解包目标必须是尚不存在的 staging 目录")
    origin_map: dict[str, str] = {}
    pack_entries: dict[str, dict[str, int]] = {}
    try:
        temporary.mkdir(parents=True)
        for item in manifest["logicalFiles"]:
            _run_checkpoint(checkpoint)
            storage = dict(item.get("storage") or {})
            if storage.get("type") == "pack-entry":
                digest = validate_digest(str(storage.get("objectSha256") or ""))
                entry = validate_logical_path(str(storage.get("entry") or ""))
                if entry != item["logicalPath"]:
                    raise ProtocolError("ZIP entry 与 logicalPath 不一致")
                entries = pack_entries.setdefault(digest, {})
                if entry in entries:
                    raise ProtocolError("ZIP entry 在 manifest 中重复")
                entries[entry] = int(item.get("size") or 0)

        for digest, expected_entries in pack_entries.items():
            _run_checkpoint(checkpoint)
            object_path = Path(objects.get(digest) or "")
            _verify_object(object_path, digest, checkpoint=checkpoint)
            try:
                with zipfile.ZipFile(object_path, "r") as archive:
                    names = [validate_logical_path(info.filename) for info in archive.infolist()]
                    if set(names) != set(expected_entries) or len(names) != len(expected_entries):
                        raise ProtocolError("ZIP 包包含未声明、重复或缺失的 entry")
                    for info in archive.infolist():
                        mode = info.external_attr >> 16
                        file_type = stat.S_IFMT(mode)
                        special_permissions = mode & (stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX)
                        if file_type not in {0, stat.S_IFREG} or special_permissions:
                            raise ProtocolError("ZIP 包包含符号链接、设备文件或特殊权限 entry")
                        if info.flag_bits & 0x1:
                            raise ProtocolError("ZIP 包包含加密 entry")
                        if int(info.file_size) != expected_entries[validate_logical_path(info.filename)]:
                            raise ProtocolError("ZIP entry 大小与 manifest 不一致")
            except zipfile.BadZipFile as error:
                raise ProtocolError("ZIP 对象损坏") from error

        written_total = 0
        for item in manifest["logicalFiles"]:
            _run_checkpoint(checkpoint)
            logical_path = validate_logical_path(str(item.get("logicalPath") or ""))
            target = _safe_output_path(temporary, logical_path)
            target.parent.mkdir(parents=True, exist_ok=True)
            storage = dict(item.get("storage") or {})
            storage_type = storage.get("type")
            if storage_type == "object":
                digest = validate_digest(str(storage.get("sha256") or ""))
                source = Path(objects.get(digest) or "")
                _verify_object(source, digest, int(storage.get("size") or 0), checkpoint)
                _copy_exact(source, target, source.stat().st_size, checkpoint)
            elif storage_type == "pack-entry":
                digest = validate_digest(str(storage.get("objectSha256") or ""))
                source = Path(objects.get(digest) or "")
                _verify_object(source, digest, int(storage.get("objectSize") or 0), checkpoint)
                expected_size = int(item.get("size") or 0)
                written = 0
                with zipfile.ZipFile(source, "r") as archive, archive.open(str(storage["entry"]), "r") as packed, target.open("wb") as output:
                    while True:
                        _run_checkpoint(checkpoint)
                        chunk = packed.read(min(BUFFER_SIZE, expected_size - written + 1))
                        if not chunk:
                            break
                        if written + len(chunk) > expected_size:
                            raise ProtocolError("ZIP entry 解压大小超过 manifest 声明")
                        output.write(chunk)
                        written += len(chunk)
                if written != expected_size:
                    raise ProtocolError("ZIP entry 解压大小与 manifest 不一致")
            elif storage_type == "chunks":
                chunks = sorted(list(storage.get("chunks") or []), key=lambda chunk: int(chunk.get("index", -1)))
                with target.open("wb") as output:
                    for expected_index, chunk in enumerate(chunks):
                        if int(chunk.get("index", -1)) != expected_index:
                            raise ProtocolError("chunk 序号不连续")
                        digest = validate_digest(str(chunk.get("sha256") or ""))
                        source = Path(objects.get(digest) or "")
                        _verify_object(source, digest, int(chunk.get("size") or 0), checkpoint)
                        with source.open("rb") as input_stream:
                            while True:
                                _run_checkpoint(checkpoint)
                                data = input_stream.read(BUFFER_SIZE)
                                if not data:
                                    break
                                output.write(data)
            else:
                raise ProtocolError("未知 storage 类型")

            size = target.stat().st_size
            if size != int(item.get("size") or 0) or sha256_file(target, checkpoint) != str(item.get("sha256") or ""):
                raise ProtocolError(f"逻辑文件校验失败：{logical_path}")
            written_total += size
            if written_total > int(manifest.get("logicalBytes") or 0):
                raise ProtocolError("解包总大小超过 manifest.logicalBytes")
            origin_map[logical_path] = str(item.get("originPath") or "")
        if written_total != int(manifest.get("logicalBytes") or 0):
            raise ProtocolError("解包总大小与 manifest.logicalBytes 不一致")
        _run_checkpoint(checkpoint)
        os.replace(temporary, destination)
        return origin_map
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise
