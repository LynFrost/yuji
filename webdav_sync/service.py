from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import threading
import time
import uuid
from collections import OrderedDict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable
from urllib.parse import quote, unquote, urlsplit

from .client import WebDAVClient, WebDAVError
from .config import (
    ConfigError,
    RuntimePaths,
    decrypt_settings_password,
    load_or_create_device,
    load_public_settings,
    load_raw_settings,
    read_json,
    save_settings,
    safe_uuid,
    utc_now,
    validate_remote_root,
    validate_webdav_url,
    write_json_atomic,
)
from .protocol import (
    IMAGE_PROTOCOL,
    PROTOCOL,
    ProtocolError,
    SnapshotResult,
    build_image_manifest,
    build_notes_document,
    canonical_json_bytes,
    create_full_manifest,
    create_snapshot,
    image_manifest_revision_id,
    manifest_revision_id,
    materialize_snapshot,
    referenced_object_digests,
    reject_required_features,
    sha256_bytes,
    sha256_file,
    validate_current_pointer,
    validate_digest,
    validate_full_manifest,
    validate_image_manifest,
    validate_image_pointer,
)
from .tasks import TaskBusyError, TaskCancelled, TaskContext, TaskManager


DEVICE_JSON_LIMIT = 256 * 1024
POINTER_JSON_LIMIT = 256 * 1024
MANIFEST_JSON_LIMIT = 64 * 1024 * 1024
NOTES_JSON_LIMIT = 64 * 1024 * 1024
POINTER_CACHE_MAX_ENTRIES = 256
UPLOAD_JOURNAL_MAX_BYTES = 16 * 1024 * 1024
UPLOAD_JOURNAL_MAX_ENTRIES = 131072
DOWNLOAD_MIN_INDEX_BUDGET_BYTES = 64 * 1024 * 1024
DOWNLOAD_SAFETY_BYTES = 64 * 1024 * 1024
LOCAL_TRANSACTION_MAX_BYTES = 64 * 1024
LOCAL_TASK_STATE_MAX_BYTES = 1024 * 1024
REMOTE_LOCK_OWNER_LIMIT = 64 * 1024
REMOTE_LOCK_LEASE_SECONDS = 120
REMOTE_LOCK_RENEW_SECONDS = 30
LOCAL_TRANSACTION_VERSION = 1
LOCAL_TRANSACTION_KINDS = {"download-commit", "index-rebuild", "cache-metadata"}
LOCAL_TRANSACTION_PHASES = {"prepared", "commit-ready"}
LOCAL_TRANSACTION_KEYS = {
    "version",
    "transactionId",
    "connectionId",
    "sourceId",
    "kind",
    "phase",
    "hadIndex",
    "hadCache",
    "manifestRevisionId",
    "chatRevisionId",
    "notesRevisionId",
}
LOCAL_SOURCE_TYPES = {"local-codex", "local-claude"}
REMOTE_TYPE_MAP = {"local-codex": "webdav-codex", "local-claude": "webdav-claude"}
REMOTE_SOURCE_PATTERN = re.compile(
    r"^webdav-([0-9a-f-]{36})-([0-9a-f-]{36})-(local-codex|local-claude)$",
    re.IGNORECASE,
)
IMAGE_MANIFEST_JSON_LIMIT = 64 * 1024 * 1024
IMAGE_POINTER_JSON_LIMIT = 256 * 1024


LOCAL_CAPABILITIES = {
    "canRefresh": True,
    "canQuickRefresh": True,
    "canRebuild": True,
    "canUpload": True,
    "canDownload": False,
    "canResume": True,
    "canReply": True,
    "canEditNotes": True,
    "canResolveLocalImages": True,
    "isReadOnly": False,
}
EXTERNAL_CAPABILITIES = {
    "canRefresh": True,
    "canQuickRefresh": True,
    "canRebuild": True,
    "canUpload": False,
    "canDownload": False,
    "canResume": False,
    "canReply": False,
    "canEditNotes": True,
    "canResolveLocalImages": True,
    "isReadOnly": False,
}
REMOTE_CAPABILITIES = {
    "canRefresh": False,
    "canQuickRefresh": False,
    "canRebuild": True,
    "canUpload": False,
    "canDownload": True,
    "canResume": False,
    "canReply": False,
    "canEditNotes": False,
    "canResolveLocalImages": False,
    "isReadOnly": True,
}


class ConfirmationRequiredError(RuntimeError):
    task_status = "needs-confirmation"
    task_stage = "等待确认"

    def __init__(self, token: str, deleted_count: int, previous_count: int) -> None:
        super().__init__(
            f"本次上传将删除 {deleted_count} 条云端记录（原有 {previous_count} 条），需要明确确认"
        )
        self.task_payload = {
            "confirmationToken": token,
            "deletedCount": deleted_count,
            "previousCount": previous_count,
        }


class LocalRecoveryError(ConfigError):
    pass


def capabilities_for_type(source_type: str) -> dict:
    if source_type in LOCAL_SOURCE_TYPES:
        return dict(LOCAL_CAPABILITIES)
    if source_type in REMOTE_TYPE_MAP.values():
        return dict(REMOTE_CAPABILITIES)
    return dict(EXTERNAL_CAPABILITIES)


def remote_source_id(connection_id: str, device_id: str, source_type: str) -> str:
    if source_type not in LOCAL_SOURCE_TYPES:
        raise ValueError("无效的远端来源类型")
    return f"webdav-{safe_uuid(connection_id)}-{safe_uuid(device_id)}-{source_type}"


def parse_remote_source_id(source_id: str) -> tuple[str, str, str]:
    match = REMOTE_SOURCE_PATTERN.fullmatch(str(source_id or ""))
    if not match:
        raise ValueError("无效的云端 sourceId")
    return safe_uuid(match.group(1)), safe_uuid(match.group(2)), match.group(3).casefold()


def _directory_size(
    path: Path,
    on_error: Callable[[Path, OSError], None] | None = None,
) -> int:
    total = 0
    if not path.exists():
        return 0
    try:
        for item in path.rglob("*"):
            try:
                if item.is_file() and not item.is_symlink():
                    total += item.stat().st_size
            except OSError as error:
                if on_error is not None:
                    on_error(item, error)
    except OSError as error:
        if on_error is None:
            raise
        on_error(path, error)
    return total


class BuildResourceCoordinator:
    def __init__(self) -> None:
        self._condition = threading.Condition(threading.RLock())
        self._local_build_count = 0

    def begin_local_build(self) -> None:
        with self._condition:
            self._local_build_count += 1
            self._condition.notify_all()

    def end_local_build(self) -> None:
        with self._condition:
            self._local_build_count = max(0, self._local_build_count - 1)
            self._condition.notify_all()

    def webdav_checkpoint(self, cancel_check: Callable[[], None]) -> None:
        cancel_check()
        with self._condition:
            while self._local_build_count:
                self._condition.wait(timeout=0.1)
                cancel_check()
        cancel_check()


