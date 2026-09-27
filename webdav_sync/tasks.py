from __future__ import annotations

import json
import os
import re
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit, urlunsplit

from .config import write_json_atomic


TERMINAL_STATUSES = {"completed", "cancelled", "error", "needs-confirmation"}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


class TaskBusyError(RuntimeError):
    def __init__(self, task: dict) -> None:
        super().__init__("已有 WebDAV 传输任务正在运行")
        self.task = task


class TaskCancelled(RuntimeError):
    pass


class TaskContext:
    _field_map = {
        "files_total": "filesTotal",
        "files_done": "filesDone",
        "bytes_total": "bytesTotal",
        "bytes_done": "bytesDone",
        "can_cancel": "canCancel",
        "error_summary": "errorSummary",
        "error_detail": "errorDetail",
        "error_reason": "errorReason",
        "error_target": "errorTarget",
        "http_status": "httpStatus",
        "retry_after": "retryAfter",
        "duration_ms": "durationMs",
    }

    def __init__(self, manager: "TaskManager", task_id: str) -> None:
        self.manager = manager
        self.task_id = task_id

    @property
    def cancel_requested(self) -> bool:
        return bool(self.manager._read_task(self.task_id).get("cancelRequested"))

    def check_cancelled(self) -> None:
        if self.cancel_requested:
            raise TaskCancelled("任务已取消")

    def update(self, **changes: object) -> dict:
        normalized = {self._field_map.get(key, key): value for key, value in changes.items()}
        return self.manager._update_task(self.task_id, normalized)