class WebDAVSyncService:
    def __init__(
        self,
        runtime_root: Path,
        build_script: Path,
        *,
        notes_file: Path | None = None,
        paths: RuntimePaths | None = None,
        client_factory: Callable[[dict], object] | None = None,
        password_loader: Callable[[dict], str] = decrypt_settings_password,
        password_protector: Callable[[str], str] | None = None,
        inventory_provider: Callable[[str, Path], dict] | None = None,
        remote_build_runner: Callable[[dict, Path, Path, Path], Path] | None = None,
        resource_coordinator: BuildResourceCoordinator | None = None,
    ) -> None:
        self.runtime_root = Path(runtime_root)
        self.build_script = Path(build_script)
        self.notes_file = Path(notes_file) if notes_file else self.runtime_root / "CodexChatIndex.notes.json"
        self.identity_error = ""
        try:
            self.paths = paths or RuntimePaths.for_current_user(self.runtime_root)
            self.device = load_or_create_device(self.paths)
        except ConfigError as error:
            self.identity_error = str(error)
            self.paths = paths or RuntimePaths(self.runtime_root, "identity-unavailable")
            self.device = {"version": 1, "deviceId": "", "createdAt": ""}
        self._client_factory = client_factory
        self._password_loader = password_loader
        self._password_protector = password_protector
        self._inventory_provider = inventory_provider or self._export_inventory
        self._remote_build_runner = remote_build_runner
        self._resource_coordinator = resource_coordinator or BuildResourceCoordinator()
        self._lock = threading.RLock()
        self._status_cache: dict[str, tuple[float, dict]] = {}
        self._pointer_cache: OrderedDict[tuple[str, str, str], tuple[str, dict]] = OrderedDict()
        self._image_sync_thread: threading.Thread | None = None
        self._image_sync_source = ""
        self.recovery_error = ""
        self.recovery_warning = ""
        self._recover_local_transactions()
        if not self.recovery_error:
            self._recover_pending_local_cleanup()
            self._recover_interrupted_task_staging()
        self._task_manager = self._new_task_manager()

    def _webdav_checkpoint(self, context: TaskContext) -> None:
        self._resource_coordinator.webdav_checkpoint(context.check_cancelled)

    def _upload_checkpoint(
        self,
        context: TaskContext,
        client: object,
        settings: dict,
        remote_lock: dict | None,
        *,
        force_lock_check: bool = False,
    ) -> None:
        self._webdav_checkpoint(context)
        if remote_lock is not None:
            self._maintain_remote_commit_lock(
                client,
                settings,
                remote_lock,
                force=force_lock_check,
            )

    def _require_identity(self) -> None:
        if self.identity_error or not self.device.get("deviceId"):
            raise ConfigError(self.identity_error or "WebDAV 设备身份不可用")

    def _require_recovery_ready(self) -> None:
        if self.recovery_error:
            raise LocalRecoveryError(f"本机缓存恢复失败，WebDAV 修改操作已停止：{self.recovery_error}")

    @staticmethod
    def _path_exists(path: Path) -> bool:
        return path.exists() or path.is_symlink()

    @staticmethod
    def _require_confined_path(path: Path, root: Path, label: str) -> None:
        try:
            resolved_path = path.resolve(strict=False)
            resolved_root = root.resolve(strict=False)
            if not resolved_path.is_relative_to(resolved_root):
                raise LocalRecoveryError(f"{label}超出允许的本机目录")
        except OSError as error:
            raise LocalRecoveryError(f"{label}无法校验") from error

    @classmethod
    def _require_plain_directory(cls, path: Path, label: str) -> None:
        if path.is_symlink() or not path.is_dir():
            raise LocalRecoveryError(f"{label}不是可用目录")

    def _transaction_paths(self, transaction: dict) -> dict[str, Path | None]:
        connection_id, device_id, source_type = parse_remote_source_id(transaction["sourceId"])
        if connection_id != transaction["connectionId"]:
            raise LocalRecoveryError("本机替换事务的 sourceId 不属于记录的连接")
        connection_root = self.paths.connection_root(connection_id)
        index_root = self._index_root(transaction["sourceId"])
        cache_root = connection_root / "devices" / device_id / source_type
        transaction_root = connection_root / "transactions"
        transaction_file = transaction_root / f"{transaction['transactionId']}.json"
        index_backup = index_root.with_name(f".{index_root.name}.{transaction['transactionId']}.old")
        cache_backup = cache_root.with_name(f".{cache_root.name}.{transaction['transactionId']}.old")
        for path, root, label in (
            (transaction_file, transaction_root, "事务文件"),
            (index_root, self.paths.sources_root, "索引目录"),
            (index_backup, self.paths.sources_root, "索引备份目录"),
            (cache_root, connection_root, "缓存目录"),
            (cache_backup, connection_root, "缓存备份目录"),
        ):
            self._require_confined_path(path, root, label)
        return {
            "connectionRoot": connection_root,
            "transactionRoot": transaction_root,
            "transactionFile": transaction_file,
            "index": index_root,
            "indexBackup": index_backup,
            "cache": cache_root,
            "cacheBackup": cache_backup,
        }

    def _read_local_transaction(self, path: Path, parent_connection_id: str) -> dict:
        if path.is_symlink() or not path.is_file():
            raise LocalRecoveryError("本机替换事务不是普通文件")
        try:
            if path.stat().st_size > LOCAL_TRANSACTION_MAX_BYTES:
                raise LocalRecoveryError("本机替换事务文件过大")
            value = json.loads(path.read_text(encoding="utf-8"))
        except LocalRecoveryError:
            raise
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise LocalRecoveryError("本机替换事务文件损坏") from error
        if not isinstance(value, dict) or set(value) != LOCAL_TRANSACTION_KEYS:
            raise LocalRecoveryError("本机替换事务字段无效")
        try:
            transaction_id = safe_uuid(str(value.get("transactionId") or ""))
            connection_id = safe_uuid(str(value.get("connectionId") or ""))
        except ConfigError as error:
            raise LocalRecoveryError("本机替换事务包含非法 ID") from error
        if (
            str(value.get("transactionId") or "") != transaction_id
            or path.name != f"{transaction_id}.json"
            or str(value.get("connectionId") or "") != connection_id
            or connection_id != parent_connection_id
        ):
            raise LocalRecoveryError("本机替换事务 ID 与所在目录不一致")
        try:
            source_connection, _device_id, _source_type = parse_remote_source_id(str(value.get("sourceId") or ""))
        except (ConfigError, ValueError) as error:
            raise LocalRecoveryError("本机替换事务包含非法 sourceId") from error
        if source_connection != connection_id:
            raise LocalRecoveryError("本机替换事务来源不属于所在连接")
        if value.get("version") != LOCAL_TRANSACTION_VERSION:
            raise LocalRecoveryError("本机替换事务版本不受支持")
        if value.get("kind") not in LOCAL_TRANSACTION_KINDS or value.get("phase") not in LOCAL_TRANSACTION_PHASES:
            raise LocalRecoveryError("本机替换事务类型或阶段无效")
        if type(value.get("hadIndex")) is not bool or type(value.get("hadCache")) is not bool:
            raise LocalRecoveryError("本机替换事务目录状态无效")
        if value["kind"] == "index-rebuild" and value["hadCache"]:
            raise LocalRecoveryError("索引重建事务不能替换缓存目录")
        if value["kind"] == "cache-metadata" and not value["hadCache"]:
            raise LocalRecoveryError("缓存元数据事务缺少旧缓存目录")
        for key in ("manifestRevisionId", "chatRevisionId", "notesRevisionId"):
            raw_digest = value.get(key)
            if not isinstance(raw_digest, str):
                raise LocalRecoveryError("本机替换事务修订 ID 无效")
            if raw_digest:
                try:
                    validate_digest(raw_digest, key)
                except ProtocolError as error:
                    raise LocalRecoveryError("本机替换事务修订 ID 无效") from error
        if value["kind"] in {"download-commit", "cache-metadata"} and not all(
            value[key] for key in ("manifestRevisionId", "chatRevisionId", "notesRevisionId")
        ):
            raise LocalRecoveryError("缓存替换事务缺少修订 ID")
        return dict(value)

    def _validate_cache_output(
        self,
        cache_root: Path,
        transaction: dict,
        *,
        match_transaction_revisions: bool = True,
    ) -> dict:
        self._require_plain_directory(cache_root, "云端缓存")
        connection_id, device_id, source_type = parse_remote_source_id(transaction["sourceId"])
        if connection_id != transaction["connectionId"]:
            raise LocalRecoveryError("云端缓存与事务连接不一致")
        required_files = {
            "manifest": cache_root / "manifest.json",
            "pointer": cache_root / "pointer.json",
            "notes": cache_root / "notes.json",
            "originMap": cache_root / "origin-map.json",
        }
        if not (cache_root / "raw").is_dir() or (cache_root / "raw").is_symlink():
            raise LocalRecoveryError("云端缓存缺少 raw 目录")
        for label, path in required_files.items():
            if path.is_symlink() or not path.is_file():
                raise LocalRecoveryError(f"云端缓存缺少 {label} 文件")
        try:
            manifest_bytes = required_files["manifest"].read_bytes()
            manifest = json.loads(manifest_bytes.decode("utf-8"))
            pointer = json.loads(required_files["pointer"].read_text(encoding="utf-8"))
            notes_bytes = required_files["notes"].read_bytes()
            origin_map = json.loads(required_files["originMap"].read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise LocalRecoveryError("云端缓存 JSON 无法校验") from error
        if not isinstance(origin_map, dict):
            raise LocalRecoveryError("云端缓存 origin-map.json 无效")
        try:
            validate_current_pointer(pointer, device_id=device_id, source_type=source_type)
            validate_full_manifest(manifest, device_id=device_id, source_type=source_type)
        except (ProtocolError, ValueError) as error:
            raise LocalRecoveryError("云端缓存 manifest 校验失败") from error
        if sha256_bytes(manifest_bytes) != pointer["manifestRevisionId"] or manifest_revision_id(manifest) != pointer["manifestRevisionId"]:
            raise LocalRecoveryError("云端缓存 manifest 散列无效")
        if match_transaction_revisions:
            for key in ("manifestRevisionId", "chatRevisionId", "notesRevisionId"):
                if pointer.get(key) != transaction.get(key):
                    raise LocalRecoveryError(f"云端缓存 {key} 与替换事务不一致")
        if manifest.get("chatRevisionId") != pointer.get("chatRevisionId") or manifest.get("notesRevisionId") != pointer.get("notesRevisionId"):
            raise LocalRecoveryError("云端缓存 manifest 与当前指针不一致")
        notes = manifest["notes"]
        if len(notes_bytes) != int(notes["size"]) or sha256_bytes(notes_bytes) != notes["sha256"]:
            raise LocalRecoveryError("云端缓存备注对象校验失败")
        try:
            self._parse_notes(notes_bytes, device_id, source_type)
        except (ProtocolError, ValueError) as error:
            raise LocalRecoveryError("云端缓存备注内容无效") from error
        raw_root = cache_root / "raw"
        for item in manifest.get("logicalFiles") or []:
            logical_path = str(item["logicalPath"])
            target = raw_root.joinpath(*logical_path.split("/"))
            self._require_confined_path(target, raw_root, "云端缓存会话文件")
            if target.is_symlink() or not target.is_file():
                raise LocalRecoveryError("云端缓存会话文件缺失")
            if target.stat().st_size != int(item["size"]) or sha256_file(target) != item["sha256"]:
                raise LocalRecoveryError("云端缓存会话文件校验失败")
        object_sizes = self._object_sizes(manifest)
        journal_root = cache_root / "journal" / "objects"
        for digest, expected_size in object_sizes.items():
            target = journal_root / digest[:2] / f"{digest}.bin"
            if target.is_symlink() or not target.is_file():
                raise LocalRecoveryError("云端缓存对象缺失")
            if target.stat().st_size != expected_size or sha256_file(target) != digest:
                raise LocalRecoveryError("云端缓存对象校验失败")
        return pointer

    def _transaction_pairs(self, transaction: dict, paths: dict[str, Path | None]) -> list[tuple[str, Path, Path, bool]]:
        pairs: list[tuple[str, Path, Path, bool]] = []
        if transaction["kind"] in {"download-commit", "index-rebuild"}:
            pairs.append(("index", paths["index"], paths["indexBackup"], bool(transaction["hadIndex"])))
        if transaction["kind"] == "download-commit":
            pairs.append(("cache", paths["cache"], paths["cacheBackup"], bool(transaction["hadCache"])))
        elif transaction["kind"] == "cache-metadata":
            pairs.append(("cache", paths["cache"], paths["cacheBackup"], bool(transaction["hadCache"])))
        return pairs

    def _validate_transaction_directory(
        self,
        area: str,
        path: Path,
        transaction: dict,
        *,
        match_transaction_revisions: bool = True,
    ) -> None:
        if area == "index":
            try:
                self._validate_index_output(path)
            except (OSError, RuntimeError, ValueError) as error:
                raise LocalRecoveryError("本机云端索引不完整") from error
        else:
            self._validate_cache_output(
                path,
                transaction,
                match_transaction_revisions=match_transaction_revisions,
            )

    @staticmethod
    def _remove_directory(path: Path) -> None:
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise LocalRecoveryError("待清理路径不是普通目录")
        if path.exists():
            shutil.rmtree(path)
        if path.exists() or path.is_symlink():
            raise OSError("目录删除后仍然存在")

    def _rollback_transaction(self, transaction: dict, paths: dict[str, Path | None], *, require_backups: bool) -> None:
        pairs = self._transaction_pairs(transaction, paths)
        restore_sources: list[tuple[str, Path, Path, bool]] = []
        for area, target, backup, had_old in pairs:
            if target.is_symlink() or backup.is_symlink():
                raise LocalRecoveryError("本机替换目标或备份是符号链接")
            backup_exists = backup.is_dir()
            if had_old:
                if require_backups and not backup_exists:
                    raise LocalRecoveryError("旧版本备份缺失，无法恢复")
                candidate = backup if backup_exists else target
                self._validate_transaction_directory(
                    area,
                    candidate,
                    transaction,
                    match_transaction_revisions=False,
                )
            elif backup_exists or self._path_exists(backup):
                raise LocalRecoveryError("首次安装事务出现了不应存在的旧备份")
            restore_sources.append((area, target, backup, had_old))
        for _area, target, backup, had_old in restore_sources:
            if had_old and backup.is_dir():
                if self._path_exists(target):
                    self._remove_directory(target)
                os.replace(backup, target)
            elif not had_old and self._path_exists(target):
                self._remove_directory(target)
        transaction_file = paths["transactionFile"]
        transaction_file.unlink()

    def _finish_committed_transaction(self, transaction: dict, paths: dict[str, Path | None]) -> None:
        cleanup_failed = False
        for _area, _target, backup, _had_old in self._transaction_pairs(transaction, paths):
            try:
                if self._path_exists(backup):
                    self._remove_directory(backup)
            except (OSError, LocalRecoveryError):
                cleanup_failed = True
        if cleanup_failed:
            self.recovery_warning = "新版本已生效，但旧本机缓存清理失败"
            return
        try:
            paths["transactionFile"].unlink()
        except OSError:
            self.recovery_warning = "新版本已生效，但本机恢复记录清理失败"

    def _recover_one_local_transaction(self, transaction: dict) -> None:
        paths = self._transaction_paths(transaction)
        if transaction["phase"] == "prepared":
            self._rollback_transaction(transaction, paths, require_backups=False)
            return
        try:
            pointer = None
            for area, target, _backup, _had_old in self._transaction_pairs(transaction, paths):
                if area == "cache":
                    pointer = self._validate_cache_output(target, transaction)
                else:
                    self._validate_transaction_directory(area, target, transaction)
        except (OSError, LocalRecoveryError, RuntimeError, ValueError):
            self._rollback_transaction(transaction, paths, require_backups=True)
            return
        if pointer is not None:
            self._remember_downloaded({"connectionId": transaction["connectionId"]}, transaction["sourceId"], pointer)
        self._finish_committed_transaction(transaction, paths)

    def _recover_local_transactions(self) -> None:
        root = self.paths.connections_root
        if not root.exists():
            return
        try:
            if root.is_symlink() or not root.is_dir():
                raise LocalRecoveryError("本机 WebDAV 连接目录无效")
            pending: list[dict] = []
            for connection_root in sorted(root.iterdir(), key=lambda item: item.name.casefold()):
                if connection_root.is_symlink() or not connection_root.is_dir():
                    continue
                try:
                    connection_id = safe_uuid(connection_root.name)
                except ConfigError:
                    continue
                if connection_id != connection_root.name:
                    raise LocalRecoveryError("本机 WebDAV 连接目录 ID 非法")
                transaction_root = connection_root / "transactions"
                if not transaction_root.exists():
                    continue
                if transaction_root.is_symlink() or not transaction_root.is_dir():
                    raise LocalRecoveryError("本机替换事务目录无效")
                for transaction_file in sorted(transaction_root.glob("*.json"), key=lambda item: item.name.casefold()):
                    pending.append(self._read_local_transaction(transaction_file, connection_id))
            for transaction in pending:
                self._recover_one_local_transaction(transaction)
        except (OSError, LocalRecoveryError, RuntimeError, ValueError) as error:
            self.recovery_error = TaskManager._sanitize_error(error)[:2048] or "未知恢复错误"

    def _local_cleanup_path(self, connection_id: str, kind: str, cleanup_id: str) -> Path:
        connection_id = safe_uuid(connection_id)
        cleanup_id = safe_uuid(cleanup_id)
        tasks_root = self.paths.connection_root(connection_id) / "tasks"
        if kind in {"upload", "download"}:
            target = tasks_root / cleanup_id / "staging"
        elif kind == "index-rebuild":
            target = tasks_root / f"rebuild-{cleanup_id}"
        else:
            raise LocalRecoveryError("未知的本机临时目录清理类型")
        self._require_confined_path(target, tasks_root, "待重试临时目录")
        return target

    def _remove_local_cleanup_target(self, connection_id: str, kind: str, cleanup_id: str) -> None:
        target = self._local_cleanup_path(connection_id, kind, cleanup_id)
        self._remove_directory(target)
        if kind not in {"upload", "download"}:
            return
        task_root = target.parent
        tasks_root = self.paths.connection_root(safe_uuid(connection_id)) / "tasks"
        self._require_confined_path(task_root, tasks_root, "任务临时目录")
        if task_root.is_symlink():
            raise LocalRecoveryError("任务临时目录不能是符号链接")
        if task_root.exists():
            if not task_root.is_dir():
                raise LocalRecoveryError("任务临时目录不是普通目录")
            try:
                if not any(task_root.iterdir()):
                    task_root.rmdir()
            except OSError as error:
                raise LocalRecoveryError("空任务临时目录无法删除") from error

    def _remember_local_cleanup(self, settings: dict, kind: str, cleanup_id: str, error: Exception) -> None:
        entry = {
            "kind": kind,
            "cleanupId": safe_uuid(cleanup_id),
            "error": TaskManager._sanitize_error(error),
            "lastAttemptAt": utc_now(),
        }

        def remember(connection: dict) -> None:
            pending = list(connection.get("pendingLocalCleanup") or [])
            pending = [
                item for item in pending
                if not (
                    isinstance(item, dict)
                    and item.get("kind") == entry["kind"]
                    and item.get("cleanupId") == entry["cleanupId"]
                )
            ]
            pending.append(entry)
            connection["pendingLocalCleanup"] = pending[-128:]

        self._update_connection_state(settings, remember)
        self.recovery_warning = "本机临时目录清理失败，将在下次启动重试"

    def _forget_local_cleanup(self, connection_id: str, kind: str, cleanup_id: str) -> None:
        settings = {"connectionId": safe_uuid(connection_id)}
        existing = list(self._connection_state(settings).get("pendingLocalCleanup") or [])
        if not any(
            isinstance(item, dict)
            and item.get("kind") == kind
            and item.get("cleanupId") == cleanup_id
            for item in existing
        ):
            return

        def forget(connection: dict) -> None:
            pending = [
                item for item in list(connection.get("pendingLocalCleanup") or [])
                if not (
                    isinstance(item, dict)
                    and item.get("kind") == kind
                    and item.get("cleanupId") == cleanup_id
                )
            ]
            if pending:
                connection["pendingLocalCleanup"] = pending
            else:
                connection.pop("pendingLocalCleanup", None)

        self._update_connection_state(settings, forget)

    def _cleanup_temporary_directory(
        self,
        settings: dict,
        kind: str,
        cleanup_id: str,
        expected_path: Path,
    ) -> bool:
        connection_id = safe_uuid(str(settings.get("connectionId") or ""))
        cleanup_id = safe_uuid(cleanup_id)
        target = self._local_cleanup_path(connection_id, kind, cleanup_id)
        if target.resolve(strict=False) != Path(expected_path).resolve(strict=False):
            raise LocalRecoveryError("本机临时目录与清理标识不一致")
        try:
            self._remove_local_cleanup_target(connection_id, kind, cleanup_id)
        except (OSError, LocalRecoveryError) as error:
            try:
                self._remember_local_cleanup(settings, kind, cleanup_id, error)
            except (OSError, ConfigError):
                self.recovery_warning = "本机临时目录清理失败，且待重试状态无法保存"
            return False
        self._forget_local_cleanup(connection_id, kind, cleanup_id)
        return True

    def _recover_pending_local_cleanup(self) -> None:
        try:
            state = self._state()
            entries: list[tuple[str, str, str]] = []
            for raw_connection_id, connection in dict(state.get("connections") or {}).items():
                connection_id = safe_uuid(raw_connection_id)
                for item in list(dict(connection or {}).get("pendingLocalCleanup") or []):
                    if not isinstance(item, dict):
                        raise LocalRecoveryError("本机临时目录清理记录无效")
                    kind = str(item.get("kind") or "")
                    cleanup_id = safe_uuid(str(item.get("cleanupId") or ""))
                    self._local_cleanup_path(connection_id, kind, cleanup_id)
                    entries.append((connection_id, kind, cleanup_id))
            for connection_id, kind, cleanup_id in entries:
                try:
                    self._remove_local_cleanup_target(connection_id, kind, cleanup_id)
                except (OSError, LocalRecoveryError) as error:
                    try:
                        self._remember_local_cleanup(
                            {"connectionId": connection_id},
                            kind,
                            cleanup_id,
                            error,
                        )
                    except (OSError, ConfigError) as state_error:
                        self.recovery_warning = (
                            "本机临时目录清理失败，且待重试状态无法保存："
                            + TaskManager._sanitize_error(state_error)[:1024]
                        )
                    else:
                        self.recovery_warning = "本机临时目录清理失败，将在下次启动重试"
                    continue
                self._forget_local_cleanup(connection_id, kind, cleanup_id)
        except (OSError, ConfigError, LocalRecoveryError, ValueError) as error:
            if not self.recovery_warning:
                self.recovery_warning = "本机临时目录清理记录无法恢复：" + TaskManager._sanitize_error(error)[:1024]

    def _remote_staging_path(self, settings: dict, source_type: str, task_id: str) -> str:
        connection_id = safe_uuid(str(settings.get("connectionId") or ""))
        if source_type not in LOCAL_SOURCE_TYPES:
            raise LocalRecoveryError("远端暂存清理来源类型无效")
        task_id = safe_uuid(task_id)
        if connection_id != str(settings.get("connectionId") or ""):
            raise LocalRecoveryError("远端暂存清理连接 ID 无效")
        return self._join(
            self._source_base(settings, str(self.device["deviceId"]), source_type),
            "staging",
            task_id,
        )

    def _remember_remote_staging_cleanup(
        self,
        settings: dict,
        source_type: str,
        task_id: str,
        error: object,
    ) -> None:
        connection_id = safe_uuid(str(settings.get("connectionId") or ""))
        task_id = safe_uuid(task_id)
        if source_type not in LOCAL_SOURCE_TYPES:
            raise LocalRecoveryError("远端暂存清理来源类型无效")
        entry = {
            "connectionId": connection_id,
            "sourceType": source_type,
            "taskId": task_id,
            "error": TaskManager._sanitize_error(error)[:2048] or type(error).__name__,
        }

        def remember(connection: dict) -> None:
            pending = [
                item for item in list(connection.get("pendingRemoteStagingCleanup") or [])
                if not (
                    isinstance(item, dict)
                    and item.get("sourceType") == source_type
                    and item.get("taskId") == task_id
                )
            ]
            pending.append(entry)
            connection["pendingRemoteStagingCleanup"] = pending[-128:]

        self._update_connection_state(settings, remember)

    def _forget_remote_staging_cleanup(self, settings: dict, source_type: str, task_id: str) -> None:
        task_id = safe_uuid(task_id)
        existing = list(self._connection_state(settings).get("pendingRemoteStagingCleanup") or [])
        if not any(
            isinstance(item, dict)
            and item.get("sourceType") == source_type
            and item.get("taskId") == task_id
            for item in existing
        ):
            return

        def forget(connection: dict) -> None:
            pending = [
                item for item in list(connection.get("pendingRemoteStagingCleanup") or [])
                if not (
                    isinstance(item, dict)
                    and item.get("sourceType") == source_type
                    and item.get("taskId") == task_id
                )
            ]
            if pending:
                connection["pendingRemoteStagingCleanup"] = pending
            else:
                connection.pop("pendingRemoteStagingCleanup", None)

        self._update_connection_state(settings, forget)

    def _cleanup_remote_task_staging(
        self,
        client: object,
        settings: dict,
        source_type: str,
        task_id: str,
    ) -> bool:
        target = self._remote_staging_path(settings, source_type, task_id)
        try:
            client.delete(target, allow_missing=True)
        except Exception as error:
            self._remember_remote_staging_cleanup(settings, source_type, task_id, error)
            return False
        self._forget_remote_staging_cleanup(settings, source_type, task_id)
        return True

    def _retry_remote_staging_cleanup(
        self,
        client: object,
        settings: dict,
        source_types: set[str] | None = None,
    ) -> list[dict]:
        connection_id = safe_uuid(str(settings.get("connectionId") or ""))
        pending = list(self._connection_state(settings).get("pendingRemoteStagingCleanup") or [])
        failed: list[dict] = []
        for raw_entry in pending:
            if not isinstance(raw_entry, dict) or set(raw_entry) != {
                "connectionId", "sourceType", "taskId", "error"
            }:
                self.recovery_warning = "远端暂存清理记录无效，未执行远端删除"
                continue
            try:
                entry_connection = safe_uuid(str(raw_entry.get("connectionId") or ""))
                source_type = str(raw_entry.get("sourceType") or "")
                task_id = safe_uuid(str(raw_entry.get("taskId") or ""))
                if entry_connection != connection_id or source_type not in LOCAL_SOURCE_TYPES:
                    raise LocalRecoveryError("远端暂存清理记录不属于当前连接")
                self._remote_staging_path(settings, source_type, task_id)
            except (ConfigError, LocalRecoveryError, ValueError):
                self.recovery_warning = "远端暂存清理记录无效，未执行远端删除"
                continue
            if source_types is not None and source_type not in source_types:
                continue
            if not self._cleanup_remote_task_staging(client, settings, source_type, task_id):
                updated_entry = next(
                    (
                        item for item in self._connection_state(settings).get(
                            "pendingRemoteStagingCleanup", []
                        )
                        if isinstance(item, dict)
                        and item.get("sourceType") == source_type
                        and item.get("taskId") == task_id
                    ),
                    None,
                )
                if updated_entry is None:
                    raise LocalRecoveryError("远端暂存清理失败状态未保存")
                failed.append(dict(updated_entry))
        return failed

    def _remote_commit_lock_paths(self, settings: dict, source_type: str) -> tuple[str, str]:
        if source_type not in LOCAL_SOURCE_TYPES:
            raise LocalRecoveryError("远端提交锁来源类型无效")
        source_base = self._source_base(settings, str(self.device["deviceId"]), source_type)
        lock_root = self._join(source_base, "locks", "commit")
        return lock_root, self._join(lock_root, "owner.json")

    @staticmethod
    def _parse_utc_timestamp(value: object) -> datetime:
        try:
            parsed = datetime.fromisoformat(str(value or "").replace("Z", "+00:00"))
        except ValueError as error:
            raise ProtocolError("远端提交锁租约时间无效") from error
        if parsed.tzinfo is None:
            raise ProtocolError("远端提交锁租约缺少时区")
        return parsed.astimezone(timezone.utc)

    def _validate_remote_lock_owner(self, payload: object, source_type: str) -> dict:
        if not isinstance(payload, dict) or set(payload) != {
            "taskId", "lockToken", "deviceId", "sourceType", "leaseUntil", "updatedAt"
        }:
            raise ProtocolError("远端提交锁 owner.json 字段无效")
        owner = dict(payload)
        owner["taskId"] = safe_uuid(str(owner.get("taskId") or ""))
        owner["lockToken"] = safe_uuid(str(owner.get("lockToken") or ""))
        owner["deviceId"] = safe_uuid(str(owner.get("deviceId") or ""))
        if owner["deviceId"] != safe_uuid(str(self.device["deviceId"])):
            raise ProtocolError("远端提交锁不属于当前设备")
        if owner.get("sourceType") != source_type:
            raise ProtocolError("远端提交锁不属于当前来源")
        self._parse_utc_timestamp(owner.get("leaseUntil"))
        self._parse_utc_timestamp(owner.get("updatedAt"))
        return owner

    def _read_remote_lock_owner(self, client: object, owner_path: str, source_type: str) -> tuple[dict, bytes]:
        raw, _etag = client.get_bytes(owner_path, max_bytes=REMOTE_LOCK_OWNER_LIMIT)
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ProtocolError("远端提交锁 owner.json 无效") from error
        return self._validate_remote_lock_owner(payload, source_type), raw

    @staticmethod
    def _new_remote_lock_owner(task_id: str, lock_token: str, device_id: str, source_type: str) -> dict:
        now = datetime.now(timezone.utc)
        return {
            "taskId": safe_uuid(task_id),
            "lockToken": safe_uuid(lock_token),
            "deviceId": safe_uuid(device_id),
            "sourceType": source_type,
            "leaseUntil": (now + timedelta(seconds=REMOTE_LOCK_LEASE_SECONDS)).isoformat(
                timespec="microseconds"
            ).replace("+00:00", "Z"),
            "updatedAt": now.isoformat(timespec="microseconds").replace("+00:00", "Z"),
        }

    def _remember_remote_lock_cleanup(
        self,
        settings: dict,
        source_type: str,
        task_id: str,
        lock_token: str,
        error: object,
    ) -> None:
        connection_id = safe_uuid(str(settings.get("connectionId") or ""))
        task_id = safe_uuid(task_id)
        lock_token = safe_uuid(lock_token)
        if source_type not in LOCAL_SOURCE_TYPES:
            raise LocalRecoveryError("远端提交锁清理来源类型无效")
        entry = {
            "connectionId": connection_id,
            "sourceType": source_type,
            "taskId": task_id,
            "lockToken": lock_token,
            "error": TaskManager._sanitize_error(error)[:2048] or type(error).__name__,
        }

        def remember(connection: dict) -> None:
            pending = [
                item for item in list(connection.get("pendingRemoteLockCleanup") or [])
                if not (
                    isinstance(item, dict)
                    and item.get("sourceType") == source_type
                    and item.get("taskId") == task_id
                )
            ]
            pending.append(entry)
            connection["pendingRemoteLockCleanup"] = pending[-128:]

        self._update_connection_state(settings, remember)

    def _forget_remote_lock_cleanup(self, settings: dict, source_type: str, task_id: str) -> None:
        task_id = safe_uuid(task_id)

        def forget(connection: dict) -> None:
            pending = [
                item for item in list(connection.get("pendingRemoteLockCleanup") or [])
                if not (
                    isinstance(item, dict)
                    and item.get("sourceType") == source_type
                    and item.get("taskId") == task_id
                )
            ]
            if pending:
                connection["pendingRemoteLockCleanup"] = pending
            else:
                connection.pop("pendingRemoteLockCleanup", None)

        self._update_connection_state(settings, forget)

    def _acquire_remote_commit_lock(
        self,
        client: object,
        settings: dict,
        source_type: str,
        task_id: str,
    ) -> dict:
        task_id = safe_uuid(task_id)
        lock_token = str(uuid.uuid4())
        source_base = self._source_base(settings, str(self.device["deviceId"]), source_type)
        client.mkcol(self._join(source_base, "locks"), allow_exists=True)
        lock_root, owner_path = self._remote_commit_lock_paths(settings, source_type)
        try:
            client.mkcol(lock_root, allow_exists=False)
        except WebDAVError as error:
            if error.status not in {405, 409}:
                raise
            try:
                first_owner, first_bytes = self._read_remote_lock_owner(client, owner_path, source_type)
            except WebDAVError as owner_error:
                if owner_error.status != 404:
                    raise
                time.sleep(0.05)
                try:
                    first_owner, first_bytes = self._read_remote_lock_owner(
                        client, owner_path, source_type
                    )
                except WebDAVError as repeated_owner_error:
                    if repeated_owner_error.status == 404:
                        raise WebDAVError("远端提交锁正在初始化，来源正在由其他任务提交") from error
                    raise
            if self._parse_utc_timestamp(first_owner["leaseUntil"]) > datetime.now(timezone.utc):
                raise WebDAVError("远端来源正在由其他任务提交") from error
            time.sleep(0.05)
            second_owner, second_bytes = self._read_remote_lock_owner(client, owner_path, source_type)
            if (
                second_bytes != first_bytes
                or second_owner["lockToken"] != first_owner["lockToken"]
                or self._parse_utc_timestamp(second_owner["leaseUntil"]) > datetime.now(timezone.utc)
            ):
                raise WebDAVError("远端提交锁已续租，来源正在由其他任务提交") from error
            client.delete(lock_root, allow_missing=False)
            try:
                client.mkcol(lock_root, allow_exists=False)
            except WebDAVError as competition_error:
                if competition_error.status in {405, 409}:
                    raise WebDAVError("远端提交锁竞争失败，来源正在由其他任务提交") from competition_error
                raise
            self._forget_remote_lock_cleanup(
                settings, source_type, str(first_owner["taskId"])
            )

        owner = self._new_remote_lock_owner(
            task_id,
            lock_token,
            str(self.device["deviceId"]),
            source_type,
        )
        owner_bytes = canonical_json_bytes(owner)
        try:
            client.put_bytes(owner_path, owner_bytes, content_type="application/json")
            checked, checked_bytes = self._read_remote_lock_owner(client, owner_path, source_type)
            if checked_bytes != owner_bytes or checked["lockToken"] != lock_token:
                raise ProtocolError("远端提交锁 owner.json 写后校验失败")
            self._remember_remote_lock_cleanup(
                settings,
                source_type,
                task_id,
                lock_token,
                RuntimeError("远端提交锁由当前任务持有"),
            )
        except Exception as acquisition_error:
            try:
                client.delete(lock_root, allow_missing=True)
            except Exception as cleanup_error:
                try:
                    self._remember_remote_lock_cleanup(
                        settings, source_type, task_id, lock_token, cleanup_error
                    )
                except Exception as state_error:
                    self.recovery_warning = (
                        "远端提交锁获取失败后的清理状态无法保存："
                        + TaskManager._sanitize_error(state_error)[:1024]
                    )
            raise
        return {
            "sourceType": source_type,
            "taskId": task_id,
            "lockToken": lock_token,
            "lockRoot": lock_root,
            "ownerPath": owner_path,
            "renewAfter": time.monotonic() + REMOTE_LOCK_RENEW_SECONDS,
        }

    def _maintain_remote_commit_lock(
        self,
        client: object,
        settings: dict,
        lock_state: dict,
        *,
        force: bool = False,
    ) -> None:
        source_type = str(lock_state["sourceType"])
        try:
            owner, _raw = self._read_remote_lock_owner(
                client, str(lock_state["ownerPath"]), source_type
            )
        except WebDAVError as error:
            if error.status == 404:
                raise ProtocolError("远端提交锁已丢失") from error
            raise
        if owner["lockToken"] != lock_state["lockToken"] or owner["taskId"] != lock_state["taskId"]:
            raise ProtocolError("远端提交锁令牌已变化或锁已丢失")
        if self._parse_utc_timestamp(owner["leaseUntil"]) <= datetime.now(timezone.utc):
            raise ProtocolError("远端提交锁租约已失效")
        if not force and time.monotonic() < float(lock_state["renewAfter"]):
            return
        renewed = self._new_remote_lock_owner(
            str(lock_state["taskId"]),
            str(lock_state["lockToken"]),
            str(self.device["deviceId"]),
            source_type,
        )
        renewed_bytes = canonical_json_bytes(renewed)
        client.put_bytes(str(lock_state["ownerPath"]), renewed_bytes, content_type="application/json")
        checked, checked_bytes = self._read_remote_lock_owner(
            client, str(lock_state["ownerPath"]), source_type
        )
        if checked_bytes != renewed_bytes or checked["lockToken"] != lock_state["lockToken"]:
            raise ProtocolError("远端提交锁续租写后校验失败")
        lock_state["renewAfter"] = time.monotonic() + REMOTE_LOCK_RENEW_SECONDS

    def _release_remote_commit_lock(
        self,
        client: object,
        settings: dict,
        lock_state: dict,
    ) -> bool:
        source_type = str(lock_state["sourceType"])
        task_id = safe_uuid(str(lock_state["taskId"]))
        try:
            owner, _raw = self._read_remote_lock_owner(
                client, str(lock_state["ownerPath"]), source_type
            )
        except WebDAVError as error:
            if error.status == 404:
                self._remember_remote_lock_cleanup(
                    settings, source_type, task_id, str(lock_state["lockToken"]), error
                )
                return False
            self._remember_remote_lock_cleanup(
                settings, source_type, task_id, str(lock_state["lockToken"]), error
            )
            return False
        except Exception as error:
            self._remember_remote_lock_cleanup(
                settings, source_type, task_id, str(lock_state["lockToken"]), error
            )
            return False
        if owner["lockToken"] != lock_state["lockToken"] or owner["taskId"] != task_id:
            self._forget_remote_lock_cleanup(settings, source_type, task_id)
            return False
        try:
            client.delete(str(lock_state["lockRoot"]), allow_missing=True)
        except Exception as error:
            self._remember_remote_lock_cleanup(
                settings, source_type, task_id, str(lock_state["lockToken"]), error
            )
            return False
        self._forget_remote_lock_cleanup(settings, source_type, task_id)
        return True

    def _retry_remote_lock_cleanup(
        self,
        client: object,
        settings: dict,
        source_types: set[str] | None = None,
    ) -> list[dict]:
        connection_id = safe_uuid(str(settings.get("connectionId") or ""))
        pending = list(self._connection_state(settings).get("pendingRemoteLockCleanup") or [])
        failed: list[dict] = []
        for raw_entry in pending:
            if not isinstance(raw_entry, dict) or set(raw_entry) != {
                "connectionId", "sourceType", "taskId", "lockToken", "error"
            }:
                self.recovery_warning = "远端提交锁清理记录无效，未执行远端删除"
                continue
            try:
                entry_connection = safe_uuid(str(raw_entry.get("connectionId") or ""))
                source_type = str(raw_entry.get("sourceType") or "")
                task_id = safe_uuid(str(raw_entry.get("taskId") or ""))
                lock_token = safe_uuid(str(raw_entry.get("lockToken") or ""))
                if entry_connection != connection_id or source_type not in LOCAL_SOURCE_TYPES:
                    raise LocalRecoveryError("远端提交锁清理记录不属于当前连接")
            except (ConfigError, LocalRecoveryError, ValueError):
                self.recovery_warning = "远端提交锁清理记录无效，未执行远端删除"
                continue
            if source_types is not None and source_type not in source_types:
                continue
            lock_root, owner_path = self._remote_commit_lock_paths(settings, source_type)
            lock_state = {
                "sourceType": source_type,
                "taskId": task_id,
                "lockToken": lock_token,
                "lockRoot": lock_root,
                "ownerPath": owner_path,
            }
            if not self._release_remote_commit_lock(client, settings, lock_state):
                current = next(
                    (
                        item for item in self._connection_state(settings).get(
                            "pendingRemoteLockCleanup", []
                        )
                        if isinstance(item, dict)
                        and item.get("sourceType") == source_type
                        and item.get("taskId") == task_id
                    ),
                    None,
                )
                if current is not None:
                    failed.append(dict(current))
        return failed

    def _recover_interrupted_task_staging(self) -> None:
        connections_root = self.paths.connections_root
        if not connections_root.exists():
            return
        try:
            if connections_root.is_symlink() or not connections_root.is_dir():
                raise LocalRecoveryError("本机 WebDAV 连接目录无效")
            for connection_root in sorted(connections_root.iterdir(), key=lambda item: item.name.casefold()):
                try:
                    connection_id = safe_uuid(connection_root.name)
                except ConfigError:
                    continue
                if connection_root.name != connection_id or connection_root.is_symlink() or not connection_root.is_dir():
                    self.recovery_warning = "发现无效的本机 WebDAV 连接任务目录，未执行清理"
                    continue
                tasks_root = connection_root / "tasks"
                if not self._path_exists(tasks_root):
                    continue
                if tasks_root.is_symlink() or not tasks_root.is_dir():
                    self.recovery_warning = "发现无效的本机 WebDAV 任务目录，未执行清理"
                    continue
                for task_file in sorted(tasks_root.glob("*.json"), key=lambda item: item.name.casefold()):
                    try:
                        task_id = safe_uuid(task_file.stem)
                        if task_file.stem != task_id or task_file.is_symlink() or not task_file.is_file():
                            raise LocalRecoveryError("任务文件名或类型无效")
                        if task_file.stat().st_size > LOCAL_TASK_STATE_MAX_BYTES:
                            raise LocalRecoveryError("任务状态文件过大")
                        task = json.loads(task_file.read_text(encoding="utf-8"))
                        if not isinstance(task, dict):
                            raise LocalRecoveryError("任务状态格式无效")
                        if str(task.get("taskId") or "") != task_id:
                            raise LocalRecoveryError("任务 ID 与文件名不一致")
                        action = str(task.get("action") or "")
                        source_id = str(task.get("sourceId") or "")
                        status = str(task.get("status") or "")
                        interrupted = status in {"running", "cancelling"}
                        interrupted_error = status == "error" and task.get("stage") == "传输已中断"
                        if not interrupted and not interrupted_error:
                            continue
                        target = self._local_cleanup_path(connection_id, action, task_id)
                        if interrupted_error and not self._path_exists(target):
                            continue
                        task_warnings: list[str] = []
                        if action == "upload":
                            if source_id not in LOCAL_SOURCE_TYPES:
                                raise LocalRecoveryError("上传任务来源无效")
                            try:
                                self._remember_remote_staging_cleanup(
                                    {"connectionId": connection_id},
                                    source_id,
                                    task_id,
                                    RuntimeError("上次服务器进程结束，远端暂存清理待手动重试"),
                                )
                            except (OSError, ConfigError, LocalRecoveryError, ValueError) as error:
                                task_warnings.append(
                                    "远端暂存待清理状态无法保存："
                                    + TaskManager._sanitize_error(error)[:1024]
                                )
                        elif action == "download":
                            source_connection, _device_id, _source_type = parse_remote_source_id(source_id)
                            if source_connection != connection_id:
                                raise LocalRecoveryError("下载任务来源不属于所在连接")
                        else:
                            raise LocalRecoveryError("任务类型无效")
                        try:
                            local_cleanup_ok = self._cleanup_temporary_directory(
                                {"connectionId": connection_id},
                                action,
                                task_id,
                                target,
                            )
                            if not local_cleanup_ok and self.recovery_warning:
                                task_warnings.append(self.recovery_warning)
                        except (OSError, ConfigError, LocalRecoveryError, ValueError) as error:
                            task_warnings.append(
                                "本机中断任务暂存清理失败："
                                + TaskManager._sanitize_error(error)[:1024]
                            )
                        if task_warnings:
                            self.recovery_warning = "；".join(dict.fromkeys(task_warnings))[:2048]
                    except (OSError, UnicodeError, json.JSONDecodeError, ConfigError, LocalRecoveryError, ValueError):
                        self.recovery_warning = "发现无效或无法清理的中断任务暂存，未触及任务目录之外的数据"
                        continue
        except (OSError, LocalRecoveryError) as error:
            self.recovery_warning = "中断任务暂存恢复失败：" + TaskManager._sanitize_error(error)[:1024]

    def _commit_local_replacement(
        self,
        settings: dict,
        source_id: str,
        *,
        kind: str,
        index_staging: Path | None = None,
        cache_staging: Path | None = None,
        pointer: dict | None = None,
    ) -> None:
        self._require_recovery_ready()
        connection_id, _device_id, _source_type = parse_remote_source_id(source_id)
        if connection_id != safe_uuid(str(settings.get("connectionId") or "")):
            raise ValueError("替换来源不属于当前连接")
        expects_index = kind in {"download-commit", "index-rebuild"}
        expects_cache = kind in {"download-commit", "cache-metadata"}
        if (
            kind not in LOCAL_TRANSACTION_KINDS
            or expects_index != (index_staging is not None)
            or expects_cache != (cache_staging is not None)
        ):
            raise ValueError("本机替换事务参数无效")
        if expects_cache and pointer is None:
            raise ValueError("缓存替换缺少当前指针")
        transaction_id = str(uuid.uuid4())
        index_root = self._index_root(source_id)
        cache_root = self._remote_source_cache_root(settings, parse_remote_source_id(source_id)[1], parse_remote_source_id(source_id)[2])
        transaction = {
            "version": LOCAL_TRANSACTION_VERSION,
            "transactionId": transaction_id,
            "connectionId": connection_id,
            "sourceId": source_id,
            "kind": kind,
            "phase": "prepared",
            "hadIndex": bool(expects_index and self._path_exists(index_root)),
            "hadCache": bool(expects_cache and self._path_exists(cache_root)),
            "manifestRevisionId": str((pointer or {}).get("manifestRevisionId") or ""),
            "chatRevisionId": str((pointer or {}).get("chatRevisionId") or ""),
            "notesRevisionId": str((pointer or {}).get("notesRevisionId") or ""),
        }
        paths = self._transaction_paths(transaction)
        connection_root = paths["connectionRoot"]
        if index_staging is not None:
            self._require_confined_path(index_staging, connection_root, "待安装索引")
            self._require_plain_directory(index_staging, "待安装索引")
            self._validate_transaction_directory("index", index_staging, transaction)
        if cache_staging is not None:
            self._require_confined_path(cache_staging, connection_root, "待安装缓存")
            self._require_plain_directory(cache_staging, "待安装缓存")
            self._validate_cache_output(cache_staging, transaction)
        for area, target, backup, had_old in self._transaction_pairs(transaction, paths):
            if self._path_exists(backup):
                raise LocalRecoveryError("本机替换备份目录已存在")
            if self._path_exists(target):
                if target.is_symlink() or not target.is_dir():
                    raise LocalRecoveryError("本机替换目标不是普通目录")
                if not had_old:
                    raise LocalRecoveryError("本机替换目标状态发生变化")
                self._validate_transaction_directory(
                    area,
                    target,
                    transaction,
                    match_transaction_revisions=False,
                )
            target.parent.mkdir(parents=True, exist_ok=True)
        paths["transactionRoot"].mkdir(parents=True, exist_ok=True)
        write_json_atomic(paths["transactionFile"], transaction)
        try:
            for area, target, backup, had_old in self._transaction_pairs(transaction, paths):
                if had_old:
                    os.replace(target, backup)
                staging = index_staging if area == "index" else cache_staging
                os.replace(staging, target)
            committed_pointer = None
            for area, target, _backup, _had_old in self._transaction_pairs(transaction, paths):
                if area == "cache":
                    committed_pointer = self._validate_cache_output(target, transaction)
                else:
                    self._validate_transaction_directory(area, target, transaction)
            transaction["phase"] = "commit-ready"
            write_json_atomic(paths["transactionFile"], transaction)
            if committed_pointer is not None:
                self._remember_downloaded(settings, source_id, committed_pointer)
            self._finish_committed_transaction(transaction, paths)
        except Exception as error:
            try:
                self._recover_one_local_transaction(self._read_local_transaction(paths["transactionFile"], connection_id))
            except Exception as recovery_error:
                self.recovery_error = TaskManager._sanitize_error(recovery_error)[:2048] or "未知恢复错误"
                raise LocalRecoveryError(f"本机目录替换失败且无法恢复：{self.recovery_error}") from error
            raise

    def _new_task_manager(self) -> TaskManager:
        try:
            settings = load_raw_settings(self.paths)
            connection_id = str(settings.get("connectionId") or "")
            if connection_id:
                root = self.paths.connection_root(connection_id) / "tasks"
            else:
                root = self.paths.webdav_root / "tasks"
        except ConfigError:
            root = self.paths.webdav_root / "tasks"
        return TaskManager(root)

    def _settings(self, *, require_enabled: bool = False) -> dict:
        self._require_identity()
        settings = load_raw_settings(self.paths)
        if not settings:
            raise ConfigError("WebDAV 尚未配置")
        if require_enabled and not settings.get("enabled"):
            raise ConfigError("WebDAV 已停用")
        safe_uuid(str(settings.get("connectionId") or ""))
        return settings

    def _client(self, settings: dict | None = None) -> object:
        settings = settings or self._settings(require_enabled=True)
        if self._client_factory:
            return self._client_factory(settings)
        password = self._password_loader(settings)
        return WebDAVClient(
            str(settings.get("baseUrl") or ""),
            str(settings.get("username") or ""),
            password,
            allow_insecure_private_http=bool(settings.get("allowInsecurePrivateHttp")),
        )

    def get_settings(self) -> dict:
        public = load_public_settings(self.paths)
        cache_warnings: list[dict] = []
        public.update(
            {
                "ok": not bool(self.identity_error),
                "identityError": self.identity_error,
                "recoveryError": self.recovery_error,
                "warning": self.recovery_warning,
                "deviceId": str(self.device.get("deviceId") or ""),
                "cache": self.cache_entries(warnings=cache_warnings),
                "cacheWarnings": cache_warnings,
                "task": self.task_state(),
            }
        )
        state = self._state()
        last_check = dict(state.get("lastCheck", {}) or {})
        fingerprint = self._connection_fingerprint(public)
        public["lastCheck"] = last_check if last_check.get("connectionFingerprint") == fingerprint else {}
        return public

    def save_settings(self, payload: dict) -> dict:
        self._require_identity()
        with self._lock:
            self._require_recovery_ready()
            self._require_idle_task()
            old_settings = load_raw_settings(self.paths)
            old_connection = str(old_settings.get("connectionId") or "")
            kwargs = {"protect": self._password_protector} if self._password_protector else {}
            settings = save_settings(self.paths, payload, **kwargs)
            new_connection = str(settings["connectionId"])
            self.paths.connection_root(new_connection).mkdir(parents=True, exist_ok=True)
            if new_connection != old_connection:
                self._task_manager = self._new_task_manager()
                self._pointer_cache.clear()
                fingerprint = self._connection_fingerprint(settings)

                def invalidate_old_check(state: dict) -> None:
                    last_check = dict(state.get("lastCheck") or {})
                    if last_check.get("connectionFingerprint") != fingerprint:
                        state["lastCheck"] = {}

                self._update_state(invalidate_old_check)
            old_cleanup = {"ok": True, "cleared": [], "failed": [], "cache": []}
            if (
                old_connection
                and new_connection != old_connection
                and bool(payload.get("clearOldConnectionCache"))
            ):
                old_source_ids, discovery_failures = self._physical_cache_source_ids(old_settings, strict=True)
                old_cleanup = self._clear_cache_for_settings(
                    old_settings,
                    old_source_ids,
                    discovery_failures=discovery_failures,
                )
                if old_cleanup["ok"]:
                    try:
                        old_root = self.paths.connection_root(old_connection)
                        if old_root.exists() and self._connection_root_has_only_known_entries(old_root):
                            shutil.rmtree(old_root)
                        if old_root.exists() or old_root.is_symlink():
                            if self._connection_root_has_only_known_entries(old_root):
                                raise OSError("旧连接目录删除后仍然存在")
                    except (OSError, LocalRecoveryError) as error:
                        old_cleanup["ok"] = False
                        old_cleanup["failed"].append(
                            {
                                "sourceId": old_connection,
                                "area": "cache",
                                "path": str(old_root),
                                "reason": TaskManager._sanitize_error(error),
                            }
                        )
            self._status_cache.clear()
            result = self.get_settings()
            connection_changed = bool(old_connection and old_connection != new_connection)
            result["connectionChanged"] = connection_changed
            result["oldConnectionId"] = old_connection if result["connectionChanged"] else ""
            if connection_changed and bool(payload.get("clearOldConnectionCache")):
                result["oldCacheCleanupOk"] = bool(old_cleanup["ok"])
                if not old_cleanup["ok"]:
                    result["warning"] = "设置已保存，但部分旧连接本机缓存清理失败"
                    result["failed"] = old_cleanup["failed"]
            return result

    def disable(self) -> dict:
        with self._lock:
            self._require_recovery_ready()
            self._require_idle_task()
            settings = self._settings()
            settings["enabled"] = False
            write_json_atomic(self.paths.settings_file, settings)
            self._status_cache.clear()
            return self.get_settings()

    def _require_idle_task(self) -> None:
        current = self.task_state()
        if current.get("status") in {"running", "cancelling"}:
            raise TaskBusyError(current)
        if self._image_sync_thread is not None and self._image_sync_thread.is_alive():
            raise TaskBusyError(
                {
                    "taskId": "image-sidecar",
                    "action": "image-upload",
                    "sourceId": self._image_sync_source,
                    "stage": "同步图片",
                    "status": "running",
                }
            )

    def invalidate_source_status(self, source_id: str) -> None:
        with self._lock:
            self._status_cache.pop(str(source_id or ""), None)

    def _state(self) -> dict:
        try:
            state = read_json(self.paths.state_file, {})
        except ConfigError:
            state = {}
        if not state:
            state = {"version": 1, "connections": {}, "pendingProbes": [], "lastCheck": {}}
        state.setdefault("connections", {})
        state.setdefault("pendingProbes", [])
        state.setdefault("lastCheck", {})
        return state

    def _update_state(self, updater: Callable[[dict], None]) -> dict:
        with self._lock:
            state = self._state()
            updater(state)
            write_json_atomic(self.paths.state_file, state)
            return state

    def _connection_state(self, settings: dict) -> dict:
        state = self._state()
        connection_id = str(settings["connectionId"])
        return dict(state.get("connections", {}).get(connection_id) or {})

    def _update_connection_state(self, settings: dict, updater: Callable[[dict], None]) -> None:
        connection_id = str(settings["connectionId"])

        def update(state: dict) -> None:
            connections = state.setdefault("connections", {})
            connection = connections.setdefault(connection_id, {})
            updater(connection)

        self._update_state(update)

    def _temporary_settings(self, payload: dict) -> dict:
        existing = load_raw_settings(self.paths)
        allow_http = bool(payload.get("allowInsecurePrivateHttp", False))
        base_url = validate_webdav_url(str(payload.get("baseUrl") or ""), allow_http)
        username = str(payload.get("username") or "").strip()
        remote_root = validate_remote_root(str(payload.get("remoteRoot") or ""))
        password = str(payload.get("password") or "")
        unchanged = all(
            str(existing.get(key) or "") == value
            for key, value in {"baseUrl": base_url, "username": username, "remoteRoot": remote_root}.items()
        )
        if not password:
            if not unchanged:
                raise ConfigError("连接字段变化后，检查连通性也必须重新输入密码")
            password = self._password_loader(existing)
        if not username or not password:
            raise ConfigError("用户名和密码不能为空")
        temporary = {
            "baseUrl": base_url,
            "username": username,
            "remoteRoot": remote_root,
            "allowInsecurePrivateHttp": allow_http,
            "_clearPassword": password,
        }
        if unchanged and existing.get("connectionId"):
            temporary["connectionId"] = safe_uuid(str(existing["connectionId"]))
        return temporary

    @staticmethod
    def _connection_fingerprint(settings: dict) -> str:
        material = {
            "baseUrl": str(settings.get("baseUrl") or ""),
            "username": str(settings.get("username") or ""),
            "remoteRoot": str(settings.get("remoteRoot") or ""),
        }
        return hashlib.sha256(canonical_json_bytes(material)).hexdigest()

    def _require_safe_commit_mode(self, settings: dict) -> str:
        last_check = dict(self._state().get("lastCheck") or {})
        fingerprint = self._connection_fingerprint(settings)
        capabilities = dict(last_check.get("capabilities") or {})
        mode = str(last_check.get("commitMode") or "")
        if (
            last_check.get("connectionFingerprint") != fingerprint
            or not last_check.get("ok")
            or mode not in {"standard", "move-create", "remote-lock"}
            or self._commit_mode_for_capabilities(capabilities) != mode
        ):
            raise ConfigError("当前 WebDAV 连接尚无匹配的安全提交模式，请先检查连通性")
        return mode

    def _temporary_client(self, settings: dict) -> object:
        if self._client_factory:
            material = dict(settings)
            material["protectedPassword"] = settings.get("_clearPassword", "")
            return self._client_factory(material)
        return WebDAVClient(
            settings["baseUrl"],
            settings["username"],
            settings["_clearPassword"],
            allow_insecure_private_http=bool(settings.get("allowInsecurePrivateHttp")),
        )

    @staticmethod
    def _join(*parts: object) -> str:
        return "/".join(str(part).strip("/") for part in parts if str(part).strip("/"))

    def _ensure_collections(self, client: object, *parts: object) -> None:
        current: list[str] = []
        for part in parts:
            for segment in str(part).strip("/").split("/"):
                if not segment:
                    continue
                current.append(segment)
                client.mkcol("/".join(current), allow_exists=True)

    @staticmethod
    def _commit_mode_for_capabilities(capabilities: dict) -> str:
        if not capabilities.get("moveNoOverwrite"):
            return "blocked"
        if (
            capabilities.get("etag")
            and capabilities.get("ifMatchRejectsInvalid")
            and capabilities.get("ifMatchAllowsValid")
        ):
            return "standard" if capabilities.get("ifNoneMatch") else "move-create"
        if capabilities.get("mkcolExisting"):
            return "remote-lock"
        return "blocked"

    def _remember_probe_cleanup(self, settings: dict, probe_id: str, error: object) -> None:
        probe_id = safe_uuid(probe_id)
        fingerprint = self._connection_fingerprint(settings)
        entry = {
            "connectionFingerprint": fingerprint,
            "probeId": probe_id,
            "error": TaskManager._sanitize_error(error)[:2048] or type(error).__name__,
        }

        def remember(state: dict) -> None:
            pending = [
                item for item in list(state.get("pendingProbes") or [])
                if not (
                    isinstance(item, dict)
                    and item.get("connectionFingerprint") == fingerprint
                    and item.get("probeId") == probe_id
                )
            ]
            pending.append(entry)
            state["pendingProbes"] = pending[-128:]

        self._update_state(remember)

    def _forget_probe_cleanup(self, settings: dict, probe_id: str) -> None:
        probe_id = safe_uuid(probe_id)
        fingerprint = self._connection_fingerprint(settings)

        def forget(state: dict) -> None:
            state["pendingProbes"] = [
                item for item in list(state.get("pendingProbes") or [])
                if not (
                    isinstance(item, dict)
                    and item.get("connectionFingerprint") == fingerprint
                    and item.get("probeId") == probe_id
                )
            ]

        self._update_state(forget)

    def _retry_probe_cleanup(self, client: object, settings: dict) -> list[dict]:
        fingerprint = self._connection_fingerprint(settings)
        failed: list[dict] = []
        for raw_entry in list(self._state().get("pendingProbes") or []):
            if not isinstance(raw_entry, dict) or set(raw_entry) != {
                "connectionFingerprint", "probeId", "error"
            }:
                continue
            if raw_entry.get("connectionFingerprint") != fingerprint:
                continue
            try:
                probe_id = safe_uuid(str(raw_entry.get("probeId") or ""))
                target = self._join(settings["remoteRoot"], f".yuji-probe-{probe_id}")
                client.delete(target, allow_missing=True)
                self._forget_probe_cleanup(settings, probe_id)
            except Exception as error:
                self._remember_probe_cleanup(settings, str(raw_entry.get("probeId") or ""), error)
                failed.append(dict(raw_entry))
        return failed

    @staticmethod
    def _probe_error(error: object) -> str:
        return TaskManager._sanitize_error(error)[:2048] or type(error).__name__

    def check_connection(self, payload: dict) -> dict:
        self._require_identity()
        self._require_recovery_ready()
        settings = self._temporary_settings(payload)
        client = self._temporary_client(settings)
        root = settings["remoteRoot"]
        probe_id = str(uuid.uuid4())
        probe_root = self._join(root, f".yuji-probe-{probe_id}")
        capabilities = {
            "etag": False,
            "ifNoneMatch": False,
            "ifMatchRejectsInvalid": False,
            "ifMatchAllowsValid": False,
            "moveNoOverwrite": False,
            "mkcolExisting": False,
        }
        capability_errors: dict[str, str] = {}
        cleanup_error = ""
        probe_created = False
        result: dict | None = None

        def record(name: str, operation: Callable[[], bool]) -> None:
            try:
                capabilities[name] = bool(operation())
                if not capabilities[name]:
                    capability_errors[name] = "服务器返回结果不满足安全要求"
            except Exception as error:
                capabilities[name] = False
                capability_errors[name] = self._probe_error(error)

        def put_and_etag(name: str, data: bytes) -> str:
            path = self._join(probe_root, name)
            client.put_bytes(path, data, content_type="application/octet-stream")
            _body, etag = client.get_bytes(path, max_bytes=4096)
            return etag

        try:
            self._ensure_collections(client, root)
            self._retry_probe_cleanup(client, settings)
            client.mkcol(probe_root, allow_exists=False)
            probe_created = True
            client.propfind(probe_root, depth=0)

            def check_etag() -> bool:
                return bool(put_and_etag("etag.bin", b"etag"))

            def check_if_none_match() -> bool:
                path = self._join(probe_root, "if-none.bin")
                client.put_bytes(path, b"original")
                try:
                    client.put_bytes(path, b"overwritten", if_none_match="*")
                except WebDAVError as error:
                    if error.status != 412:
                        raise
                    current, _ = client.get_bytes(path, max_bytes=4096)
                    return current == b"original"
                return False

            def check_invalid_if_match() -> bool:
                path = self._join(probe_root, "if-match-invalid.bin")
                client.put_bytes(path, b"original")
                try:
                    client.put_bytes(path, b"overwritten", if_match='"yuji-invalid-etag"')
                except WebDAVError as error:
                    if error.status != 412:
                        raise
                    current, _ = client.get_bytes(path, max_bytes=4096)
                    return current == b"original"
                return False

            def check_valid_if_match() -> bool:
                path = self._join(probe_root, "if-match-valid.bin")
                etag = put_and_etag("if-match-valid.bin", b"original")
                if not etag:
                    return False
                client.put_bytes(path, b"updated", if_match=etag)
                current, _ = client.get_bytes(path, max_bytes=4096)
                return current == b"updated"

            def check_move_no_overwrite() -> bool:
                source = self._join(probe_root, "move-source.bin")
                destination = self._join(probe_root, "move-target.bin")
                client.put_bytes(source, b"source")
                client.put_bytes(destination, b"target")
                try:
                    client.move(source, destination, overwrite=False)
                except WebDAVError as error:
                    if error.status not in {409, 412}:
                        raise
                else:
                    return False
                source_body, _ = client.get_bytes(source, max_bytes=4096)
                target_body, _ = client.get_bytes(destination, max_bytes=4096)
                return source_body == b"source" and target_body == b"target"

            def check_mkcol_existing() -> bool:
                path = self._join(probe_root, "collection")
                client.mkcol(path, allow_exists=False)
                try:
                    client.mkcol(path, allow_exists=False)
                except WebDAVError as error:
                    return error.status in {405, 409}
                return False

            record("etag", check_etag)
            record("ifNoneMatch", check_if_none_match)
            record("ifMatchRejectsInvalid", check_invalid_if_match)
            record("ifMatchAllowsValid", check_valid_if_match)
            record("moveNoOverwrite", check_move_no_overwrite)
            record("mkcolExisting", check_mkcol_existing)

            commit_mode = self._commit_mode_for_capabilities(capabilities)
            ok = commit_mode != "blocked"
            message = (
                "标准条件请求模式检查通过"
                if commit_mode == "standard"
                else "坚果云兼容提交模式检查通过"
                if ok
                else "WebDAV 安全提交能力不足，同步已被阻止"
            )
            self._record_check(
                ok,
                "" if ok else message,
                "",
                self._connection_fingerprint(settings),
                capabilities=capabilities,
                capability_errors=capability_errors,
                commit_mode=commit_mode,
                message=message,
            )
            result = {
                "ok": ok,
                "message": message,
                "capabilities": capabilities,
                "capabilityErrors": capability_errors,
                "commitMode": commit_mode,
            }
            return result
        except Exception as error:
            self._record_check(False, str(error), cleanup_error, self._connection_fingerprint(settings))
            raise
        finally:
            if probe_created:
                try:
                    client.delete(probe_root, allow_missing=True)
                    self._forget_probe_cleanup(settings, probe_id)
                except Exception as cleanup:
                    cleanup_error = self._probe_error(cleanup)
                    self._remember_probe_cleanup(settings, probe_id, cleanup)
                    if result is not None:
                        result["probeCleanupOk"] = False
                        result["warning"] = "能力检查完成，但远端探针清理待下次检查重试"

                    def record_cleanup_error(state: dict) -> None:
                        last_check = dict(state.get("lastCheck") or {})
                        if last_check.get("connectionFingerprint") == self._connection_fingerprint(settings):
                            last_check["cleanupError"] = cleanup_error
                            state["lastCheck"] = last_check

                    self._update_state(record_cleanup_error)

    def _record_check(
        self,
        ok: bool,
        error: str,
        cleanup_error: str,
        connection_fingerprint: str,
        *,
        capabilities: dict | None = None,
        capability_errors: dict | None = None,
        commit_mode: str = "",
        message: str = "",
    ) -> None:
        def update(state: dict) -> None:
            state["lastCheck"] = {
                "ok": ok,
                "checkedAt": utc_now(),
                "error": error,
                "cleanupError": cleanup_error,
                "connectionFingerprint": connection_fingerprint,
                "capabilities": dict(capabilities or {}),
                "capabilityErrors": dict(capability_errors or {}),
                "commitMode": commit_mode,
                "message": message,
            }

        self._update_state(update)

    def _connection_root(self, settings: dict) -> Path:
        return self.paths.connection_root(str(settings["connectionId"]))

    def _catalog_file(self, settings: dict) -> Path:
        return self._connection_root(settings) / "catalog.json"

    def _remote_source_cache_root(self, settings: dict, device_id: str, source_type: str) -> Path:
        return self._connection_root(settings) / "devices" / safe_uuid(device_id) / source_type

    def _index_root(self, source_id: str) -> Path:
        return self.paths.sources_root / source_id

    def source_index_root(self, source_id: str) -> Path:
        parse_remote_source_id(source_id)
        return self._index_root(source_id)

    def get_selected_source_id(self, fallback: str = "local-codex") -> str:
        try:
            state = read_json(self.paths.ui_state_file, {})
        except ConfigError:
            return fallback
        return str(state.get("selectedSourceId") or fallback)

    def set_selected_source_id(self, source_id: str) -> None:
        state = read_json(self.paths.ui_state_file, {}) if self.paths.ui_state_file.is_file() else {}
        state.update({"version": 1, "selectedSourceId": str(source_id or "local-codex")})
        write_json_atomic(self.paths.ui_state_file, state)

    def _source_base(self, settings: dict, device_id: str, source_type: str) -> str:
        return self._join(settings["remoteRoot"], "v1", "devices", device_id, source_type)

    def _device_base(self, settings: dict, device_id: str) -> str:
        return self._join(settings["remoteRoot"], "v1", "devices", device_id)

    def _publish_device(
        self,
        client: object,
        settings: dict,
        commit_mode: str,
        remote_staging_root: str,
    ) -> None:
        device_id = str(self.device["deviceId"])
        self._ensure_collections(client, settings["remoteRoot"], "v1", "devices", device_id)
        path = self._join(self._device_base(settings, device_id), "device.json")
        current, etag = client.get_optional(path, max_bytes=DEVICE_JSON_LIMIT)
        payload = {
            "schemaVersion": 1,
            "protocol": PROTOCOL,
            "deviceId": device_id,
            "displayName": str(settings.get("deviceDisplayName") or ""),
            "updatedAt": utc_now(),
            "sources": ["local-codex", "local-claude"],
        }
        payload_bytes = canonical_json_bytes(payload)
        if current is None:
            if commit_mode == "standard":
                client.put_bytes(path, payload_bytes, if_none_match="*", content_type="application/json")
                return
            try:
                self._move_create_bytes(client, path, payload_bytes, remote_staging_root)
                return
            except ProtocolError:
                current, etag = client.get_bytes(path, max_bytes=DEVICE_JSON_LIMIT)
        if current is None:
            raise ProtocolError("device.json 安全创建后无法读取")
        try:
            existing = json.loads(current.decode("utf-8"))
            self._validate_device_document(existing, device_id)
        except (UnicodeError, json.JSONDecodeError, ProtocolError, ValueError) as error:
            raise ProtocolError("现有 device.json 无法安全更新") from error
        if commit_mode == "remote-lock":
            return
        if not etag:
            raise ProtocolError("device.json 更新缺少可用 ETag")
        client.put_bytes(path, payload_bytes, if_match=etag, content_type="application/json")

    @staticmethod
    def _validate_device_document(payload: dict, expected_device_id: str) -> dict:
        if not isinstance(payload, dict):
            raise ProtocolError("device.json 不是对象")
        if int(payload.get("schemaVersion") or 0) != 1 or payload.get("protocol") != PROTOCOL:
            raise ProtocolError("不支持的 device.json 协议")
        reject_required_features(payload, "device.json")
        device_id = safe_uuid(str(payload.get("deviceId") or ""))
        if device_id != safe_uuid(expected_device_id):
            raise ProtocolError("device.json 与设备目录 UUID 不一致")
        sources = [str(value) for value in payload.get("sources") or [] if str(value) in LOCAL_SOURCE_TYPES]
        return {
            "deviceId": device_id,
            "displayName": str(payload.get("displayName") or "").strip() or "未命名设备",
            "updatedAt": str(payload.get("updatedAt") or ""),
            "sources": sorted(set(sources)),
        }

    @staticmethod
    def _device_directories_from_propfind(rows: list[dict]) -> dict[str, str]:
        devices: dict[str, str] = {}
        for row in rows:
            if not row.get("isCollection"):
                continue
            path = unquote(urlsplit(str(row.get("href") or "")).path).rstrip("/")
            leaf = path.rsplit("/", 1)[-1]
            try:
                devices[safe_uuid(leaf)] = str(row.get("etag") or "")
            except ConfigError:
                continue
        return devices

    def refresh_catalog(self) -> list[dict]:
        self._require_recovery_ready()
        settings = self._settings(require_enabled=True)
        client = self._client(settings)
        self._retry_remote_lock_cleanup(client, settings)
        self._retry_remote_staging_cleanup(client, settings)
        devices_path = self._join(settings["remoteRoot"], "v1", "devices")
        self._ensure_collections(client, settings["remoteRoot"], "v1", "devices")
        rows = client.propfind(devices_path, depth=1)
        device_directories = self._device_directories_from_propfind(rows)
        current_device_id = str(self.device["deviceId"])
        try:
            cached_catalog = read_json(self._catalog_file(settings), {})
        except ConfigError:
            cached_catalog = {}
        cached_devices = {
            str(device.get("deviceId") or ""): dict(device)
            for device in cached_catalog.get("devices") or []
            if isinstance(device, dict)
        }
        devices: list[dict] = []
        for device_id in sorted(device_directories):
            if device_id == current_device_id:
                continue
            directory_etag = device_directories[device_id]
            cached = cached_devices.get(device_id)
            if cached and directory_etag and cached.get("directoryEtag") == directory_etag:
                devices.append(cached)
                continue
            device_path = self._join(devices_path, device_id, "device.json")
            body: bytes | None
            etag = ""
            if cached and not directory_etag and cached.get("deviceEtag"):
                body, etag = client.get_if_changed(
                    device_path,
                    str(cached.get("deviceEtag") or ""),
                    max_bytes=DEVICE_JSON_LIMIT,
                )
                if body is None:
                    devices.append(cached)
                    continue
            else:
                body, etag = client.get_bytes(device_path, max_bytes=DEVICE_JSON_LIMIT)
            try:
                assert body is not None
                parsed = json.loads(body.decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError) as error:
                raise ProtocolError(f"设备 {device_id} 的 device.json 无效") from error
            device = self._validate_device_document(parsed, device_id)
            device["deviceEtag"] = etag
            device["directoryEtag"] = directory_etag
            devices.append(device)
        catalog = {
            "version": 1,
            "connectionId": settings["connectionId"],
            "checkedAt": utc_now(),
            "devices": devices,
        }
        write_json_atomic(self._catalog_file(settings), catalog)
        return self.cached_remote_sources(settings)

    def cached_remote_sources(self, settings: dict | None = None) -> list[dict]:
        settings = settings or load_raw_settings(self.paths)
        if not settings or not settings.get("connectionId"):
            return []
        try:
            catalog = read_json(self._catalog_file(settings), {})
        except ConfigError:
            return []
        devices = list(catalog.get("devices") or [])
        name_counts: dict[str, int] = {}
        for device in devices:
            name = str(device.get("displayName") or "未命名设备").casefold()
            name_counts[name] = name_counts.get(name, 0) + 1
        sources: list[dict] = []
        for device in devices:
            device_id = str(device.get("deviceId") or "")
            display_name = str(device.get("displayName") or "未命名设备")
            if name_counts.get(display_name.casefold(), 0) > 1:
                display_name = f"{display_name}-{device_id.replace('-', '')[:6]}"
            for source_type in device.get("sources") or []:
                if source_type not in LOCAL_SOURCE_TYPES:
                    continue
                source_id = remote_source_id(str(settings["connectionId"]), device_id, source_type)
                suffix = "Codex" if source_type == "local-codex" else "Claude"
                cache_root = self._remote_source_cache_root(settings, device_id, source_type)
                sources.append(
                    {
                        "id": source_id,
                        "label": f"{display_name}-云端 {suffix}",
                        "type": REMOTE_TYPE_MAP[source_type],
                        "connectionId": settings["connectionId"],
                        "deviceId": device_id,
                        "remoteSourceType": source_type,
                        "downloaded": (cache_root / "manifest.json").is_file() and self._index_root(source_id).is_dir(),
                        "offline": not bool(settings.get("enabled")),
                        "capabilities": capabilities_for_type(REMOTE_TYPE_MAP[source_type]),
                    }
                )
        return sorted(sources, key=lambda source: str(source["label"]).casefold())

    @staticmethod
    def _pointer_cache_key(settings: dict, device_id: str, source_type: str) -> tuple[str, str, str]:
        return str(settings["connectionId"]), str(device_id), str(source_type)

    def _remember_pointer(self, settings: dict, device_id: str, source_type: str, etag: str, pointer: dict) -> None:
        key = self._pointer_cache_key(settings, device_id, source_type)
        with self._lock:
            self._pointer_cache[key] = (str(etag or ""), dict(pointer))
            self._pointer_cache.move_to_end(key)
            while len(self._pointer_cache) > POINTER_CACHE_MAX_ENTRIES:
                self._pointer_cache.popitem(last=False)

    def _forget_pointer(self, settings: dict, device_id: str, source_type: str) -> None:
        with self._lock:
            self._pointer_cache.pop(self._pointer_cache_key(settings, device_id, source_type), None)

    def _read_current_pointer(self, client: object, settings: dict, device_id: str, source_type: str) -> tuple[dict | None, str]:
        source_base = self._source_base(settings, device_id, source_type)
        pointer_path = self._join(source_base, "manifest.json")
        key = self._pointer_cache_key(settings, device_id, source_type)
        with self._lock:
            cached = self._pointer_cache.get(key)
            if cached:
                self._pointer_cache.move_to_end(key)
        try:
            if cached and cached[0]:
                pointer_bytes, etag = client.get_if_changed(pointer_path, cached[0], max_bytes=POINTER_JSON_LIMIT)
                if pointer_bytes is None:
                    return dict(cached[1]), etag or cached[0]
            else:
                pointer_bytes, etag = client.get_optional(pointer_path, max_bytes=POINTER_JSON_LIMIT)
        except WebDAVError as error:
            if error.status != 404:
                raise
            self._forget_pointer(settings, device_id, source_type)
            return None, ""
        if pointer_bytes is None:
            self._forget_pointer(settings, device_id, source_type)
            return None, ""
        try:
            pointer = json.loads(pointer_bytes.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ProtocolError("manifest.json 当前指针无效") from error
        validate_current_pointer(pointer, device_id=device_id, source_type=source_type)
        self._remember_pointer(settings, device_id, source_type, etag, pointer)
        return pointer, etag

    def _read_pointer(self, client: object, settings: dict, device_id: str, source_type: str) -> tuple[dict | None, str, dict | None, bytes | None]:
        source_base = self._source_base(settings, device_id, source_type)
        pointer, etag = self._read_current_pointer(client, settings, device_id, source_type)
        if pointer is None:
            return None, "", None, None
        manifest_bytes, _ = client.get_bytes(
            self._join(source_base, pointer["manifestPath"]),
            max_bytes=MANIFEST_JSON_LIMIT,
        )
        if sha256_bytes(manifest_bytes) != pointer["manifestRevisionId"]:
            raise ProtocolError("完整 manifest 字节散列与当前指针不一致")
        try:
            manifest = json.loads(manifest_bytes.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ProtocolError("完整 manifest JSON 无效") from error
        validate_full_manifest(manifest, device_id=device_id, source_type=source_type)
        if manifest_revision_id(manifest) != pointer["manifestRevisionId"]:
            raise ProtocolError("完整 manifest canonical SHA-256 校验失败")
        for key in ("chatRevisionId", "notesRevisionId", "logicalFileCount", "logicalBytes"):
            if pointer.get(key) != manifest.get(key):
                raise ProtocolError(f"当前指针与完整 manifest 的 {key} 不一致")
        return pointer, etag, manifest, manifest_bytes

    @staticmethod
    def _safe_image_source_id(source_id: str) -> str:
        return re.sub(r"[^A-Za-z0-9._-]+", "-", str(source_id or "")).strip("-") or "local-codex"

    def _local_image_root(self) -> Path:
        return self.runtime_root / "CodexChatIndex.images"

    def _local_image_manifest_path(self, source_id: str) -> Path:
        return self._local_image_root() / "manifests" / f"{self._safe_image_source_id(source_id)}.json"

    def _local_image_object_path(self, asset_id: str) -> Path:
        digest = validate_digest(str(asset_id or ""), "图片资产 SHA-256")
        return self._local_image_root() / "objects" / digest[:2] / f"{digest}.bin"

    def _load_local_image_manifest(self, source_id: str) -> dict:
        path = self._local_image_manifest_path(source_id)
        if not path.is_file() or path.is_symlink():
            return {
                "schemaVersion": 1,
                "protocol": IMAGE_PROTOCOL,
                "sourceId": source_id,
                "sourceType": source_id,
                "assets": [],
                "references": [],
                "totalObjects": 0,
                "totalBytes": 0,
                "generatedAt": "",
            }
        try:
            if path.stat().st_size > IMAGE_MANIFEST_JSON_LIMIT:
                raise ProtocolError("本机图片清单超过大小上限")
            payload = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise ProtocolError("本机图片清单无法读取") from error
        if not isinstance(payload, dict):
            raise ProtocolError("本机图片清单格式无效")
        return payload

    def _image_remote_base(self, settings: dict, device_id: str, source_type: str) -> str:
        return self._join(self._source_base(settings, device_id, source_type), "images")

    def _ensure_image_layout(self, client: object, settings: dict, device_id: str, source_type: str) -> str:
        self._ensure_source_layout(client, settings, device_id, source_type)
        base = self._image_remote_base(settings, device_id, source_type)
        client.mkcol(base, allow_exists=True)
        for child in ("manifests", "objects", "staging"):
            client.mkcol(self._join(base, child), allow_exists=True)
        return base

    def _read_image_sidecar(
        self,
        client: object,
        settings: dict,
        device_id: str,
        source_type: str,
    ) -> tuple[dict | None, str, dict | None]:
        base = self._image_remote_base(settings, device_id, source_type)
        pointer_bytes, etag = client.get_optional(
            self._join(base, "current.json"),
            max_bytes=IMAGE_POINTER_JSON_LIMIT,
        )
        if pointer_bytes is None:
            return None, "", None
        try:
            pointer_raw = json.loads(pointer_bytes.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ProtocolError("图片 current.json 无效") from error
        pointer = validate_image_pointer(
            pointer_raw,
            expected_device_id=device_id,
            expected_source_type=source_type,
        )
        manifest_bytes, _ = client.get_bytes(
            self._join(base, pointer["manifestPath"]),
            max_bytes=IMAGE_MANIFEST_JSON_LIMIT,
        )
        try:
            manifest_raw = json.loads(manifest_bytes.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ProtocolError("图片 manifest JSON 无效") from error
        manifest = validate_image_manifest(
            manifest_raw,
            expected_device_id=device_id,
            expected_source_type=source_type,
        )
        if manifest["imageManifestRevisionId"] != pointer["imageManifestRevisionId"]:
            raise ProtocolError("图片 current.json 与 manifest revision 不一致")
        for key in ("totalObjects", "totalBytes"):
            if int(pointer.get(key) or 0) != int(manifest.get(key) or 0):
                raise ProtocolError(f"图片 current.json 与 manifest 的 {key} 不一致")
        return pointer, etag, manifest

    @staticmethod
    def _remote_image_object_sizes(client: object, base: str, manifest: dict) -> dict[str, int]:
        sizes: dict[str, int] = {}
        prefixes = sorted({str(item.get("assetId") or "")[:2] for item in manifest.get("assets") or [] if isinstance(item, dict)})
        for prefix in prefixes:
            if len(prefix) != 2:
                continue
            try:
                rows = client.propfind(WebDAVSyncService._join(base, "objects", prefix), depth=1)
            except WebDAVError as error:
                if error.status == 404:
                    continue
                raise
            for row in rows:
                if row.get("isCollection"):
                    continue
                path = unquote(urlsplit(str(row.get("href") or "")).path).rstrip("/")
                leaf = path.rsplit("/", 1)[-1]
                if not leaf.endswith(".bin"):
                    continue
                digest = leaf[:-4].casefold()
                if len(digest) == 64 and all(character in "0123456789abcdef" for character in digest):
                    sizes[digest] = int(row.get("size") or 0)
        return sizes

    def _remember_image_sync(
        self,
        settings: dict,
        source_type: str,
        *,
        pending: bool,
        revision: str = "",
        error: str = "",
    ) -> None:
        def update(connection: dict) -> None:
            image_sync = connection.setdefault("imageSync", {})
            image_sync[source_type] = {
                "pending": bool(pending),
                "imageManifestRevisionId": str(revision or ""),
                "lastError": TaskManager._sanitize_error(error)[:2048],
                "updatedAt": utc_now(),
            }

        self._update_connection_state(settings, update)

    def _sync_image_sidecar(
        self,
        settings: dict,
        source_type: str,
        *,
        client: object | None = None,
        verify_remote_objects: bool = False,
    ) -> str:
        if source_type not in LOCAL_SOURCE_TYPES:
            raise ValueError("图片 sidecar 只支持本机来源")
        client = client or self._client(settings)
        device_id = str(self.device["deviceId"])
        local_manifest = self._load_local_image_manifest(source_type)
        manifest = build_image_manifest(device_id, source_type, local_manifest)
        revision = str(manifest["imageManifestRevisionId"])
        base = self._ensure_image_layout(client, settings, device_id, source_type)
        old_pointer, _old_etag, old_manifest = self._read_image_sidecar(
            client, settings, device_id, source_type
        )
        remote_sizes: dict[str, int] = {}
        if verify_remote_objects and old_manifest:
            remote_sizes = self._remote_image_object_sizes(client, base, old_manifest)
        remote_complete = bool(old_manifest) and all(
            remote_sizes.get(str(item.get("assetId") or "")) == int(item.get("sizeBytes") or 0)
            for item in old_manifest.get("assets") or []
            if isinstance(item, dict)
        )
        if old_pointer and old_pointer.get("imageManifestRevisionId") == revision and (not verify_remote_objects or remote_complete):
            self._remember_image_sync(settings, source_type, pending=False, revision=revision)
            return revision

        if verify_remote_objects:
            old_assets = {
                str(item.get("assetId") or "")
                for item in (old_manifest or {}).get("assets") or []
                if isinstance(item, dict)
                and remote_sizes.get(str(item.get("assetId") or "")) == int(item.get("sizeBytes") or 0)
            }
        else:
            old_assets = {
                str(item.get("assetId") or "")
                for item in (old_manifest or {}).get("assets") or []
                if isinstance(item, dict)
            }
        staging = self._connection_root(settings) / "image-sync"
        staging.mkdir(parents=True, exist_ok=True)
        try:
            created_prefixes: set[str] = set()
            for asset in manifest["assets"]:
                digest = str(asset["assetId"])
                local_path = self._local_image_object_path(digest)
                if (
                    not local_path.is_file()
                    or local_path.is_symlink()
                    or local_path.stat().st_size != int(asset["sizeBytes"])
                    or sha256_file(local_path) != digest
                ):
                    raise ProtocolError(f"本机图片对象校验失败：{digest}")
                if digest in old_assets:
                    continue
                prefix = digest[:2]
                if prefix not in created_prefixes:
                    client.mkcol(self._join(base, "objects", prefix), allow_exists=True)
                    created_prefixes.add(prefix)
                try:
                    client.put_file(
                        self._join(base, "objects", prefix, f"{digest}.bin"),
                        local_path,
                        if_none_match="*",
                    )
                except WebDAVError as error:
                    if error.status != 412:
                        raise
                    verification = staging / f"verify-{digest}.bin"
                    try:
                        client.download(
                            self._join(base, "objects", prefix, f"{digest}.bin"),
                            verification,
                            max_bytes=int(asset["sizeBytes"]),
                        )
                        if (
                            verification.stat().st_size != int(asset["sizeBytes"])
                            or sha256_file(verification) != digest
                        ):
                            raise ProtocolError(f"云端同名图片对象内容冲突：{digest}") from error
                    finally:
                        verification.unlink(missing_ok=True)

            manifest_bytes = canonical_json_bytes(manifest)
            manifest_path = self._join(base, "manifests", f"{revision}.json")
            try:
                client.put_bytes(
                    manifest_path,
                    manifest_bytes,
                    if_none_match="*",
                    content_type="application/json",
                )
            except WebDAVError as error:
                if error.status != 412:
                    raise
                existing, _ = client.get_bytes(
                    manifest_path,
                    max_bytes=max(len(manifest_bytes), 1),
                )
                if existing != manifest_bytes:
                    raise ProtocolError("云端同名图片 manifest 内容冲突") from error

            pointer = {
                "schemaVersion": 1,
                "protocol": IMAGE_PROTOCOL,
                "deviceId": device_id,
                "sourceType": source_type,
                "imageManifestRevisionId": revision,
                "manifestPath": f"manifests/{revision}.json",
                "totalObjects": int(manifest["totalObjects"]),
                "totalBytes": int(manifest["totalBytes"]),
                "updatedAt": utc_now(),
            }
            client.put_bytes(
                self._join(base, "current.json"),
                canonical_json_bytes(pointer),
                content_type="application/json",
            )
            self._remember_image_sync(settings, source_type, pending=False, revision=revision)
            return revision
        finally:
            try:
                shutil.rmtree(staging)
            except OSError:
                pass

    def _current_local_image_revision(self, source_type: str) -> str:
        manifest = build_image_manifest(
            str(self.device["deviceId"]),
            source_type,
            self._load_local_image_manifest(source_type),
        )
        return str(manifest["imageManifestRevisionId"])

    def schedule_image_sync(self, source_type: str) -> dict:
        if source_type not in LOCAL_SOURCE_TYPES:
            return {"scheduled": False, "pending": False, "reason": "unsupported"}
        with self._lock:
            try:
                settings = self._settings(require_enabled=True)
            except ConfigError:
                return {"scheduled": False, "pending": False, "reason": "disabled"}
            current = self.task_state()
            if current.get("status") in {"running", "cancelling"}:
                self._remember_image_sync(settings, source_type, pending=True, error="WebDAV busy")
                return {"scheduled": False, "pending": True, "reason": "busy"}
            if self._image_sync_thread is not None and self._image_sync_thread.is_alive():
                self._remember_image_sync(settings, source_type, pending=True, error="image sync busy")
                return {"scheduled": False, "pending": True, "reason": "busy"}
            self._remember_image_sync(settings, source_type, pending=True)
            self._image_sync_source = source_type

            def worker() -> None:
                try:
                    while True:
                        revision = self._sync_image_sidecar(settings, source_type)
                        if revision == self._current_local_image_revision(source_type):
                            break
                    self._remember_image_sync(
                        settings, source_type, pending=False, revision=revision
                    )
                except Exception as error:
                    try:
                        self._remember_image_sync(
                            settings,
                            source_type,
                            pending=True,
                            error=str(error),
                        )
                    except Exception:
                        pass
                finally:
                    with self._lock:
                        self._image_sync_thread = None
                        self._image_sync_source = ""

            thread = threading.Thread(
                target=worker,
                name=f"YujiImageSync-{source_type}",
                daemon=True,
            )
            self._image_sync_thread = thread
            thread.start()
            return {"scheduled": True, "pending": True, "reason": ""}

    def _download_image_sidecar(
        self,
        context: TaskContext,
        client: object,
        settings: dict,
        source_id: str,
        device_id: str,
        source_type: str,
        staging: Path,
    ) -> bool:
        previous_revision = ""
        previous_manifest_path = self._local_image_manifest_path(source_id)
        if previous_manifest_path.is_file() and not previous_manifest_path.is_symlink():
            try:
                previous_payload = json.loads(previous_manifest_path.read_text(encoding="utf-8-sig"))
                if isinstance(previous_payload, dict):
                    previous_revision = str(previous_payload.get("imageManifestRevisionId") or "")
            except (OSError, UnicodeError, json.JSONDecodeError):
                previous_revision = ""
        pointer, _etag, manifest = self._read_image_sidecar(
            client, settings, device_id, source_type
        )
        if pointer is None or manifest is None:
            return False
        local_root = self._local_image_root()
        for asset in manifest["assets"]:
            self._webdav_checkpoint(context)
            digest = str(asset["assetId"])
            size_bytes = int(asset["sizeBytes"])
            target = self._local_image_object_path(digest)
            reusable = False
            try:
                reusable = (
                    target.is_file()
                    and not target.is_symlink()
                    and target.stat().st_size == size_bytes
                    and sha256_file(target) == digest
                )
            except OSError:
                reusable = False
            if reusable:
                continue
            download_target = staging / "images" / "objects" / digest[:2] / f"{digest}.bin"
            client.download(
                self._join(
                    self._image_remote_base(settings, device_id, source_type),
                    "objects",
                    digest[:2],
                    f"{digest}.bin",
                ),
                download_target,
                max_bytes=size_bytes,
            )
            if (
                download_target.stat().st_size != size_bytes
                or sha256_file(download_target) != digest
            ):
                raise ProtocolError(f"云端图片对象校验失败：{digest}")
            target.parent.mkdir(parents=True, exist_ok=True)
            if not target.exists():
                try:
                    os.replace(download_target, target)
                except OSError:
                    if not target.exists():
                        raise

        local_payload = {
            "schemaVersion": 1,
            "protocol": IMAGE_PROTOCOL,
            "sourceId": source_id,
            "sourceType": REMOTE_TYPE_MAP[source_type],
            "imageManifestRevisionId": pointer["imageManifestRevisionId"],
            "assets": list(manifest["assets"]),
            "references": list(manifest["references"]),
            "totalObjects": int(manifest["totalObjects"]),
            "totalBytes": int(manifest["totalBytes"]),
            "generatedAt": str(manifest.get("generatedAt") or ""),
        }
        manifest_path = self._local_image_manifest_path(source_id)
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        write_json_atomic(manifest_path, local_payload)
        return previous_revision != str(pointer["imageManifestRevisionId"])

    def _export_inventory(self, source_type: str, inventory_path: Path) -> dict:
        command = [
            "pwsh",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(self.build_script),
            "-SourceId",
            source_type,
            "-SourceType",
            source_type,
            "-ExportSyncInventoryPath",
            str(inventory_path),
            "-JsonSummary",
        ]
        process = subprocess.run(command, cwd=self.build_script.parent, capture_output=True, text=True, encoding="utf-8", errors="replace")
        if process.returncode != 0:
            raise RuntimeError(process.stderr.strip() or process.stdout.strip() or "同步 inventory 扫描失败")
        try:
            inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError("同步 inventory 未生成有效 JSON") from error
        return inventory

    def _all_notes(self) -> dict:
        if not self.notes_file.is_file():
            return {}
        try:
            value = json.loads(self.notes_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError("本机备注文件无法读取") from error
        return dict(value.get("notes") or {}) if isinstance(value, dict) else {}

    @staticmethod
    def _confirmation_token(source_type: str, old_revision: str, new_revision: str, source_signature: object) -> str:
        payload = {
            "sourceType": source_type,
            "oldRevision": old_revision,
            "newRevision": new_revision,
            "sourceSignature": source_signature,
        }
        return hashlib.sha256(canonical_json_bytes(payload)).hexdigest()

    @staticmethod
    def _deletion_requires_confirmation(old_manifest: dict | None, new_manifest: dict) -> tuple[bool, int, int]:
        old_paths = {item["logicalPath"] for item in (old_manifest or {}).get("logicalFiles") or []}
        new_paths = {item["logicalPath"] for item in new_manifest.get("logicalFiles") or []}
        deleted = len(old_paths - new_paths)
        previous = len(old_paths)
        required = bool(previous and not new_paths) or bool(deleted >= 20 and deleted * 100 >= previous * 20)
        return required, deleted, previous

    def _ensure_source_layout(self, client: object, settings: dict, device_id: str, source_type: str) -> None:
        self._ensure_collections(
            client,
            settings["remoteRoot"],
            "v1",
            "devices",
            device_id,
            source_type,
        )
        base = self._source_base(settings, device_id, source_type)
        for child in ("staging", "manifests", "objects", "notes", "locks"):
            client.mkcol(self._join(base, child), allow_exists=True)

    def _put_immutable_bytes(self, client: object, path: str, data: bytes) -> None:
        self._put_immutable_bytes_for_mode(client, path, data, "standard", "")

    def _move_create_bytes(
        self,
        client: object,
        path: str,
        data: bytes,
        remote_staging_root: str,
    ) -> str:
        temporary = self._join(remote_staging_root, f"create-{uuid.uuid4()}.tmp")
        client.put_bytes(temporary, data, content_type="application/octet-stream")
        try:
            client.move(temporary, path, overwrite=False)
        except WebDAVError as error:
            if error.status not in {409, 412}:
                raise
            existing, etag = client.get_bytes(path, max_bytes=max(len(data), 1))
            if existing != data:
                raise ProtocolError(f"远端不可变对象内容冲突：{path}") from error
            return etag
        existing, etag = client.get_bytes(path, max_bytes=max(len(data), 1))
        if existing != data:
            raise ProtocolError(f"远端 MOVE 创建后内容校验失败：{path}")
        return etag

    def _put_immutable_bytes_for_mode(
        self,
        client: object,
        path: str,
        data: bytes,
        commit_mode: str,
        remote_staging_root: str,
    ) -> None:
        if commit_mode in {"move-create", "remote-lock"}:
            self._move_create_bytes(client, path, data, remote_staging_root)
            return
        try:
            client.put_bytes(path, data, if_none_match="*", content_type="application/json")
        except WebDAVError as error:
            if error.status != 412:
                raise
            existing, _ = client.get_bytes(path, max_bytes=max(len(data), 1))
            if existing != data:
                raise ProtocolError(f"远端不可变对象内容冲突：{path}") from error

    def _put_object(
        self,
        client: object,
        path: str,
        local_path: Path,
        verification_root: Path,
        commit_mode: str = "standard",
        remote_staging_root: str = "",
    ) -> None:
        if commit_mode in {"move-create", "remote-lock"}:
            temporary = self._join(remote_staging_root, f"object-{uuid.uuid4()}.tmp")
            client.put_file(temporary, local_path)
            try:
                client.move(temporary, path, overwrite=False)
            except WebDAVError as error:
                if error.status not in {409, 412}:
                    raise
                verification = verification_root / f"verify-{uuid.uuid4().hex}.bin"
                try:
                    client.download(path, verification, max_bytes=local_path.stat().st_size)
                    if (
                        verification.stat().st_size != local_path.stat().st_size
                        or sha256_file(verification) != sha256_file(local_path)
                    ):
                        raise ProtocolError(f"远端同名内容寻址对象校验失败：{path}")
                finally:
                    verification.unlink(missing_ok=True)
            return
        try:
            client.put_file(path, local_path, if_none_match="*")
        except WebDAVError as error:
            if error.status != 412:
                raise
            verification = verification_root / f"verify-{uuid.uuid4().hex}.bin"
            try:
                client.download(path, verification, max_bytes=local_path.stat().st_size)
                if verification.stat().st_size != local_path.stat().st_size or sha256_file(verification) != sha256_file(local_path):
                    raise ProtocolError(f"远端同名内容寻址对象校验失败：{path}")
            finally:
                verification.unlink(missing_ok=True)

    def _upload_journal_file(self, settings: dict, source_type: str) -> Path:
        return (
            self._remote_source_cache_root(settings, str(self.device["deviceId"]), source_type)
            / "journal"
            / "uploaded-objects.json"
        )

    def _load_upload_journal(self, settings: dict, source_type: str) -> dict[str, int]:
        path = self._upload_journal_file(settings, source_type)
        if not path.is_file():
            return {}
        try:
            if path.stat().st_size > UPLOAD_JOURNAL_MAX_BYTES:
                raise ConfigError("上传对象 journal 超过大小上限")
            payload = read_json(path, {})
            if int(payload.get("version") or 0) != 1 or payload.get("sourceType") != source_type:
                raise ConfigError("上传对象 journal 格式无效")
            raw_objects = payload.get("objects") or {}
            if not isinstance(raw_objects, dict) or len(raw_objects) > UPLOAD_JOURNAL_MAX_ENTRIES:
                raise ConfigError("上传对象 journal 条目数量无效")
            objects: dict[str, int] = {}
            for raw_digest, raw_size in raw_objects.items():
                digest = validate_digest(str(raw_digest), "upload journal object SHA-256")
                size = int(raw_size)
                if size < 0:
                    raise ConfigError("上传对象 journal 大小无效")
                objects[digest] = size
            return objects
        except (ConfigError, OSError, TypeError, ValueError):
            path.unlink(missing_ok=True)
            return {}

    def _write_upload_journal(self, settings: dict, source_type: str, objects: dict[str, int]) -> None:
        if len(objects) > UPLOAD_JOURNAL_MAX_ENTRIES:
            raise RuntimeError("上传对象 journal 条目超过上限")
        write_json_atomic(
            self._upload_journal_file(settings, source_type),
            {
                "version": 1,
                "sourceType": source_type,
                "objects": {digest: int(objects[digest]) for digest in sorted(objects)},
                "updatedAt": utc_now(),
            },
        )

    def _clear_upload_journal(self, settings: dict, source_type: str) -> None:
        self._upload_journal_file(settings, source_type).unlink(missing_ok=True)

    def start_upload(self, source_id: str, confirmation_token: str = "") -> dict:
        with self._lock:
            self._require_recovery_ready()
            self._require_idle_task()
            if source_id not in LOCAL_SOURCE_TYPES:
                raise ValueError("只有本机 Codex 或本机 Claude 可以上传")
            settings = self._settings(require_enabled=True)
            commit_mode = self._require_safe_commit_mode(settings)
            return self._task_manager.start(
                "upload",
                source_id,
                lambda context: self._upload(
                    context,
                    settings,
                    source_id,
                    str(confirmation_token or ""),
                    commit_mode,
                ),
            )

    def _upload(
        self,
        context: TaskContext,
        settings: dict,
        source_type: str,
        confirmation_token: str,
        commit_mode: str,
    ) -> None:
        client = self._client(settings)
        self._retry_remote_lock_cleanup(client, settings)
        self._retry_remote_staging_cleanup(client, settings)
        device_id = str(self.device["deviceId"])
        connection_root = self._connection_root(settings)
        staging = connection_root / "tasks" / context.task_id / "staging"
        self._remove_directory(staging)
        staging.mkdir(parents=True, exist_ok=True)
        source_base = self._source_base(settings, device_id, source_type)
        remote_task_root = ""
        remote_lock: dict | None = None
        pointer_committed = False
        try:
            context.update(stage="同步图片")
            self._sync_image_sidecar(settings, source_type, client=client, verify_remote_objects=True)
            context.update(stage="扫描")
            inventory_path = staging / "inventory.json"
            inventory = self._inventory_provider(source_type, inventory_path)
            if not inventory.get("scanComplete") or inventory.get("errors"):
                raise ProtocolError("同步 inventory 扫描不完整，禁止上传")
            self._webdav_checkpoint(context)
            context.update(stage="比较清单")
            self._ensure_source_layout(client, settings, device_id, source_type)
            if commit_mode == "standard":
                self._publish_device(client, settings, commit_mode, "")
            else:
                remote_task_root = self._join(source_base, "staging", context.task_id)
                client.mkcol(remote_task_root, allow_exists=True)
                if commit_mode == "remote-lock":
                    remote_lock = self._acquire_remote_commit_lock(
                        client, settings, source_type, context.task_id
                    )
                    self._upload_checkpoint(
                        context, client, settings, remote_lock, force_lock_check=True
                    )
                self._publish_device(client, settings, commit_mode, remote_task_root)
            old_pointer, old_etag, old_manifest, _old_manifest_bytes = self._read_pointer(
                client, settings, device_id, source_type
            )
            self._upload_checkpoint(
                context, client, settings, remote_lock, force_lock_check=remote_lock is not None
            )
            pending_cleanup_ok = self._retry_pending_cleanup(client, settings, source_type, old_pointer, old_manifest)
            notes_document = build_notes_document(device_id, source_type, self._all_notes())
            uploaded_state = dict(self._connection_state(settings).get("uploaded", {}).get(source_type) or {})
            can_reuse_chat = bool(
                old_pointer
                and old_manifest
                and uploaded_state.get("sourceSignature") == inventory.get("sourceSignature")
                and uploaded_state.get("manifestRevisionId") == old_pointer.get("manifestRevisionId")
                and uploaded_state.get("chatRevisionId") == old_pointer.get("chatRevisionId")
            )
            if can_reuse_chat:
                snapshot = SnapshotResult(
                    source_type=source_type,
                    source_signature=inventory.get("sourceSignature"),
                    logical_files=list(old_manifest.get("logicalFiles") or []),
                    objects={},
                    chat_revision_id=str(old_manifest["chatRevisionId"]),
                    logical_bytes=int(old_manifest["logicalBytes"]),
                )
            else:
                context.update(stage="打包", files_total=len(inventory.get("files") or []), files_done=0)
                snapshot = create_snapshot(
                    inventory,
                    staging / "snapshot",
                    checkpoint=lambda: self._upload_checkpoint(
                        context, client, settings, remote_lock
                    ),
                )
            manifest, notes_bytes, revision = create_full_manifest(device_id, snapshot, notes_document)
            required, deleted_count, previous_count = self._deletion_requires_confirmation(old_manifest, manifest)
            expected_token = self._confirmation_token(
                source_type,
                str((old_pointer or {}).get("manifestRevisionId") or ""),
                revision,
                snapshot.source_signature,
            )
            if required and confirmation_token != expected_token:
                raise ConfirmationRequiredError(expected_token, deleted_count, previous_count)

            if old_pointer and old_pointer.get("manifestRevisionId") == revision:
                self._remember_uploaded(settings, source_type, snapshot.source_signature, old_pointer)
                self._clear_upload_journal(settings, source_type)
                context.update(stage="完成", files_done=len(snapshot.logical_files), bytes_done=snapshot.logical_bytes, bytes_total=snapshot.logical_bytes)
                return

            if not remote_task_root:
                remote_task_root = self._join(source_base, "staging", context.task_id)
                client.mkcol(remote_task_root, allow_exists=True)

            reusable_objects = referenced_object_digests(old_manifest or {})
            upload_journal = self._load_upload_journal(settings, source_type)
            journal_reusable = {
                digest
                for digest, path in snapshot.objects.items()
                if upload_journal.get(digest) == path.stat().st_size
            }
            objects_to_upload = {
                digest: path
                for digest, path in snapshot.objects.items()
                if digest not in reusable_objects and digest not in journal_reusable
            }
            context.update(
                stage="上传对象",
                files_total=len(objects_to_upload),
                files_done=0,
                bytes_total=sum(path.stat().st_size for path in objects_to_upload.values()),
                bytes_done=0,
            )
            bytes_done = 0
            files_done = 0
            created_prefixes: set[str] = set()
            for digest, local_path in sorted(objects_to_upload.items()):
                self._upload_checkpoint(context, client, settings, remote_lock)
                prefix = digest[:2]
                if prefix not in created_prefixes:
                    client.mkcol(self._join(source_base, "objects", prefix), allow_exists=True)
                    created_prefixes.add(prefix)
                self._put_object(
                    client,
                    self._join(source_base, "objects", prefix, f"{digest}.bin"),
                    local_path,
                    staging,
                    commit_mode,
                    remote_task_root,
                )
                upload_journal[digest] = local_path.stat().st_size
                self._write_upload_journal(settings, source_type, upload_journal)
                files_done += 1
                bytes_done += local_path.stat().st_size
                context.update(files_done=files_done, bytes_done=bytes_done)

            self._upload_checkpoint(context, client, settings, remote_lock)
            if not old_pointer or old_pointer.get("notesRevisionId") != manifest["notesRevisionId"]:
                self._put_immutable_bytes_for_mode(
                    client,
                    self._join(source_base, "notes", f"{manifest['notesRevisionId']}.json"),
                    notes_bytes,
                    commit_mode,
                    remote_task_root,
                )
            manifest_bytes = canonical_json_bytes(manifest)
            remote_staging_manifest = self._join(remote_task_root, "manifest.json")
            client.put_bytes(
                remote_staging_manifest,
                manifest_bytes,
                if_none_match="*" if commit_mode == "standard" else "",
                content_type="application/json",
            )
            immutable_manifest = self._join(source_base, "manifests", f"{revision}.json")
            try:
                client.move(remote_staging_manifest, immutable_manifest, overwrite=False)
            except WebDAVError as error:
                if error.status not in {409, 412}:
                    raise
                existing, _ = client.get_bytes(immutable_manifest, max_bytes=MANIFEST_JSON_LIMIT)
                if existing != manifest_bytes:
                    raise ProtocolError("远端同名完整 manifest 内容冲突") from error

            context.check_cancelled()
            pointer = {
                "schemaVersion": 1,
                "protocol": PROTOCOL,
                "deviceId": device_id,
                "sourceType": source_type,
                "manifestRevisionId": revision,
                "manifestPath": f"manifests/{revision}.json",
                "chatRevisionId": manifest["chatRevisionId"],
                "notesRevisionId": manifest["notesRevisionId"],
                "logicalFileCount": manifest["logicalFileCount"],
                "logicalBytes": manifest["logicalBytes"],
                "updatedAt": utc_now(),
            }
            context.update(stage="提交清单", can_cancel=False)
            pointer_path = self._join(source_base, "manifest.json")
            pointer_bytes = canonical_json_bytes(pointer)
            if commit_mode == "remote-lock":
                self._upload_checkpoint(
                    context, client, settings, remote_lock, force_lock_check=True
                )
                pointer_etag = client.put_bytes(
                    pointer_path,
                    pointer_bytes,
                    content_type="application/json",
                )
                checked_pointer, checked_etag = client.get_bytes(
                    pointer_path, max_bytes=max(len(pointer_bytes), 1)
                )
                if checked_pointer != pointer_bytes:
                    raise ProtocolError("远端 manifest.json 指针写入后读回不一致")
                pointer_etag = checked_etag or pointer_etag
            elif old_pointer:
                pointer_etag = client.put_bytes(pointer_path, canonical_json_bytes(pointer), if_match=old_etag, content_type="application/json")
            elif commit_mode == "move-create":
                pointer_etag = self._move_create_bytes(
                    client,
                    pointer_path,
                    pointer_bytes,
                    remote_task_root,
                )
            else:
                pointer_etag = client.put_bytes(pointer_path, canonical_json_bytes(pointer), if_none_match="*", content_type="application/json")
            pointer_committed = True
            if pointer_etag:
                self._remember_pointer(settings, device_id, source_type, pointer_etag, pointer)
            else:
                self._forget_pointer(settings, device_id, source_type)
            self._remember_uploaded(settings, source_type, snapshot.source_signature, pointer)
            context.update(stage="清理")
            journal_orphans = set(upload_journal) - referenced_object_digests(manifest)
            if remote_lock is not None:
                try:
                    self._maintain_remote_commit_lock(
                        client, settings, remote_lock, force=True
                    )
                except Exception as lock_error:
                    self._remember_pending_cleanup(
                        settings,
                        source_type,
                        old_pointer,
                        old_manifest,
                        pointer,
                        manifest,
                        str(lock_error),
                        journal_orphans,
                    )
                    raise
            try:
                self._cleanup_old_remote(
                    client,
                    source_base,
                    old_pointer,
                    old_manifest,
                    pointer,
                    manifest,
                    journal_orphans,
                )
                if pending_cleanup_ok:
                    self._clear_pending_cleanup(settings, source_type)
                self._clear_upload_journal(settings, source_type)
            except Exception as cleanup_error:
                self._remember_pending_cleanup(
                    settings,
                    source_type,
                    old_pointer,
                    old_manifest,
                    pointer,
                    manifest,
                    str(cleanup_error),
                    journal_orphans,
                )
        finally:
            if remote_task_root:
                try:
                    if remote_lock is not None:
                        self._maintain_remote_commit_lock(
                            client, settings, remote_lock, force=True
                        )
                    remote_cleanup_ok = self._cleanup_remote_task_staging(
                        client, settings, source_type, context.task_id
                    )
                except Exception as cleanup_error:
                    remote_cleanup_ok = False
                    try:
                        self._remember_remote_staging_cleanup(
                            settings, source_type, context.task_id, cleanup_error
                        )
                    except Exception as state_error:
                        self.recovery_warning = (
                            "远端暂存清理失败，且待重试状态无法保存："
                            + TaskManager._sanitize_error(state_error)[:1024]
                        )
                    self.recovery_warning = "远端暂存清理失败，且待重试状态无法保存"
                    try:
                        context.update(warning="远端暂存清理失败，且待重试状态无法保存")
                    except Exception as update_error:
                        self.recovery_warning += "：" + TaskManager._sanitize_error(update_error)[:1024]
                if not remote_cleanup_ok:
                    warning = (
                        "新版本有效，但远端暂存清理待重试"
                        if pointer_committed
                        else "远端暂存清理待重试"
                    )
                    try:
                        context.update(warning=warning)
                    except Exception as update_error:
                        self.recovery_warning = (
                            "远端暂存清理警告状态无法保存："
                            + TaskManager._sanitize_error(update_error)[:1024]
                        )
            if remote_lock is not None and not self._release_remote_commit_lock(
                client, settings, remote_lock
            ):
                try:
                    context.update(warning="远端提交锁清理待下次手动任务重试")
                except Exception as update_error:
                    self.recovery_warning = (
                        "远端提交锁清理警告状态无法保存："
                        + TaskManager._sanitize_error(update_error)[:1024]
                    )
            self._cleanup_temporary_directory(settings, "upload", context.task_id, staging)

    def _remember_uploaded(self, settings: dict, source_type: str, source_signature: object, pointer: dict) -> None:
        def update(connection: dict) -> None:
            uploaded = connection.setdefault("uploaded", {})
            uploaded[source_type] = {
                "sourceSignature": source_signature,
                "manifestRevisionId": pointer.get("manifestRevisionId", ""),
                "chatRevisionId": pointer.get("chatRevisionId", ""),
                "notesRevisionId": pointer.get("notesRevisionId", ""),
                "uploadedAt": utc_now(),
            }

        self._update_connection_state(settings, update)
        self._status_cache.pop(source_type, None)

    @staticmethod
    def _pending_cleanup_values(pending: dict, plural_key: str, singular_key: str, label: str) -> set[str]:
        values = {validate_digest(str(value), label) for value in pending.get(plural_key) or []}
        if pending.get(singular_key):
            values.add(validate_digest(str(pending[singular_key]), label))
        return values

    def _remember_pending_cleanup(
        self,
        settings: dict,
        source_type: str,
        old_pointer: dict | None,
        old_manifest: dict | None,
        new_pointer: dict,
        new_manifest: dict,
        error: str,
        extra_object_digests: set[str] | None = None,
    ) -> None:
        old_objects = referenced_object_digests(old_manifest or {})
        new_objects = referenced_object_digests(new_manifest)
        extra_objects = {validate_digest(digest) for digest in (extra_object_digests or set())}
        notes_revision = str((old_pointer or {}).get("notesRevisionId") or "")
        manifest_revision = str((old_pointer or {}).get("manifestRevisionId") or "")
        existing = dict(self._connection_state(settings).get("pendingCleanup", {}).get(source_type) or {})
        object_digests = self._pending_cleanup_values(
            existing, "objectDigests", "objectDigest", "pending cleanup object SHA-256"
        )
        notes_revisions = self._pending_cleanup_values(
            existing, "notesRevisionIds", "notesRevisionId", "pending cleanup notesRevisionId"
        )
        manifest_revisions = self._pending_cleanup_values(
            existing, "manifestRevisionIds", "manifestRevisionId", "pending cleanup manifestRevisionId"
        )
        object_digests.update((old_objects - new_objects) | (extra_objects - new_objects))
        if notes_revision and notes_revision != str(new_pointer.get("notesRevisionId") or ""):
            notes_revisions.add(validate_digest(notes_revision, "pending cleanup notesRevisionId"))
        if manifest_revision and manifest_revision != str(new_pointer.get("manifestRevisionId") or ""):
            manifest_revisions.add(validate_digest(manifest_revision, "pending cleanup manifestRevisionId"))
        committed_revisions = {
            str(value) for value in existing.get("committedManifestRevisionIds") or [] if str(value)
        }
        if existing.get("committedManifestRevisionId"):
            committed_revisions.add(str(existing["committedManifestRevisionId"]))
        if new_pointer.get("manifestRevisionId"):
            committed_revisions.add(str(new_pointer["manifestRevisionId"]))

        def update(connection: dict) -> None:
            pending = connection.setdefault("pendingCleanup", {})
            pending[source_type] = {
                "committedManifestRevisionIds": sorted(committed_revisions),
                "objectDigests": sorted(object_digests),
                "notesRevisionIds": sorted(notes_revisions),
                "manifestRevisionIds": sorted(manifest_revisions),
                "error": error,
                "recordedAt": utc_now(),
            }

        self._update_connection_state(settings, update)

    def _clear_pending_cleanup(self, settings: dict, source_type: str) -> None:
        def update(connection: dict) -> None:
            pending = connection.setdefault("pendingCleanup", {})
            pending.pop(source_type, None)

        self._update_connection_state(settings, update)

    def _retry_pending_cleanup(
        self,
        client: object,
        settings: dict,
        source_type: str,
        current_pointer: dict | None,
        current_manifest: dict | None,
    ) -> bool:
        pending = dict(self._connection_state(settings).get("pendingCleanup", {}).get(source_type) or {})
        if not pending:
            return True
        source_base = self._source_base(settings, str(self.device["deviceId"]), source_type)
        current_objects = referenced_object_digests(current_manifest or {})
        object_digests = self._pending_cleanup_values(
            pending, "objectDigests", "objectDigest", "pending cleanup object SHA-256"
        )
        notes_revisions = self._pending_cleanup_values(
            pending, "notesRevisionIds", "notesRevisionId", "pending cleanup notesRevisionId"
        )
        manifest_revisions = self._pending_cleanup_values(
            pending, "manifestRevisionIds", "manifestRevisionId", "pending cleanup manifestRevisionId"
        )
        remaining_objects: set[str] = set()
        remaining_notes: set[str] = set()
        remaining_manifests: set[str] = set()
        errors: list[str] = []

        for digest in sorted(object_digests):
            if digest not in current_objects:
                try:
                    client.delete(self._join(source_base, "objects", digest[:2], f"{digest}.bin"), allow_missing=True)
                except Exception as error:
                    remaining_objects.add(digest)
                    errors.append(str(error))
        current_notes_revision = str((current_pointer or {}).get("notesRevisionId") or "")
        for notes_revision in sorted(notes_revisions):
            if notes_revision != current_notes_revision:
                try:
                    client.delete(self._join(source_base, "notes", f"{notes_revision}.json"), allow_missing=True)
                except Exception as error:
                    remaining_notes.add(notes_revision)
                    errors.append(str(error))
        current_manifest_revision = str((current_pointer or {}).get("manifestRevisionId") or "")
        for manifest_revision in sorted(manifest_revisions):
            if manifest_revision != current_manifest_revision:
                try:
                    client.delete(self._join(source_base, "manifests", f"{manifest_revision}.json"), allow_missing=True)
                except Exception as error:
                    remaining_manifests.add(manifest_revision)
                    errors.append(str(error))

        if remaining_objects or remaining_notes or remaining_manifests:
            pending["objectDigests"] = sorted(remaining_objects)
            pending["notesRevisionIds"] = sorted(remaining_notes)
            pending["manifestRevisionIds"] = sorted(remaining_manifests)
            pending.pop("objectDigest", None)
            pending.pop("notesRevisionId", None)
            pending.pop("manifestRevisionId", None)
            pending["error"] = "; ".join(errors)[:2048]
            pending["lastAttemptAt"] = utc_now()

            def remember(connection: dict) -> None:
                connection.setdefault("pendingCleanup", {})[source_type] = pending

            self._update_connection_state(settings, remember)
            return False
        self._clear_pending_cleanup(settings, source_type)
        return True

    def _cleanup_old_remote(
        self,
        client: object,
        source_base: str,
        old_pointer: dict | None,
        old_manifest: dict | None,
        new_pointer: dict,
        new_manifest: dict,
        extra_object_digests: set[str] | None = None,
    ) -> None:
        old_objects = referenced_object_digests(old_manifest or {})
        new_objects = referenced_object_digests(new_manifest)
        extra_objects = {validate_digest(digest) for digest in (extra_object_digests or set())}
        for digest in sorted((old_objects - new_objects) | (extra_objects - new_objects)):
            client.delete(self._join(source_base, "objects", digest[:2], f"{digest}.bin"), allow_missing=True)
        if not old_pointer or not old_manifest:
            return
        if old_pointer.get("notesRevisionId") != new_pointer.get("notesRevisionId"):
            client.delete(self._join(source_base, "notes", f"{old_pointer['notesRevisionId']}.json"), allow_missing=True)
        if old_pointer.get("manifestRevisionId") != new_pointer.get("manifestRevisionId"):
            client.delete(self._join(source_base, "manifests", f"{old_pointer['manifestRevisionId']}.json"), allow_missing=True)

    def start_download(self, source_id: str) -> dict:
        with self._lock:
            self._require_recovery_ready()
            self._require_idle_task()
            settings = self._settings(require_enabled=True)
            connection_id, _device_id, _source_type = parse_remote_source_id(source_id)
            if connection_id != settings["connectionId"]:
                raise ValueError("云端来源不属于当前 WebDAV 连接")
            return self._task_manager.start(
                "download",
                source_id,
                lambda context: self._download(context, settings, source_id),
            )

    def _download(self, context: TaskContext, settings: dict, source_id: str) -> None:
        connection_id, device_id, source_type = parse_remote_source_id(source_id)
        if connection_id != settings["connectionId"]:
            raise ValueError("云端来源不属于当前连接")
        client = self._client(settings)
        self._retry_remote_lock_cleanup(client, settings)
        self._retry_remote_staging_cleanup(client, settings)
        source_base = self._source_base(settings, device_id, source_type)
        cache_root = self._remote_source_cache_root(settings, device_id, source_type)
        task_staging = self._connection_root(settings) / "tasks" / context.task_id / "staging"
        self._remove_directory(task_staging)
        task_staging.mkdir(parents=True, exist_ok=True)
        try:
            context.update(stage="比较清单")
            pointer, _etag, manifest, manifest_bytes = self._read_pointer(client, settings, device_id, source_type)
            if pointer is None or manifest is None or manifest_bytes is None:
                raise ProtocolError("云端来源尚未上传")
            connection_state = self._connection_state(settings)
            downloaded = dict(connection_state.get("downloaded", {}).get(source_id) or {})
            chat_changed = downloaded.get("chatRevisionId") != pointer["chatRevisionId"]
            notes_changed = downloaded.get("notesRevisionId") != pointer["notesRevisionId"]
            notes_bytes, _ = client.get_bytes(
                self._join(source_base, manifest["notes"]["path"]), max_bytes=NOTES_JSON_LIMIT
            )
            if len(notes_bytes) != int(manifest["notes"]["size"]) or sha256_bytes(notes_bytes) != manifest["notes"]["sha256"]:
                raise ProtocolError("云端备注对象校验失败")
            notes_document = self._parse_notes(notes_bytes, device_id, source_type)
            context.update(stage="同步图片")
            image_changed = self._download_image_sidecar(
                context,
                client,
                settings,
                source_id,
                device_id,
                source_type,
                task_staging,
            )
            index_root = self._index_root(source_id)
            if (
                not chat_changed
                and not image_changed
                and notes_changed
                and index_root.is_dir()
                and not index_root.is_symlink()
            ):
                metadata_staging = task_staging / "cache-metadata-commit"
                try:
                    self._stage_notes_cache_update(
                        context,
                        cache_root,
                        metadata_staging,
                        manifest,
                        manifest_bytes,
                        pointer,
                        notes_document,
                    )
                except (OSError, LocalRecoveryError):
                    pass
                else:
                    context.update(stage="替换缓存", can_cancel=False)
                    self._commit_local_replacement(
                        settings,
                        source_id,
                        kind="cache-metadata",
                        cache_staging=metadata_staging,
                        pointer=pointer,
                    )
                    return
            if (
                not chat_changed
                and not image_changed
                and not notes_changed
                and self._index_root(source_id).is_dir()
            ):
                return

            object_digests = sorted(referenced_object_digests(manifest))
            object_sizes = self._object_sizes(manifest)
            journal_objects = cache_root / "journal" / "objects"
            reusable_digests: set[str] = set()
            for digest in object_digests:
                self._webdav_checkpoint(context)
                target = journal_objects / digest[:2] / f"{digest}.bin"
                try:
                    reusable = target.is_file() and target.stat().st_size == object_sizes[digest]
                except OSError:
                    reusable = False
                if reusable and sha256_file(target, checkpoint=lambda: self._webdav_checkpoint(context)) == digest:
                    reusable_digests.add(digest)
            estimate = self._estimate_download_space(
                logical_bytes=int(manifest["logicalBytes"]),
                object_sizes=object_sizes,
                reusable_digests=reusable_digests,
                existing_index_bytes=_directory_size(self._index_root(source_id)),
            )
            self._ensure_download_space(estimate["requiredBytes"], "下载前")
            context.update(
                stage="下载对象",
                files_total=len(object_digests),
                files_done=0,
                bytes_total=sum(object_sizes.values()),
                bytes_done=0,
            )
            objects: dict[str, Path] = {}
            bytes_done = 0
            for index, digest in enumerate(object_digests):
                self._webdav_checkpoint(context)
                target = journal_objects / digest[:2] / f"{digest}.bin"
                reusable = digest in reusable_digests
                if not reusable:
                    download_target = task_staging / "objects" / digest[:2] / f"{digest}.bin"
                    client.download(
                        self._join(source_base, "objects", digest[:2], f"{digest}.bin"),
                        download_target,
                        max_bytes=object_sizes[digest],
                    )
                    if (
                        download_target.stat().st_size != object_sizes[digest]
                        or sha256_file(download_target, checkpoint=lambda: self._webdav_checkpoint(context)) != digest
                    ):
                        raise ProtocolError(f"云端对象校验失败：{digest}")
                    target = download_target
                objects[digest] = target
                bytes_done += target.stat().st_size
                context.update(files_done=index + 1, bytes_done=bytes_done)

            self._webdav_checkpoint(context)
            context.update(stage="重组")
            raw_staging = task_staging / "raw"
            origin_map = materialize_snapshot(
                manifest,
                objects,
                raw_staging,
                checkpoint=lambda: self._webdav_checkpoint(context),
            )
            origin_map_path = task_staging / "origin-map.json"
            write_json_atomic(origin_map_path, origin_map)
            self._webdav_checkpoint(context)
            self._ensure_download_space(
                estimate["journalCopyBytes"] + estimate["indexBudgetBytes"] + estimate["safetyBytes"],
                "构建前",
            )
            context.update(stage="解析")
            index_staging = self._execute_remote_build(
                self._remote_source_descriptor(source_id),
                raw_staging,
                origin_map_path,
                task_staging / "build",
                context,
            )
            self._webdav_checkpoint(context)
            self._validate_index_output(index_staging)

            new_cache = task_staging / "cache-commit"
            new_cache.mkdir(parents=True)
            os.replace(raw_staging, new_cache / "raw")
            (new_cache / "manifest.json").write_bytes(manifest_bytes)
            (new_cache / "pointer.json").write_bytes(canonical_json_bytes(pointer))
            (new_cache / "notes.json").write_bytes(canonical_json_bytes(notes_document))
            (new_cache / "origin-map.json").write_bytes(canonical_json_bytes(origin_map))
            if object_digests:
                self._ensure_download_space(
                    estimate["journalCopyBytes"] + estimate["safetyBytes"],
                    "复制对象缓存前",
                )
                self._copy_current_journal_objects(
                    context,
                    objects,
                    object_sizes,
                    new_cache / "journal" / "objects",
                )
            self._ensure_download_space(estimate["safetyBytes"], "替换缓存前")
            context.update(stage="替换缓存", can_cancel=False)
            self._commit_local_replacement(
                settings,
                source_id,
                kind="download-commit",
                index_staging=index_staging,
                cache_staging=new_cache,
                pointer=pointer,
            )
        finally:
            self._cleanup_temporary_directory(settings, "download", context.task_id, task_staging)

    def _stage_notes_cache_update(
        self,
        context: TaskContext,
        cache_root: Path,
        destination: Path,
        manifest: dict,
        manifest_bytes: bytes,
        pointer: dict,
        notes_document: dict,
    ) -> None:
        self._require_plain_directory(cache_root, "现有云端缓存")
        self._remove_directory(destination)
        raw_source = cache_root / "raw"
        raw_destination = destination / "raw"
        raw_destination.mkdir(parents=True)
        for item in manifest.get("logicalFiles") or []:
            self._webdav_checkpoint(context)
            logical_path = str(item["logicalPath"])
            source = raw_source.joinpath(*logical_path.split("/"))
            self._require_confined_path(source, raw_source, "现有云端会话文件")
            if source.is_symlink() or not source.is_file():
                raise LocalRecoveryError("现有云端会话文件缺失")
            target = raw_destination.joinpath(*logical_path.split("/"))
            target.parent.mkdir(parents=True, exist_ok=True)
            os.link(source, target)

        origin_map = cache_root / "origin-map.json"
        if origin_map.is_symlink() or not origin_map.is_file():
            raise LocalRecoveryError("现有云端缓存缺少 origin-map.json")
        (destination / "origin-map.json").write_bytes(origin_map.read_bytes())

        for digest in sorted(self._object_sizes(manifest)):
            self._webdav_checkpoint(context)
            source = cache_root / "journal" / "objects" / digest[:2] / f"{digest}.bin"
            if source.is_symlink() or not source.is_file():
                raise LocalRecoveryError("现有云端对象缓存缺失")
            target = destination / "journal" / "objects" / digest[:2] / f"{digest}.bin"
            target.parent.mkdir(parents=True, exist_ok=True)
            os.link(source, target)

        (destination / "manifest.json").write_bytes(manifest_bytes)
        (destination / "pointer.json").write_bytes(canonical_json_bytes(pointer))
        (destination / "notes.json").write_bytes(canonical_json_bytes(notes_document))

    @staticmethod
    def _estimate_download_space(
        *,
        logical_bytes: int,
        object_sizes: dict[str, int],
        reusable_digests: set[str],
        existing_index_bytes: int,
    ) -> dict[str, int]:
        missing_object_bytes = sum(
            max(0, int(size))
            for digest, size in object_sizes.items()
            if digest not in reusable_digests
        )
        materialized_bytes = max(0, int(logical_bytes))
        journal_copy_bytes = sum(max(0, int(size)) for size in object_sizes.values())
        index_budget_bytes = max(
            DOWNLOAD_MIN_INDEX_BUDGET_BYTES,
            max(0, int(existing_index_bytes)),
            materialized_bytes * 2,
        )
        safety_bytes = DOWNLOAD_SAFETY_BYTES
        return {
            "missingObjectBytes": missing_object_bytes,
            "materializedBytes": materialized_bytes,
            "journalCopyBytes": journal_copy_bytes,
            "indexBudgetBytes": index_budget_bytes,
            "safetyBytes": safety_bytes,
            "requiredBytes": (
                missing_object_bytes
                + materialized_bytes
                + journal_copy_bytes
                + index_budget_bytes
                + safety_bytes
            ),
        }

    def _ensure_download_space(self, required_bytes: int, stage: str) -> None:
        required = max(0, int(required_bytes))
        free_space = shutil.disk_usage(self.paths.local_root.parent).free
        if free_space < required:
            raise RuntimeError(f"{stage}磁盘空间不足：需要约 {required} 字节，可用 {free_space} 字节")

    def _copy_current_journal_objects(
        self,
        context: TaskContext,
        objects: dict[str, Path],
        object_sizes: dict[str, int],
        destination: Path,
    ) -> None:
        for digest in sorted(objects):
            self._webdav_checkpoint(context)
            source = objects[digest]
            target = destination / digest[:2] / f"{digest}.bin"
            target.parent.mkdir(parents=True, exist_ok=True)
            temporary = target.with_name(f".{target.name}.{uuid.uuid4().hex}.tmp")
            copied = 0
            copied_digest = hashlib.sha256()
            try:
                with source.open("rb") as input_stream, temporary.open("wb") as output_stream:
                    while True:
                        self._webdav_checkpoint(context)
                        chunk = input_stream.read(1024 * 1024)
                        if not chunk:
                            break
                        output_stream.write(chunk)
                        copied_digest.update(chunk)
                        copied += len(chunk)
                if copied != object_sizes[digest] or copied_digest.hexdigest() != digest:
                    raise ProtocolError(f"本机对象缓存复制校验失败：{digest}")
                os.replace(temporary, target)
            finally:
                temporary.unlink(missing_ok=True)

    @staticmethod
    def _object_sizes(manifest: dict) -> dict[str, int]:
        sizes: dict[str, int] = {}
        for item in manifest.get("logicalFiles") or []:
            storage = dict(item.get("storage") or {})
            if storage.get("type") == "object":
                sizes[validate_digest(str(storage["sha256"]))] = int(storage["size"])
            elif storage.get("type") == "pack-entry":
                sizes[validate_digest(str(storage["objectSha256"]))] = int(storage["objectSize"])
            elif storage.get("type") == "chunks":
                for chunk in storage.get("chunks") or []:
                    sizes[validate_digest(str(chunk["sha256"]))] = int(chunk["size"])
        return sizes

    @staticmethod
    def _parse_notes(raw: bytes, device_id: str, source_type: str) -> dict:
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            raise ProtocolError("云端备注 JSON 无效") from error
        if isinstance(parsed, dict):
            reject_required_features(parsed, "云端备注")
        if (
            not isinstance(parsed, dict)
            or int(parsed.get("schemaVersion") or 0) != 1
            or str(parsed.get("deviceId") or "") != device_id
            or str(parsed.get("sourceType") or "") != source_type
            or not isinstance(parsed.get("notes"), dict)
        ):
            raise ProtocolError("云端备注来源或 schemaVersion 无效")
        return parsed

    @staticmethod
    def _write_bytes_atomic(path: Path, data: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
        try:
            temporary.write_bytes(data)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)

    def _remote_source_descriptor(self, source_id: str) -> dict:
        for source in self.cached_remote_sources():
            if source["id"] == source_id:
                return source
        connection_id, device_id, source_type = parse_remote_source_id(source_id)
        return {
            "id": source_id,
            "label": source_id,
            "type": REMOTE_TYPE_MAP[source_type],
            "connectionId": connection_id,
            "deviceId": device_id,
            "remoteSourceType": source_type,
            "capabilities": capabilities_for_type(REMOTE_TYPE_MAP[source_type]),
        }

    def _execute_remote_build(
        self,
        source: dict,
        raw_root: Path,
        origin_map_path: Path,
        build_root: Path,
        context: TaskContext | None,
    ) -> Path:
        if context:
            self._webdav_checkpoint(context)
        if self._remote_build_runner:
            result = self._remote_build_runner(source, raw_root, origin_map_path, build_root)
        else:
            result = self._run_remote_build(source, raw_root, origin_map_path, build_root, context)
        if context:
            self._webdav_checkpoint(context)
        return result

    @staticmethod
    def _stop_process(process: subprocess.Popen[str]) -> None:
        if process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)

    def _run_remote_build(
        self,
        source: dict,
        raw_root: Path,
        origin_map_path: Path,
        build_root: Path,
        context: TaskContext | None = None,
    ) -> Path:
        build_root.mkdir(parents=True, exist_ok=True)
        data_root = build_root / "data"
        output_path = build_root / "CodexChatIndex.html"
        command = [
            "pwsh",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(self.build_script),
            "-OutputPath",
            str(output_path),
            "-DataRoot",
            str(data_root),
            "-SourceId",
            str(source["id"]),
            "-SourceLabel",
            str(source["label"]),
            "-SourceType",
            str(source["type"]),
            "-RefreshMode",
            "Full",
            "-RemoteSourceRoot",
            str(raw_root),
            "-OriginMapPath",
            str(origin_map_path),
            "-DisableLocalPathImages",
            "-JsonSummary",
        ]
        if context is None:
            completed = subprocess.run(
                command,
                cwd=self.build_script.parent,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            return_code = completed.returncode
            stdout = completed.stdout
            stderr = completed.stderr
        else:
            process = subprocess.Popen(
                command,
                cwd=self.build_script.parent,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=getattr(subprocess, "BELOW_NORMAL_PRIORITY_CLASS", 0) if os.name == "nt" else 0,
            )
            while True:
                try:
                    stdout, stderr = process.communicate(timeout=0.1)
                    break
                except subprocess.TimeoutExpired:
                    try:
                        self._webdav_checkpoint(context)
                    except TaskCancelled:
                        self._stop_process(process)
                        raise
            return_code = int(process.returncode or 0)
            self._webdav_checkpoint(context)
        if return_code != 0:
            raise RuntimeError(stderr.strip() or stdout.strip() or "云端来源解析失败")
        index_root = data_root / "CodexChatIndex.sources" / str(source["id"])
        data_file = index_root / "CodexChatIndex.data.json"
        try:
            data = json.loads(data_file.read_text(encoding="utf-8"))
            final_details = self._index_root(str(source["id"])) / "CodexChatIndex.sessions"
            html_parent = self.build_script.parent / "temp"
            relative_root = os.path.relpath(final_details, html_parent).replace("\\", "/")
            web_root = quote(relative_root, safe="/.:_-~")
            for workspace in data.get("workspaces") or []:
                for session in workspace.get("sessions") or []:
                    detail_name = Path(str(session.get("detailHref") or "")).name
                    if not detail_name:
                        raise RuntimeError("云端来源会话缺少 detailHref")
                    session["detailHref"] = web_root.rstrip("/") + "/" + quote(detail_name, safe="._-~")
            data_file.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
        except (OSError, json.JSONDecodeError) as error:
            raise RuntimeError("云端来源构建结果无法重写详情地址") from error
        return index_root

    @staticmethod
    def _validate_index_output(index_root: Path) -> None:
        for name in ("CodexChatIndex.data.json", "CodexChatIndex.search.json", "CodexChatIndex.cache.json"):
            path = index_root / name
            if not path.is_file():
                raise RuntimeError(f"云端来源构建输出缺失：{name}")
            try:
                json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as error:
                raise RuntimeError(f"云端来源构建输出无效：{name}") from error
        if not (index_root / "CodexChatIndex.sessions").is_dir():
            raise RuntimeError("云端来源会话详情目录缺失")

    def _remember_downloaded(self, settings: dict, source_id: str, pointer: dict) -> None:
        def update(connection: dict) -> None:
            downloaded = connection.setdefault("downloaded", {})
            downloaded[source_id] = {
                "manifestRevisionId": pointer["manifestRevisionId"],
                "chatRevisionId": pointer["chatRevisionId"],
                "notesRevisionId": pointer["notesRevisionId"],
                "downloadedAt": utc_now(),
            }

        self._update_connection_state(settings, update)
        self._status_cache.pop(source_id, None)

    def load_remote_notes(self, source_id: str) -> dict:
        connection_id, device_id, source_type = parse_remote_source_id(source_id)
        settings = load_raw_settings(self.paths)
        if not settings or settings.get("connectionId") != connection_id:
            raise ValueError("云端来源不属于当前连接")
        notes_file = self._remote_source_cache_root(settings, device_id, source_type) / "notes.json"
        if not notes_file.is_file():
            return {"ok": True, "version": 1, "updatedAt": "", "notes": {}}
        document = read_json(notes_file)
        notes: dict[str, dict] = {}
        for storage_key, raw_item in dict(document.get("notes") or {}).items():
            if not isinstance(raw_item, dict):
                continue
            item = dict(raw_item)
            item["sourceId"] = source_id
            key = str(item.get("key") or str(storage_key).split("::", 1)[-1])
            item["key"] = key
            notes[key] = item
        return {"ok": True, "version": 1, "updatedAt": "", "notes": notes}

    def remote_build_inputs(self, source_id: str) -> dict[str, Path]:
        connection_id, device_id, source_type = parse_remote_source_id(source_id)
        settings = load_raw_settings(self.paths)
        if not settings or settings.get("connectionId") != connection_id:
            raise ValueError("云端来源不属于当前连接")
        cache_root = self._remote_source_cache_root(settings, device_id, source_type)
        raw_root = cache_root / "raw"
        origin_map = cache_root / "origin-map.json"
        if not raw_root.is_dir() or not origin_map.is_file():
            raise ValueError("云端来源尚未下载")
        return {"raw": raw_root, "originMap": origin_map}

    def rebuild_remote_index(self, source_id: str) -> dict:
        with self._lock:
            self._require_recovery_ready()
            self._require_idle_task()
            inputs = self.remote_build_inputs(source_id)
            connection_id, _device_id, _source_type = parse_remote_source_id(source_id)
            settings = load_raw_settings(self.paths)
            if not settings or settings.get("connectionId") != connection_id:
                raise ValueError("云端来源不属于当前连接")
            cleanup_id = str(uuid.uuid4())
            rebuild_root = self._connection_root(settings) / "tasks" / f"rebuild-{cleanup_id}"
            try:
                index_staging = self._execute_remote_build(
                    self._remote_source_descriptor(source_id),
                    inputs["raw"],
                    inputs["originMap"],
                    rebuild_root / "build",
                    None,
                )
                self._validate_index_output(index_staging)
                data = json.loads((index_staging / "CodexChatIndex.data.json").read_text(encoding="utf-8"))
                self._commit_local_replacement(
                    settings,
                    source_id,
                    kind="index-rebuild",
                    index_staging=index_staging,
                )
                self._status_cache.pop(source_id, None)
                return {
                    "mode": "Full",
                    "sourceId": source_id,
                    "sessions": int(data.get("totalSessions") or 0),
                    "workspaces": int(data.get("totalWorkspaces") or 0),
                    "archived": int(data.get("archived") or 0),
                    "imageReferences": int(data.get("imageReferences") or 0),
                }
            finally:
                self._cleanup_temporary_directory(settings, "index-rebuild", cleanup_id, rebuild_root)

    @staticmethod
    def _cache_failure(source_id: str, area: str, path: Path, error: object) -> dict:
        reason = TaskManager._sanitize_error(error)[:2048] or type(error).__name__
        return {
            "sourceId": str(source_id or ""),
            "area": str(area or "cache"),
            "path": str(path),
            "reason": reason,
        }

    @staticmethod
    def _append_cache_failure(failures: list[dict], failure: dict) -> None:
        key = tuple(str(failure.get(name) or "") for name in ("sourceId", "area", "path", "reason"))
        if not any(
            tuple(str(item.get(name) or "") for name in ("sourceId", "area", "path", "reason")) == key
            for item in failures
        ):
            failures.append(failure)

    def _cache_directory_entries(
        self,
        path: Path,
        *,
        source_ids: tuple[str, ...],
        area: str,
        failures: list[dict],
    ) -> list[Path] | None:
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            return []
        except OSError as error:
            for source_id in source_ids:
                self._append_cache_failure(failures, self._cache_failure(source_id, area, path, error))
            return None
        if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
            error = LocalRecoveryError("本机缓存路径不是普通目录")
            for source_id in source_ids:
                self._append_cache_failure(failures, self._cache_failure(source_id, area, path, error))
            return None
        try:
            return list(path.iterdir())
        except OSError as error:
            for source_id in source_ids:
                self._append_cache_failure(failures, self._cache_failure(source_id, area, path, error))
            return None

    def _connection_root_has_only_known_entries(self, connection_root: Path) -> bool:
        entries = self._cache_directory_entries(
            connection_root,
            source_ids=(connection_root.name,),
            area="cache",
            failures=[],
        )
        if entries is None:
            raise LocalRecoveryError("旧连接目录无法校验")
        allowed_root_names = {"catalog.json", "devices", "logs", "tasks", "transactions"}
        if any(entry.name not in allowed_root_names for entry in entries):
            return False
        devices_root = connection_root / "devices"
        if not self._path_exists(devices_root):
            return True
        device_entries = self._cache_directory_entries(
            devices_root,
            source_ids=(connection_root.name,),
            area="cache",
            failures=[],
        )
        if device_entries is None:
            raise LocalRecoveryError("旧连接设备缓存目录无法校验")
        for device_root in device_entries:
            try:
                device_id = safe_uuid(device_root.name)
            except ConfigError:
                return False
            source_entries = self._cache_directory_entries(
                device_root,
                source_ids=(device_id,),
                area="cache",
                failures=[],
            )
            if source_entries is None or any(entry.name not in LOCAL_SOURCE_TYPES for entry in source_entries):
                return False
        return True

    def cache_entries(
        self,
        *,
        settings: dict | None = None,
        warnings: list[dict] | None = None,
    ) -> list[dict]:
        settings = settings or load_raw_settings(self.paths)
        if not settings or not settings.get("connectionId"):
            return []
        source_ids, discovery_warnings = self._physical_cache_source_ids(settings, strict=False)
        warning_sink = warnings if warnings is not None else []
        for warning in discovery_warnings:
            self._append_cache_failure(warning_sink, warning)
        source_descriptors = {source["id"]: source for source in self.cached_remote_sources(settings)}
        entries: list[dict] = []
        for source_id in sorted(source_ids):
            _connection, device_id, source_type = parse_remote_source_id(source_id)
            cache_root = self._remote_source_cache_root(settings, device_id, source_type)
            index_root = self._index_root(source_id)
            source = source_descriptors.get(source_id)

            def measure(path: Path, area: str) -> int:
                return _directory_size(
                    path,
                    on_error=lambda failed_path, error: self._append_cache_failure(
                        warning_sink,
                        self._cache_failure(source_id, area, failed_path, error),
                    ),
                )

            entries.append(
                {
                    "sourceId": source_id,
                    "label": source["label"] if source else "设备已消失的本机缓存",
                    "bytes": measure(cache_root, "cache") + measure(index_root, "index"),
                    "downloaded": bool(source and source["downloaded"]),
                }
            )
        return entries

    def _physical_cache_source_ids(self, settings: dict, *, strict: bool = False) -> tuple[set[str], list[dict]]:
        connection_id = safe_uuid(str(settings["connectionId"]))
        source_ids: set[str] = set()
        failures: list[dict] = []
        for source in self.cached_remote_sources(settings):
            try:
                candidate_connection, _device_id, _source_type = parse_remote_source_id(str(source["id"]))
            except (ConfigError, ValueError):
                continue
            if candidate_connection == connection_id:
                source_ids.add(str(source["id"]))

        try:
            state = self._connection_state(settings)
        except ConfigError:
            state = {}
        for candidate in dict(state.get("downloaded") or {}):
            try:
                candidate_connection, device_id, source_type = parse_remote_source_id(candidate)
            except (ConfigError, ValueError):
                continue
            if candidate_connection == connection_id:
                source_ids.add(remote_source_id(candidate_connection, device_id, source_type))

        devices_root = self._connection_root(settings) / "devices"
        device_directories = self._cache_directory_entries(
            devices_root,
            source_ids=(connection_id,),
            area="cache",
            failures=failures,
        )
        if device_directories is None:
            device_directories = []
        current_device_id = safe_uuid(str(self.device.get("deviceId") or ""))
        for device_root in device_directories:
            try:
                device_id = safe_uuid(device_root.name)
            except ConfigError:
                continue
            candidate_source_ids = tuple(
                remote_source_id(connection_id, device_id, source_type)
                for source_type in sorted(LOCAL_SOURCE_TYPES)
            )
            source_directories = self._cache_directory_entries(
                device_root,
                source_ids=candidate_source_ids,
                area="cache",
                failures=failures,
            )
            if device_id == current_device_id:
                continue
            if source_directories is None:
                continue
            for source_root in source_directories:
                if source_root.name not in LOCAL_SOURCE_TYPES:
                    continue
                source_id = remote_source_id(connection_id, device_id, source_root.name)
                source_ids.add(source_id)
                self._cache_directory_entries(
                    source_root,
                    source_ids=(source_id,),
                    area="cache",
                    failures=failures,
                )

        index_directories = self._cache_directory_entries(
            self.paths.sources_root,
            source_ids=(connection_id,),
            area="index",
            failures=failures,
        )
        if index_directories is None:
            index_directories = []
        for index_root in index_directories:
            try:
                candidate_connection, device_id, source_type = parse_remote_source_id(index_root.name)
            except (ConfigError, ValueError):
                continue
            if candidate_connection == connection_id:
                source_id = remote_source_id(candidate_connection, device_id, source_type)
                source_ids.add(source_id)
                self._cache_directory_entries(
                    index_root,
                    source_ids=(source_id,),
                    area="index",
                    failures=failures,
                )
        if not strict:
            return source_ids, failures
        return source_ids, failures

    def _clear_cache_for_settings(
        self,
        settings: dict,
        source_ids: set[str] | list[str],
        *,
        discovery_failures: list[dict] | None = None,
    ) -> dict:
        connection_id = safe_uuid(str(settings.get("connectionId") or ""))
        cleared: list[str] = []
        failed: list[dict] = []
        for failure in discovery_failures or []:
            self._append_cache_failure(failed, failure)
        for candidate in sorted(set(source_ids)):
            candidate_connection, device_id, source_type = parse_remote_source_id(candidate)
            if candidate_connection != connection_id:
                raise ValueError("云端来源不属于当前连接")
            paths = (
                ("cache", self._remote_source_cache_root(settings, device_id, source_type)),
                ("index", self._index_root(candidate)),
            )
            candidate_failed = any(item.get("sourceId") == candidate for item in failed)
            for area, path in paths:
                try:
                    self._remove_directory(path)
                except (OSError, LocalRecoveryError) as error:
                    candidate_failed = True
                    self._append_cache_failure(
                        failed,
                        self._cache_failure(candidate, area, path, error),
                    )
            if not candidate_failed and not any(self._path_exists(path) for _area, path in paths):
                cleared.append(candidate)

        if cleared:
            try:
                def update(connection: dict) -> None:
                    downloaded = connection.setdefault("downloaded", {})
                    for candidate in cleared:
                        downloaded.pop(candidate, None)

                self._update_connection_state(settings, update)
            except (OSError, ConfigError) as error:
                for candidate in cleared:
                    self._append_cache_failure(
                        failed,
                        self._cache_failure(candidate, "state", self.paths.state_file, error),
                    )
                cleared = []
        self._status_cache.clear()
        cache_warnings: list[dict] = []
        cache = self.cache_entries(settings=settings, warnings=cache_warnings)
        for warning in cache_warnings:
            self._append_cache_failure(failed, warning)
        return {
            "ok": not failed,
            "cleared": cleared,
            "failed": failed,
            "cache": cache,
        }

    def clear_cache(self, source_id: str = "") -> dict:
        with self._lock:
            self._require_recovery_ready()
            self._require_idle_task()
            settings = self._settings()
            if source_id:
                selected = {source_id}
                discovery_failures: list[dict] = []
            else:
                selected, discovery_failures = self._physical_cache_source_ids(settings, strict=True)
            return self._clear_cache_for_settings(
                settings,
                selected,
                discovery_failures=discovery_failures,
            )

    def unregister(self, confirmation_name: str, *, clear_cache: bool = False) -> dict:
        with self._lock:
            self._require_recovery_ready()
            self._require_idle_task()
            settings = self._settings(require_enabled=True)
            expected = str(settings.get("deviceDisplayName") or "")
            if str(confirmation_name or "") != expected:
                raise ValueError("设备显示名确认不匹配")
            client = self._client(settings)
            client.delete(self._device_base(settings, str(self.device["deviceId"])), allow_missing=True)
            for source_type in LOCAL_SOURCE_TYPES:
                self._clear_upload_journal(settings, source_type)
            self._pointer_cache.clear()

            def update(connection: dict) -> None:
                connection["uploaded"] = {}
                connection["unregisteredAt"] = utc_now()

            self._update_connection_state(settings, update)
            cleanup = {"ok": True, "cleared": [], "failed": [], "cache": self.cache_entries()}
            if clear_cache:
                source_ids, discovery_failures = self._physical_cache_source_ids(settings, strict=True)
                cleanup = self._clear_cache_for_settings(
                    settings,
                    source_ids,
                    discovery_failures=discovery_failures,
                )
            result = {
                "ok": True,
                "remoteUnregistered": True,
                "localCacheCleanupOk": bool(cleanup["ok"]),
                "message": "当前设备已从云端注销",
                "cleared": cleanup["cleared"],
                "failed": cleanup["failed"],
                "cache": cleanup["cache"],
            }
            if not cleanup["ok"]:
                result["warning"] = "云端注销成功，但本机缓存清理失败，可以稍后再次清除本机缓存。"
            return result

    def task_state(self) -> dict:
        return self._task_manager.current()

    def cancel_task(self, task_id: str) -> dict:
        return self._task_manager.cancel(task_id)

    def _run_status_only(self, source_type: str) -> dict:
        command = [
            "pwsh",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(self.build_script),
            "-SourceId",
            source_type,
            "-SourceType",
            source_type,
            "-StatusOnly",
            "-JsonSummary",
        ]
        process = subprocess.run(command, cwd=self.build_script.parent, capture_output=True, text=True, encoding="utf-8", errors="replace")
        if process.returncode != 0:
            raise RuntimeError(process.stderr.strip() or process.stdout.strip() or "本机来源状态检查失败")
        for line in reversed(process.stdout.splitlines()):
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                return value
        raise RuntimeError("StatusOnly 未返回机器可读 JSON")

    def source_status(self, source_id: str, *, force: bool = False) -> dict:
        now = time.monotonic()
        cached = self._status_cache.get(source_id)
        if cached and not force and now - cached[0] < 60:
            return dict(cached[1])
        refresh = {"state": "unsupported", "reason": ""}
        sync = {
            "action": "none",
            "state": "disabled",
            "chatChanged": False,
            "notesChanged": False,
            "reason": "",
        }
        try:
            settings = load_raw_settings(self.paths)
            if source_id in LOCAL_SOURCE_TYPES:
                try:
                    local = self._run_status_only(source_id)
                    refresh = {
                        "state": "latest" if bool(local.get("noChange") or local.get("NoChange")) else "changed",
                        "reason": str(local.get("reason") or local.get("Reason") or ""),
                    }
                except Exception as error:
                    refresh = {"state": "error", "reason": str(error)}
                    local = {}
                sync["action"] = "upload"
                if not settings or not settings.get("enabled"):
                    sync["state"] = "disabled"
                else:
                    client = self._client(settings)
                    pointer, _etag = self._read_current_pointer(
                        client, settings, str(self.device["deviceId"]), source_id
                    )
                    uploaded = self._connection_state(settings).get("uploaded", {}).get(source_id, {})
                    signature = local.get("sourceSignature") or local.get("SourceSignature")
                    chat_changed = signature != uploaded.get("sourceSignature") or not pointer
                    notes_document = build_notes_document(str(self.device["deviceId"]), source_id, self._all_notes())
                    notes_changed = sha256_bytes(canonical_json_bytes(notes_document)) != str(
                        (pointer or {}).get("notesRevisionId") or ""
                    )
                    sync.update(
                        {
                            "state": "changed" if chat_changed or notes_changed else "latest",
                            "chatChanged": chat_changed,
                            "notesChanged": notes_changed,
                        }
                    )
            else:
                connection_id, device_id, source_type = parse_remote_source_id(source_id)
                sync["action"] = "download"
                if not settings or not settings.get("enabled") or settings.get("connectionId") != connection_id:
                    sync["state"] = "disabled"
                else:
                    pointer, _etag = self._read_current_pointer(
                        self._client(settings), settings, device_id, source_type
                    )
                    if pointer is None:
                        raise ProtocolError("云端来源尚未上传")
                    downloaded = self._connection_state(settings).get("downloaded", {}).get(source_id, {})
                    chat_changed = downloaded.get("chatRevisionId") != pointer["chatRevisionId"]
                    notes_changed = downloaded.get("notesRevisionId") != pointer["notesRevisionId"]
                    sync.update(
                        {
                            "state": "changed" if chat_changed or notes_changed else "latest",
                            "chatChanged": chat_changed,
                            "notesChanged": notes_changed,
                        }
                    )
            payload = {"ok": True, "sourceId": source_id, "refresh": refresh, "sync": sync}
        except Exception as error:
            if sync["action"] == "none":
                sync["action"] = "download" if str(source_id).startswith("webdav-") else "upload"
            sync.update({"state": "error", "reason": str(error)})
            payload = {"ok": False, "sourceId": source_id, "refresh": refresh, "sync": sync}
        self._status_cache[source_id] = (now, payload)
        return dict(payload)