class TaskManager:
    def __init__(self, tasks_root: Path) -> None:
        self.tasks_root = Path(tasks_root)
        self.tasks_root.mkdir(parents=True, exist_ok=True)
        self.logs_root = self.tasks_root.parent / "logs"
        self.logs_root.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._threads: dict[str, threading.Thread] = {}
        self._recover_interrupted()
        self._prune_history()

    @staticmethod
    def _sanitize_target(value: object) -> str:
        text = str(value or "").strip()
        try:
            parsed = urlsplit(text)
            if parsed.scheme.casefold() in {"http", "https"} and parsed.hostname:
                host = parsed.hostname
                if ":" in host and not host.startswith("["):
                    host = f"[{host}]"
                port = f":{parsed.port}" if parsed.port else ""
                return urlunsplit((parsed.scheme.casefold(), host + port, parsed.path or "/", "", ""))[:2048]
        except ValueError:
            pass
        return re.split(r"[?#]", text, maxsplit=1)[0][:2048]

    @classmethod
    def _sanitize_error(cls, value: object) -> str:
        text = str(value or "")
        text = re.sub(r"(?i)(authorization\s*:\s*basic\s+)[A-Za-z0-9+/=]+", r"\1[REDACTED]", text)
        text = re.sub(r"(?i)(https?://)[^/@\s]+:[^/@\s]+@", r"\1[REDACTED]@", text)
        text = re.sub(
            r"(?i)\b(password|passwd|token|api[_-]?key|secret)\s*[:=]\s*[^\s,;]+",
            lambda match: match.group(1) + "=[REDACTED]",
            text,
        )
        text = re.sub(
            r"https?://[^\s]+",
            lambda match: cls._sanitize_target(match.group(0)),
            text,
            flags=re.IGNORECASE,
        )
        text = "".join(character if character in "\r\n\t" or ord(character) >= 32 else " " for character in text)
        return text[:8192]

    @classmethod
    def _error_metadata(cls, error: Exception) -> dict:
        status_value = getattr(error, "status", None)
        try:
            http_status = int(status_value) if status_value is not None else 0
        except (TypeError, ValueError):
            http_status = 0
        retry_after = cls._sanitize_error(getattr(error, "retry_after", ""))[:256]
        reason = cls._sanitize_error(getattr(error, "reason", ""))
        target = cls._sanitize_target(getattr(error, "target", ""))
        summary = cls._sanitize_error(error)[:2048]
        readable_reason = reason or summary
        if retry_after and "retry-after" not in summary.casefold():
            summary = (summary + f"；Retry-After: {retry_after}")[:2048]

        chain: list[str] = []
        current: BaseException | None = error
        seen: set[int] = set()
        while current is not None and id(current) not in seen:
            seen.add(id(current))
            chain.append(f"{type(current).__name__}: {cls._sanitize_error(current)}")
            current = current.__cause__ or current.__context__
        details = ["\nCaused by: ".join(chain)]
        if http_status:
            details.append(f"HTTP status: {http_status}")
        if retry_after:
            details.append(f"Retry-After: {retry_after}")
        if reason:
            details.append(f"Reason: {reason}")
        if target:
            details.append(f"Target: {target}")
        return {
            "error_summary": summary,
            "error_detail": cls._sanitize_error("\n".join(details)),
            "error_reason": readable_reason,
            "error_target": target,
            "http_status": http_status,
            "retry_after": retry_after,
        }

    def _record_history(self, state: dict) -> None:
        summary = {
            "taskId": state.get("taskId", ""),
            "action": state.get("action", ""),
            "sourceId": state.get("sourceId", ""),
            "stage": state.get("stage", ""),
            "status": state.get("status", ""),
            "filesTotal": int(state.get("filesTotal") or 0),
            "filesDone": int(state.get("filesDone") or 0),
            "bytesTotal": int(state.get("bytesTotal") or 0),
            "bytesDone": int(state.get("bytesDone") or 0),
            "startedAt": state.get("startedAt", ""),
            "updatedAt": state.get("updatedAt", ""),
            "errorTarget": self._sanitize_target(state.get("errorTarget", "")),
            "httpStatus": int(state.get("httpStatus") or 0),
            "durationMs": max(0, int(state.get("durationMs") or 0)),
        }
        write_json_atomic(self.logs_root / f"{state['taskId']}.json", summary)
        if summary["status"] == "error":
            last_error = dict(summary)
            last_error["errorSummary"] = self._sanitize_error(state.get("errorSummary", ""))
            last_error["errorReason"] = self._sanitize_error(state.get("errorReason", ""))
            last_error["retryAfter"] = self._sanitize_error(state.get("retryAfter", ""))[:256]
            last_error["errorDetail"] = self._sanitize_error(state.get("errorDetail", ""))[:8192]
            write_json_atomic(self.logs_root / "last-error.json", last_error)
        self._prune_history()

    def _prune_history(self) -> None:
        cutoff = time.time() - 30 * 24 * 60 * 60
        for root, pattern in ((self.tasks_root, "*.json"), (self.logs_root, "*.json")):
            files = [path for path in root.glob(pattern) if path.name != "last-error.json"]
            files.sort(key=lambda path: path.stat().st_mtime_ns, reverse=True)
            for index, path in enumerate(files):
                try:
                    if index >= 20 or path.stat().st_mtime < cutoff:
                        path.unlink(missing_ok=True)
                except OSError:
                    continue
        last_error = self.logs_root / "last-error.json"
        try:
            if last_error.is_file() and last_error.stat().st_mtime < cutoff:
                last_error.unlink(missing_ok=True)
        except OSError:
            pass

    def _task_file(self, task_id: str) -> Path:
        return self.tasks_root / f"{uuid.UUID(str(task_id))}.json"

    def _read_task(self, task_id: str) -> dict:
        path = self._task_file(task_id)
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return value if isinstance(value, dict) else {}

    def _write_task(self, state: dict) -> None:
        write_json_atomic(self._task_file(str(state["taskId"])), state)

    @staticmethod
    def _validated_persisted_task(path: Path, state: object) -> dict | None:
        if not isinstance(state, dict) or path.is_symlink() or not path.is_file():
            return None
        try:
            file_task_id = str(uuid.UUID(path.stem))
            state_task_id = str(uuid.UUID(str(state.get("taskId") or "")))
        except (ValueError, AttributeError):
            return None
        if path.stem != file_task_id or state_task_id != file_task_id:
            return None
        return state

    def _recover_interrupted(self) -> None:
        with self._lock:
            for path in self.tasks_root.glob("*.json"):
                try:
                    state = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    continue
                state = self._validated_persisted_task(path, state)
                if state is None or state.get("status") not in {"running", "cancelling"}:
                    continue
                state.update(
                    {
                        "status": "error",
                        "stage": "传输已中断",
                        "canCancel": False,
                        "errorSummary": "上次服务器进程结束，传输已中断；请手动重试",
                        "errorDetail": "InterruptedTask: 上次服务器进程结束，传输已中断；请手动重试",
                        "durationMs": max(0, int(state.get("durationMs") or 0)),
                        "updatedAt": utc_now(),
                    }
                )
                self._write_task(state)
                self._record_history(state)

    def _states(self) -> list[dict]:
        states: list[dict] = []
        for path in self.tasks_root.glob("*.json"):
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            value = self._validated_persisted_task(path, value)
            if value is not None:
                states.append(value)
        return states

    def current(self) -> dict:
        with self._lock:
            states = self._states()
            if not states:
                return {
                    "taskId": "",
                    "action": "",
                    "sourceId": "",
                    "stage": "",
                    "status": "idle",
                    "filesTotal": 0,
                    "filesDone": 0,
                    "bytesTotal": 0,
                    "bytesDone": 0,
                    "percent": 0,
                    "startedAt": "",
                    "updatedAt": "",
                    "cancelRequested": False,
                    "canCancel": False,
                    "errorSummary": "",
                    "errorDetail": "",
                    "errorReason": "",
                    "errorTarget": "",
                    "httpStatus": 0,
                    "retryAfter": "",
                    "durationMs": 0,
                }
            active = [state for state in states if state.get("status") in {"running", "cancelling"}]
            candidates = active or states
            return dict(max(candidates, key=lambda state: str(state.get("updatedAt") or state.get("startedAt") or "")))

    def _update_task(self, task_id: str, changes: dict) -> dict:
        with self._lock:
            state = self._read_task(task_id)
            if not state:
                raise ValueError("任务不存在")
            state.update(changes)
            files_total = max(0, int(state.get("filesTotal") or 0))
            files_done = max(0, int(state.get("filesDone") or 0))
            bytes_total = max(0, int(state.get("bytesTotal") or 0))
            bytes_done = max(0, int(state.get("bytesDone") or 0))
            if bytes_total:
                state["percent"] = min(100, int(bytes_done * 100 / bytes_total))
            elif files_total:
                state["percent"] = min(100, int(files_done * 100 / files_total))
            state["updatedAt"] = utc_now()
            if state.get("status") in TERMINAL_STATUSES:
                self._record_history(state)
            self._write_task(state)
            return dict(state)

    def start(self, action: str, source_id: str, runner: Callable[[TaskContext], None]) -> dict:
        if action not in {"upload", "download"}:
            raise ValueError("不支持的任务类型")
        with self._lock:
            current = self.current()
            if current.get("status") in {"running", "cancelling"}:
                raise TaskBusyError(current)
            task_id = str(uuid.uuid4())
            started = utc_now()
            state = {
                "taskId": task_id,
                "action": action,
                "sourceId": str(source_id or ""),
                "stage": "扫描" if action == "upload" else "比较清单",
                "status": "running",
                "filesTotal": 0,
                "filesDone": 0,
                "bytesTotal": 0,
                "bytesDone": 0,
                "percent": 0,
                "startedAt": started,
                "updatedAt": started,
                "cancelRequested": False,
                "canCancel": True,
                "errorSummary": "",
                "errorDetail": "",
                "errorReason": "",
                "errorTarget": "",
                "httpStatus": 0,
                "retryAfter": "",
                "durationMs": 0,
            }
            self._write_task(state)
            context = TaskContext(self, task_id)
            started_clock = time.monotonic()

            def execute() -> None:
                try:
                    runner(context)
                    context.update(
                        status="completed",
                        stage="完成",
                        percent=100,
                        can_cancel=False,
                        duration_ms=max(0, int((time.monotonic() - started_clock) * 1000)),
                    )
                except TaskCancelled:
                    context.update(
                        status="cancelled",
                        stage="已取消",
                        can_cancel=False,
                        error_summary="",
                        duration_ms=max(0, int((time.monotonic() - started_clock) * 1000)),
                    )
                except Exception as error:
                    special_status = str(getattr(error, "task_status", "") or "")
                    changes = {
                        "status": special_status if special_status in TERMINAL_STATUSES else "error",
                        "stage": str(getattr(error, "task_stage", "") or "失败"),
                        "can_cancel": False,
                        "duration_ms": max(0, int((time.monotonic() - started_clock) * 1000)),
                    }
                    changes.update(self._error_metadata(error))
                    extra = getattr(error, "task_payload", None)
                    if isinstance(extra, dict):
                        changes.update(extra)
                    context.update(**changes)
                finally:
                    with self._lock:
                        self._threads.pop(task_id, None)

            thread = threading.Thread(target=execute, name=f"YujiWebDAV-{action}-{task_id[:8]}", daemon=True)
            self._threads[task_id] = thread
            thread.start()
            return dict(state)

    def cancel(self, task_id: str) -> dict:
        with self._lock:
            state = self._read_task(task_id)
            if not state:
                raise ValueError("任务不存在")
            if state.get("status") not in {"running", "cancelling"} or not state.get("canCancel"):
                raise ValueError("当前任务不能取消")
            return self._update_task(task_id, {"cancelRequested": True, "status": "cancelling"})
