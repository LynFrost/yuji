from __future__ import annotations

import base64
import hashlib
import http.client
import io
import json
import os
import shutil
import ssl
import stat
import tempfile
import threading
import time
import unittest
import uuid
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError
from urllib.parse import unquote, urlsplit
from urllib.request import Request, urlopen

from webdav_sync.client import RedirectRejectedError, WebDAVClient, WebDAVError, WebDAVResponse
from webdav_sync.config import (
    ConfigError,
    RuntimePaths,
    derive_machine_key,
    load_public_settings,
    protect_password,
    save_settings,
    unprotect_password,
    validate_webdav_url,
)
from webdav_sync.protocol import (
    CHUNK_SIZE,
    OBJECT_THRESHOLD,
    ProtocolError,
    build_notes_document,
    canonical_json_bytes,
    chat_revision_id,
    create_snapshot,
    materialize_snapshot,
    notes_revision_id,
    validate_current_pointer,
    validate_full_manifest,
    validate_logical_path,
)
from webdav_sync.tasks import TaskBusyError, TaskCancelled, TaskManager
from webdav_sync.service import WebDAVSyncService
import webdav_sync.service as service_module
import CodexChatIndexServer as server_module


class ConfigTests(unittest.TestCase):
    def test_machine_key_is_stable_and_does_not_include_computer_name(self) -> None:
        expected = hashlib.sha256(b"machine-guid\nS-1-5-21-1000").hexdigest()[:16]
        self.assertEqual(expected, derive_machine_key("machine-guid", "S-1-5-21-1000"))
        self.assertNotEqual(
            derive_machine_key("machine-guid", "S-1-5-21-1000"),
            derive_machine_key("machine-guid", "S-1-5-21-1001"),
        )

    def test_runtime_paths_are_isolated_by_machine_key(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            first = RuntimePaths.for_identity(Path(temp), "guid-a", "sid-a")
            second = RuntimePaths.for_identity(Path(temp), "guid-b", "sid-a")
            self.assertNotEqual(first.local_root, second.local_root)
            self.assertEqual("CodexChatIndex.local", first.local_root.parent.name)
            self.assertTrue(first.sources_root.is_relative_to(first.local_root))

    def test_url_validation_requires_https_or_explicit_private_http(self) -> None:
        self.assertEqual(
            "https://dav.example.test/dav/",
            validate_webdav_url("https://dav.example.test/dav/"),
        )
        with self.assertRaises(ConfigError):
            validate_webdav_url("http://example.com/dav/")
        with self.assertRaises(ConfigError):
            validate_webdav_url("http://127.0.0.1/dav/", allow_insecure_private_http=False)
        self.assertEqual(
            "http://127.0.0.1/dav/",
            validate_webdav_url("http://127.0.0.1/dav/", allow_insecure_private_http=True),
        )

    def test_url_validation_rejects_embedded_credentials_query_and_fragment(self) -> None:
        for candidate in (
            "https://user:pass@example.test/dav/",
            "https://example.test/dav/?token=secret",
            "https://example.test/dav/#secret",
        ):
            with self.subTest(candidate=candidate), self.assertRaises(ConfigError):
                validate_webdav_url(candidate)

    def test_settings_hide_protected_password_and_rotate_connection(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            paths = RuntimePaths.for_identity(Path(temp), "guid", "sid")
            protect = lambda value: base64.b64encode(("protected:" + value).encode()).decode()
            first = save_settings(
                paths,
                {
                    "enabled": True,
                    "baseUrl": "https://dav.example.test/dav/",
                    "username": "user@example.test",
                    "password": "app-password",
                    "remoteRoot": "YujiSync",
                    "deviceDisplayName": "Desktop",
                },
                protect=protect,
            )
            raw = paths.settings_file.read_text(encoding="utf-8")
            self.assertNotIn("app-password", raw)
            self.assertNotIn("protectedPassword", json.dumps(load_public_settings(paths)))
            self.assertTrue(load_public_settings(paths)["passwordSaved"])

            renamed = save_settings(
                paths,
                {
                    "enabled": True,
                    "baseUrl": "https://dav.example.test/dav/",
                    "username": "user@example.test",
                    "password": "",
                    "remoteRoot": "YujiSync",
                    "deviceDisplayName": "Renamed",
                },
                protect=protect,
            )
            self.assertEqual(first["connectionId"], renamed["connectionId"])

            with self.assertRaises(ConfigError):
                save_settings(
                    paths,
                    {
                        "enabled": True,
                        "baseUrl": "https://dav.example.test/other/",
                        "username": "user@example.test",
                        "password": "",
                        "remoteRoot": "YujiSync",
                        "deviceDisplayName": "Renamed",
                    },
                    protect=protect,
                )

            changed = save_settings(
                paths,
                {
                    "enabled": True,
                    "baseUrl": "https://dav.example.test/other/",
                    "username": "user@example.test",
                    "password": "new-password",
                    "remoteRoot": "YujiSync",
                    "deviceDisplayName": "Renamed",
                },
                protect=protect,
            )
            self.assertNotEqual(first["connectionId"], changed["connectionId"])

    @unittest.skipUnless(os.name == "nt", "DPAPI is Windows-only")
    def test_dpapi_current_user_round_trip_does_not_contain_plaintext(self) -> None:
        secret = "temporary-test-password-\u5bc6\u7801"
        protected = protect_password(secret)
        self.assertNotIn(secret, protected)
        self.assertEqual(secret, unprotect_password(protected))


class LocalApiSecurityTests(unittest.TestCase):
    def test_mutation_requests_require_token_and_same_origin(self) -> None:
        host = "127.0.0.1:8765"
        token = "test-token"
        valid = {"X-Yuji-Session-Token": token, "Origin": "http://127.0.0.1:8765"}
        self.assertTrue(server_module.is_mutation_request_authorized(valid, host, token))
        self.assertFalse(server_module.is_mutation_request_authorized({"Origin": valid["Origin"]}, host, token))
        self.assertFalse(server_module.is_mutation_request_authorized(
            {"X-Yuji-Session-Token": token, "Origin": "http://malicious.test"}, host, token
        ))

    def test_remote_capabilities_are_enforced_server_side(self) -> None:
        remote = {
            "id": "remote",
            "type": "webdav-codex",
            "capabilities": {
                "canUpload": False,
                "canEditNotes": False,
                "canReply": False,
                "canResolveLocalImages": False,
            },
        }
        original = server_module.get_source
        server_module.get_source = lambda _source_id: remote
        try:
            with self.assertRaisesRegex(ValueError, "备注"):
                server_module.require_source_capability("remote", "canEditNotes", "云端备注只能在来源设备编辑")
            with self.assertRaisesRegex(ValueError, "图片"):
                server_module.require_source_capability("remote", "canResolveLocalImages", "云端来源不能读取本机图片")
        finally:
            server_module.get_source = original


class ProtocolTests(unittest.TestCase):
    def test_protocol_documents_reject_unknown_required_features(self) -> None:
        device_id = "11111111-1111-4111-8111-111111111111"
        pointer = {
            "schemaVersion": 1,
            "protocol": "YujiSync/v1",
            "deviceId": device_id,
            "sourceType": "local-codex",
            "manifestRevisionId": "a" * 64,
            "manifestPath": "manifests/" + "a" * 64 + ".json",
            "chatRevisionId": "b" * 64,
            "notesRevisionId": "c" * 64,
            "requiredFeatures": ["future-pointer-feature"],
        }
        with self.assertRaisesRegex(ProtocolError, "requiredFeatures"):
            validate_current_pointer(pointer, device_id=device_id, source_type="local-codex")

        device = {
            "schemaVersion": 1,
            "protocol": "YujiSync/v1",
            "deviceId": device_id,
            "displayName": "Desktop",
            "sources": ["local-codex"],
            "requiredFeatures": ["future-device-feature"],
        }
        with self.assertRaisesRegex(ProtocolError, "requiredFeatures"):
            WebDAVSyncService._validate_device_document(device, device_id)

        notes = {
            "schemaVersion": 1,
            "deviceId": device_id,
            "sourceType": "local-codex",
            "notes": {},
            "requiredFeatures": ["future-notes-feature"],
        }
        with self.assertRaisesRegex(ProtocolError, "requiredFeatures"):
            WebDAVSyncService._parse_notes(canonical_json_bytes(notes), device_id, "local-codex")

    def test_full_manifest_rejects_duplicate_logical_paths_before_materialization(self) -> None:
        logical_file = {
            "logicalPath": "sessions/duplicate.jsonl",
            "originPath": "C:/origin.jsonl",
            "size": 3,
            "sha256": hashlib.sha256(b"{}\n").hexdigest(),
            "archived": False,
            "sourceMeta": {"rootKind": "sessions", "recordFormat": "jsonl", "entrypoint": ""},
            "storage": {"type": "object", "sha256": "d" * 64, "size": 3},
        }
        notes_digest = "b" * 64
        for duplicate_path in ("sessions/duplicate.jsonl", "sessions/DUPLICATE.jsonl"):
            with self.subTest(duplicate_path=duplicate_path):
                logical_files = [
                    logical_file,
                    dict(logical_file, logicalPath=duplicate_path, originPath="C:/other.jsonl"),
                ]
                manifest = {
                    "schemaVersion": 1,
                    "protocol": "YujiSync/v1",
                    "deviceId": "11111111-1111-4111-8111-111111111111",
                    "sourceType": "local-codex",
                    "chatRevisionId": chat_revision_id(logical_files),
                    "notesRevisionId": notes_digest,
                    "logicalFileCount": len(logical_files),
                    "logicalBytes": sum(item["size"] for item in logical_files),
                    "logicalFiles": logical_files,
                    "notes": {"path": f"notes/{notes_digest}.json", "size": 0, "sha256": notes_digest},
                }

                with self.assertRaisesRegex(ProtocolError, "logicalPath"):
                    validate_full_manifest(manifest)

    def test_full_manifest_rejects_notes_path_outside_revision_object(self) -> None:
        notes_digest = "b" * 64
        manifest = {
            "schemaVersion": 1,
            "protocol": "YujiSync/v1",
            "deviceId": "11111111-1111-4111-8111-111111111111",
            "sourceType": "local-codex",
            "chatRevisionId": chat_revision_id([]),
            "notesRevisionId": notes_digest,
            "logicalFileCount": 0,
            "logicalBytes": 0,
            "logicalFiles": [],
            "notes": {
                "path": "../../../../outside.json",
                "size": 2,
                "sha256": notes_digest,
            },
        }

        with self.assertRaisesRegex(ProtocolError, "notes"):
            validate_full_manifest(manifest)

    def test_canonical_json_is_stable_utf8_without_bom_or_trailing_newline(self) -> None:
        first = canonical_json_bytes({"z": 1, "a": "中文", "nested": {"b": 2, "a": 1}})
        second = canonical_json_bytes({"nested": {"a": 1, "b": 2}, "a": "中文", "z": 1})
        self.assertEqual(first, second)
        self.assertFalse(first.startswith(b"\xef\xbb\xbf"))
        self.assertFalse(first.endswith(b"\n"))

    def test_chat_revision_ignores_mtime_and_storage_but_tracks_origin_metadata(self) -> None:
        base = {
            "logicalPath": "sessions/one.jsonl",
            "originPath": "C:/Users/Test/.codex/sessions/one.jsonl",
            "size": 12,
            "sha256": "a" * 64,
            "archived": False,
            "sourceMeta": {"rootKind": "sessions", "recordFormat": "jsonl", "entrypoint": ""},
            "storage": {"type": "object", "sha256": "b" * 64, "size": 12},
            "mtime": "ignored",
        }
        changed_storage = dict(base, storage={"type": "object", "sha256": "c" * 64, "size": 12})
        self.assertEqual(chat_revision_id([base]), chat_revision_id([changed_storage]))
        self.assertNotEqual(
            chat_revision_id([base]),
            chat_revision_id([dict(base, originPath="D:/Moved/one.jsonl")]),
        )

    def test_notes_revision_only_contains_requested_source(self) -> None:
        notes = {
            "local-codex::group:a": {"sourceId": "local-codex", "key": "group:a", "note": "A"},
            "local-claude::group:b": {"sourceId": "local-claude", "key": "group:b", "note": "B"},
        }
        document = build_notes_document("11111111-1111-4111-8111-111111111111", "local-codex", notes)
        self.assertEqual(["local-codex::group:a"], list(document["notes"]))
        first = notes_revision_id(document)
        notes["local-claude::group:b"]["note"] = "changed elsewhere"
        self.assertEqual(first, notes_revision_id(build_notes_document(document["deviceId"], "local-codex", notes)))

    def test_logical_path_validation_rejects_escape_absolute_unc_and_drive(self) -> None:
        self.assertEqual("sessions/one.jsonl", validate_logical_path("sessions/one.jsonl"))
        for path in ("", "../one", "a/../../one", "/rooted", "C:/rooted", "\\\\server\\share", "a\x00b"):
            with self.subTest(path=path), self.assertRaises(ProtocolError):
                validate_logical_path(path)

    def test_snapshot_is_repeatable_truncates_partial_jsonl_and_uses_stable_zip(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source"
            source.mkdir()
            first_file = source / "first.jsonl"
            second_file = source / "second.jsonl"
            first_file.write_bytes(b'{"one":1}\n{"partial":')
            second_file.write_bytes(b'{"two":2}\n')
            first_item = self._inventory_item(first_file, "sessions/first.jsonl")
            first_item["sizeBytes"] = len(b'{"one":1}\n')
            inventory = {
                "sourceId": "local-codex",
                "sourceType": "local-codex",
                "sourceSignature": {"files": 2},
                "scanComplete": True,
                "errors": [],
                "files": [
                    first_item,
                    self._inventory_item(second_file, "sessions/second.jsonl"),
                ],
            }
            one = create_snapshot(inventory, root / "snapshot-one")
            two = create_snapshot(inventory, root / "snapshot-two")
            self.assertEqual(one.chat_revision_id, two.chat_revision_id)
            self.assertEqual(sorted(one.objects), sorted(two.objects))
            first_entry = next(item for item in one.logical_files if item["logicalPath"].endswith("first.jsonl"))
            self.assertEqual(len(b'{"one":1}\n'), first_entry["size"])
            self.assertEqual("pack-entry", first_entry["storage"]["type"])
            for digest in one.objects:
                self.assertEqual(one.objects[digest].read_bytes(), two.objects[digest].read_bytes())

    def test_snapshot_checks_for_cancellation_inside_file_processing(self) -> None:
        class Cancelled(RuntimeError):
            pass

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source.jsonl"
            source.write_bytes(b'{"one":1}\n')
            inventory = {
                "sourceId": "local-codex",
                "sourceType": "local-codex",
                "scanComplete": True,
                "errors": [],
                "files": [self._inventory_item(source, "sessions/source.jsonl")],
            }

            with self.assertRaises(Cancelled):
                create_snapshot(
                    inventory,
                    root / "snapshot",
                    checkpoint=lambda: (_ for _ in ()).throw(Cancelled("cancel snapshot")),
                )

    def test_materialize_checks_for_cancellation_before_writing_logical_files(self) -> None:
        class Cancelled(RuntimeError):
            pass

        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            object_path = root / "object.bin"
            payload = b'{"one":1}\n'
            object_path.write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest()
            logical_file = {
                "logicalPath": "sessions/source.jsonl",
                "originPath": "C:/origin.jsonl",
                "size": len(payload),
                "sha256": digest,
                "archived": False,
                "sourceMeta": {"rootKind": "sessions", "recordFormat": "jsonl", "entrypoint": ""},
                "storage": {"type": "object", "sha256": digest, "size": len(payload)},
            }
            notes_digest = "b" * 64
            manifest = {
                "schemaVersion": 1,
                "protocol": "YujiSync/v1",
                "deviceId": "11111111-1111-4111-8111-111111111111",
                "sourceType": "local-codex",
                "chatRevisionId": chat_revision_id([logical_file]),
                "notesRevisionId": notes_digest,
                "logicalFileCount": 1,
                "logicalBytes": len(payload),
                "logicalFiles": [logical_file],
                "notes": {"path": f"notes/{notes_digest}.json", "size": 0, "sha256": notes_digest},
            }
            destination = root / "raw"

            with self.assertRaises(Cancelled):
                materialize_snapshot(
                    manifest,
                    {digest: object_path},
                    destination,
                    checkpoint=lambda: (_ for _ in ()).throw(Cancelled("cancel materialize")),
                )
            self.assertFalse(destination.exists())

    def test_one_mib_and_64_mib_boundaries_choose_object_and_chunks(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "source"
            source.mkdir()
            exact_object = source / "object.json"
            exact_chunk = source / "chunk.json"
            over_chunk = source / "over.json"
            exact_object.write_bytes(b"a" * OBJECT_THRESHOLD)
            exact_chunk.write_bytes(b"b" * CHUNK_SIZE)
            over_chunk.write_bytes(b"c" * (CHUNK_SIZE + 1))
            inventory = {
                "sourceId": "local-claude",
                "sourceType": "local-claude",
                "scanComplete": True,
                "errors": [],
                "files": [
                    self._inventory_item(exact_object, "projects/object.json", "json"),
                    self._inventory_item(exact_chunk, "projects/chunk.json", "json"),
                    self._inventory_item(over_chunk, "projects/over.json", "json"),
                ],
            }
            snapshot = create_snapshot(inventory, root / "snapshot")
            storage = {item["logicalPath"]: item["storage"] for item in snapshot.logical_files}
            self.assertEqual("object", storage["projects/object.json"]["type"])
            self.assertEqual("object", storage["projects/chunk.json"]["type"])
            self.assertEqual("chunks", storage["projects/over.json"]["type"])
            self.assertEqual([CHUNK_SIZE, 1], [part["size"] for part in storage["projects/over.json"]["chunks"]])

    def test_materialize_rejects_unlisted_zip_entries_and_preserves_destination(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            object_path = root / "object.bin"
            with zipfile.ZipFile(object_path, "w") as archive:
                archive.writestr("sessions/declared.jsonl", b"{}\n")
                archive.writestr("sessions/not-declared.jsonl", b"secret\n")
            digest = hashlib.sha256(object_path.read_bytes()).hexdigest()
            logical_sha = hashlib.sha256(b"{}\n").hexdigest()
            manifest = {
                "schemaVersion": 1,
                "protocol": "YujiSync/v1",
                "deviceId": "11111111-1111-4111-8111-111111111111",
                "sourceType": "local-codex",
                "chatRevisionId": "a" * 64,
                "notesRevisionId": "b" * 64,
                "logicalFileCount": 1,
                "logicalBytes": 3,
                "logicalFiles": [{
                    "logicalPath": "sessions/declared.jsonl",
                    "originPath": "C:/origin.jsonl",
                    "size": 3,
                    "sha256": logical_sha,
                    "archived": False,
                    "sourceMeta": {"rootKind": "sessions", "recordFormat": "jsonl", "entrypoint": ""},
                    "storage": {"type": "pack-entry", "objectSha256": digest, "objectSize": object_path.stat().st_size, "entry": "sessions/declared.jsonl"},
                }],
                "notes": {"path": "notes/" + "b" * 64 + ".json", "size": 0, "sha256": "b" * 64},
            }
            destination = root / "raw"
            with self.assertRaises(ProtocolError):
                materialize_snapshot(manifest, {digest: object_path}, destination)
            self.assertFalse(destination.exists())

    def test_materialize_rejects_oversized_zip_entry_before_opening_it(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            object_path = root / "oversized.bin"
            payload = b"x" * (256 * 1024)
            with zipfile.ZipFile(object_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("sessions/declared.jsonl", payload)
            digest = hashlib.sha256(object_path.read_bytes()).hexdigest()
            declared = b"{}\n"
            logical_file = {
                "logicalPath": "sessions/declared.jsonl",
                "originPath": "C:/origin.jsonl",
                "size": len(declared),
                "sha256": hashlib.sha256(declared).hexdigest(),
                "archived": False,
                "sourceMeta": {"rootKind": "sessions", "recordFormat": "jsonl", "entrypoint": ""},
                "storage": {
                    "type": "pack-entry",
                    "objectSha256": digest,
                    "objectSize": object_path.stat().st_size,
                    "entry": "sessions/declared.jsonl",
                },
            }
            notes_digest = "b" * 64
            manifest = {
                "schemaVersion": 1,
                "protocol": "YujiSync/v1",
                "deviceId": "11111111-1111-4111-8111-111111111111",
                "sourceType": "local-codex",
                "chatRevisionId": chat_revision_id([logical_file]),
                "notesRevisionId": notes_digest,
                "logicalFileCount": 1,
                "logicalBytes": len(declared),
                "logicalFiles": [logical_file],
                "notes": {"path": f"notes/{notes_digest}.json", "size": 0, "sha256": notes_digest},
            }
            original_open = zipfile.ZipFile.open
            opened_entries = 0

            def tracking_open(archive, *args, **kwargs):
                nonlocal opened_entries
                opened_entries += 1
                return original_open(archive, *args, **kwargs)

            zipfile.ZipFile.open = tracking_open
            try:
                with self.assertRaisesRegex(ProtocolError, "ZIP"):
                    materialize_snapshot(manifest, {digest: object_path}, root / "raw")
            finally:
                zipfile.ZipFile.open = original_open
            self.assertEqual(0, opened_entries)

    def test_materialize_rejects_zip_links_devices_and_special_file_modes(self) -> None:
        payload = b"{}\n"
        logical_path = "sessions/declared.jsonl"
        logical_sha = hashlib.sha256(payload).hexdigest()
        unsafe_modes = {
            "symlink": stat.S_IFLNK | 0o777,
            "character-device": stat.S_IFCHR | 0o600,
            "block-device": stat.S_IFBLK | 0o600,
            "fifo": stat.S_IFIFO | 0o600,
            "socket": stat.S_IFSOCK | 0o600,
            "setuid": stat.S_IFREG | stat.S_ISUID | 0o644,
        }
        for label, mode in unsafe_modes.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                object_path = root / "unsafe.zip"
                info = zipfile.ZipInfo(logical_path)
                info.create_system = 3
                info.external_attr = mode << 16
                with zipfile.ZipFile(object_path, "w") as archive:
                    archive.writestr(info, payload)
                digest = hashlib.sha256(object_path.read_bytes()).hexdigest()
                logical_file = {
                    "logicalPath": logical_path,
                    "originPath": "C:/origin.jsonl",
                    "size": len(payload),
                    "sha256": logical_sha,
                    "archived": False,
                    "sourceMeta": {"rootKind": "sessions", "recordFormat": "jsonl", "entrypoint": ""},
                    "storage": {
                        "type": "pack-entry",
                        "objectSha256": digest,
                        "objectSize": object_path.stat().st_size,
                        "entry": logical_path,
                    },
                }
                notes_digest = "b" * 64
                manifest = {
                    "schemaVersion": 1,
                    "protocol": "YujiSync/v1",
                    "deviceId": "11111111-1111-4111-8111-111111111111",
                    "sourceType": "local-codex",
                    "chatRevisionId": chat_revision_id([logical_file]),
                    "notesRevisionId": notes_digest,
                    "logicalFileCount": 1,
                    "logicalBytes": len(payload),
                    "logicalFiles": [logical_file],
                    "notes": {"path": f"notes/{notes_digest}.json", "size": 0, "sha256": notes_digest},
                }
                destination = root / "raw"
                with self.assertRaisesRegex(ProtocolError, "ZIP"):
                    materialize_snapshot(manifest, {digest: object_path}, destination)
                self.assertFalse(destination.exists())

    @staticmethod
    def _inventory_item(path: Path, logical_path: str, record_format: str = "jsonl") -> dict:
        return {
            "absolutePath": str(path),
            "logicalPath": logical_path,
            "originPath": str(path),
            "rootKind": "projects" if logical_path.startswith("projects/") else "sessions",
            "recordFormat": record_format,
            "archived": False,
            "entrypoint": "cli" if logical_path.startswith("projects/") else "",
        }


class _WebDAVHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests: list[dict] = []
    resources: dict[str, bytes] = {}
    etags: dict[str, str] = {}
    collections: set[str] = {"/"}
    delete_failures: set[str] = set()
    put_failures: set[str] = set()
    ignore_if_none_match = False
    ignore_if_match = False
    ignore_move_overwrite = False
    mkcol_existing_succeeds = False
    omit_etag = False
    mutation_lock = threading.RLock()
    lock_owner_mutation = ""
    lock_owner_mutate_after = 0
    lock_owner_gets = 0
    corrupt_pointer_after_put = False
    pointer_paths_written: set[str] = set()
    fail_probe_delete_once = False
    fail_lock_delete_once = False
    mutate_lock_after_pointer_put = False

    def _record(self, body: bytes = b"") -> None:
        self.__class__.requests.append({
            "method": self.command,
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "ifMatch": self.headers.get("If-Match", ""),
            "ifNoneMatch": self.headers.get("If-None-Match", ""),
            "destination": self.headers.get("Destination", ""),
            "overwrite": self.headers.get("Overwrite", ""),
            "body": body,
        })

    def _reply(self, status: int, body: bytes = b"", **headers: str) -> None:
        self.send_response(status)
        for name, value in headers.items():
            self.send_header(name.replace("_", "-"), value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_PUT(self) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self._record(body)
        if self.path in self.__class__.put_failures:
            self.__class__.put_failures.discard(self.path)
            self._reply(503, b"temporary pointer failure")
            return
        exists = self.path in self.__class__.resources
        if not self.__class__.ignore_if_none_match and self.headers.get("If-None-Match") == "*" and exists:
            self._reply(412, b"precondition")
            return
        if (
            not self.__class__.ignore_if_match
            and self.headers.get("If-Match")
            and self.headers.get("If-Match") != self.__class__.etags.get(self.path, "")
        ):
            self._reply(412, b"precondition")
            return
        self.__class__.resources[self.path] = body
        etag = '"' + hashlib.sha256(body).hexdigest()[:16] + '"'
        self.__class__.etags[self.path] = etag
        parent = self.path.rsplit("/", 1)[0] or "/"
        if parent in self.__class__.collections:
            self.__class__.etags[parent] = '"dir-' + hashlib.sha256(body).hexdigest()[:12] + '"'
        if (
            self.__class__.corrupt_pointer_after_put
            and self.path.endswith(("/local-codex/manifest.json", "/local-claude/manifest.json"))
            and "/staging/" not in self.path
        ):
            self.__class__.pointer_paths_written.add(self.path)
        if (
            self.__class__.mutate_lock_after_pointer_put
            and self.path.endswith(("/local-codex/manifest.json", "/local-claude/manifest.json"))
            and "/staging/" not in self.path
        ):
            self.__class__.lock_owner_mutation = "token"
            self.__class__.lock_owner_mutate_after = self.__class__.lock_owner_gets + 1
        headers = {} if self.__class__.omit_etag else {"ETag": etag}
        self._reply(204 if exists else 201, **headers)

    def do_GET(self) -> None:
        self._record()
        if self.path == "/redirect-same":
            self._reply(307, Location="/dav/item")
            return
        if self.path == "/redirect-cross":
            self._reply(307, Location="http://example.com/steal")
            return
        if self.path == "/limited":
            self._reply(429, b"slow down", Retry_After="60", Content_Type="text/plain")
            return
        if self.path == "/unavailable":
            self._reply(503, b"temporarily unavailable", Retry_After="120", Content_Type="text/plain")
            return
        if self.path not in self.__class__.resources:
            self._reply(404)
            return
        if self.path.endswith("/locks/commit/owner.json"):
            self.__class__.lock_owner_gets += 1
            if self.__class__.lock_owner_gets == self.__class__.lock_owner_mutate_after:
                if self.__class__.lock_owner_mutation == "lost":
                    self.__class__.resources.pop(self.path, None)
                    self.__class__.etags.pop(self.path, None)
                    self._reply(404)
                    return
                owner = json.loads(self.__class__.resources[self.path])
                if self.__class__.lock_owner_mutation == "token":
                    owner["lockToken"] = str(uuid.uuid4())
                elif self.__class__.lock_owner_mutation == "expired":
                    owner["leaseUntil"] = "2000-01-01T00:00:00Z"
                self.__class__.resources[self.path] = canonical_json_bytes(owner)
                self.__class__.etags[self.path] = '"mutated-owner"'
        if self.path in self.__class__.pointer_paths_written:
            self._reply(200, b'{"corrupted":true}', ETag=self.__class__.etags[self.path])
            return
        body = self.__class__.resources[self.path]
        etag = self.__class__.etags[self.path]
        if self.headers.get("If-None-Match") == etag:
            self._reply(304, ETag=etag)
            return
        headers = {"Content_Type": "application/octet-stream"}
        if not self.__class__.omit_etag:
            headers["ETag"] = etag
        self._reply(200, body, **headers)

    def do_MKCOL(self) -> None:
        self._record()
        path = self.path.rstrip("/") or "/"
        with self.__class__.mutation_lock:
            if path in self.__class__.collections:
                self._reply(200 if self.__class__.mkcol_existing_succeeds else 405)
                return
            parent = path.rsplit("/", 1)[0] or "/"
            if parent not in self.__class__.collections:
                self._reply(409, b"parent missing")
                return
            self.__class__.collections.add(path)
        self._reply(201)

    def do_MOVE(self) -> None:
        self._record()
        destination = urlsplit(self.headers.get("Destination", "")).path
        if self.path not in self.__class__.resources:
            self._reply(404)
            return
        if (
            not self.__class__.ignore_move_overwrite
            and destination in self.__class__.resources
            and self.headers.get("Overwrite") == "F"
        ):
            self._reply(412)
            return
        self.__class__.resources[destination] = self.__class__.resources.pop(self.path)
        self.__class__.etags[destination] = self.__class__.etags.pop(self.path)
        self._reply(201)

    def do_DELETE(self) -> None:
        self._record()
        path = self.path.rstrip("/") or "/"
        if self.__class__.fail_probe_delete_once and "/.yuji-probe-" in path:
            self.__class__.fail_probe_delete_once = False
            self._reply(503, b"temporary probe cleanup failure")
            return
        if self.__class__.fail_lock_delete_once and path.endswith("/locks/commit"):
            self.__class__.fail_lock_delete_once = False
            self._reply(503, b"temporary lock cleanup failure")
            return
        if path in self.__class__.delete_failures:
            self.__class__.delete_failures.discard(path)
            self._reply(503, b"temporary cleanup failure")
            return
        existed = path in self.__class__.resources or path in self.__class__.collections
        for resource in list(self.__class__.resources):
            if resource == path or resource.startswith(path + "/"):
                self.__class__.resources.pop(resource, None)
                self.__class__.etags.pop(resource, None)
        for collection in list(self.__class__.collections):
            if collection != "/" and (collection == path or collection.startswith(path + "/")):
                self.__class__.collections.discard(collection)
        self._reply(204 if existed else 404)

    def do_PROPFIND(self) -> None:
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self._record(body)
        path = self.path.rstrip("/") or "/"
        if path not in self.__class__.collections and path not in self.__class__.resources:
            self._reply(404)
            return
        depth = self.headers.get("Depth", "0")
        entries = [path]
        if depth == "1" and path in self.__class__.collections:
            prefix = path.rstrip("/") + "/"
            for collection in sorted(self.__class__.collections):
                if collection.startswith(prefix) and "/" not in collection[len(prefix):]:
                    entries.append(collection)
            for resource in sorted(self.__class__.resources):
                if resource.startswith(prefix) and "/" not in resource[len(prefix):]:
                    entries.append(resource)
        responses = []
        for entry in entries:
            is_collection = entry in self.__class__.collections
            resource_type = "<d:collection/>" if is_collection else ""
            etag = self.__class__.etags.get(entry, "")
            size = len(self.__class__.resources.get(entry, b""))
            href = entry + ("/" if is_collection and entry != "/" else "")
            responses.append(
                f"<d:response><d:href>{href}</d:href><d:propstat><d:prop>"
                f"<d:resourcetype>{resource_type}</d:resourcetype><d:getetag>{etag}</d:getetag>"
                f"<d:getcontentlength>{size}</d:getcontentlength></d:prop>"
                "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
            )
        payload = ('<?xml version="1.0" encoding="utf-8"?><d:multistatus xmlns:d="DAV:">' + "".join(responses) + "</d:multistatus>").encode()
        self._reply(207, payload, Content_Type="application/xml; charset=utf-8")

    def log_message(self, format: str, *args: object) -> None:
        return


class _StagingDeleteClient:
    def __init__(self, delegate: WebDAVClient) -> None:
        self.delegate = delegate
        self.fail_staging_delete = True
        self.delete_error = "password=remote-staging-secret"
        self.delete_attempts: list[str] = []
        self.staging_manifest_written = threading.Event()
        self.release_staging_manifest = threading.Event()
        self.pause_after_staging_manifest = False

    def __getattr__(self, name: str):
        return getattr(self.delegate, name)

    def put_bytes(self, path: str, data: bytes, **kwargs):
        result = self.delegate.put_bytes(path, data, **kwargs)
        if "/staging/" in "/" + str(path).strip("/") and str(path).endswith("/manifest.json"):
            self.staging_manifest_written.set()
            if self.pause_after_staging_manifest and not self.release_staging_manifest.wait(2):
                raise RuntimeError("test staging manifest release timed out")
        return result

    def delete(self, path: str, **kwargs):
        normalized = "/" + str(path).strip("/")
        if "/staging/" in normalized:
            self.delete_attempts.append(normalized)
            if self.fail_staging_delete:
                raise WebDAVError(self.delete_error)
        return self.delegate.delete(path, **kwargs)


class ClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _WebDAVHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}/"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def setUp(self) -> None:
        _WebDAVHandler.requests.clear()
        _WebDAVHandler.resources = {"/dav/item": b"old"}
        _WebDAVHandler.etags = {"/dav/item": '"etag-old"'}
        _WebDAVHandler.collections = {"/", "/dav"}
        _WebDAVHandler.ignore_if_none_match = False
        _WebDAVHandler.ignore_if_match = False
        _WebDAVHandler.ignore_move_overwrite = False
        _WebDAVHandler.mkcol_existing_succeeds = False
        _WebDAVHandler.omit_etag = False
        _WebDAVHandler.lock_owner_mutation = ""
        _WebDAVHandler.lock_owner_mutate_after = 0
        _WebDAVHandler.lock_owner_gets = 0
        _WebDAVHandler.corrupt_pointer_after_put = False
        _WebDAVHandler.pointer_paths_written = set()
        _WebDAVHandler.fail_probe_delete_once = False
        _WebDAVHandler.fail_lock_delete_once = False
        _WebDAVHandler.mutate_lock_after_pointer_put = False
        self.client = WebDAVClient(
            self.base_url,
            "user@example.test",
            "app-password",
            allow_insecure_private_http=True,
        )

    def test_client_rejects_relative_paths_that_can_escape_the_webdav_root(self) -> None:
        for path in ("../outside.json", "a/../../outside.json", "a\\outside.json", "https://example.test/outside"):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.client.url(path)

    def test_basic_auth_put_get_and_conditions(self) -> None:
        self.client.put_bytes("dav/new", b"content", if_none_match="*")
        body, etag = self.client.get_bytes("dav/new")
        self.assertEqual(b"content", body)
        self.assertTrue(etag.startswith('"') and etag.endswith('"'))
        expected = "Basic " + base64.b64encode(b"user@example.test:app-password").decode("ascii")
        self.assertTrue(all(request["authorization"] == expected for request in _WebDAVHandler.requests))
        self.assertEqual("*", _WebDAVHandler.requests[0]["ifNoneMatch"])

    def test_conditional_get_returns_cached_etag_without_body_on_304(self) -> None:
        body, etag = self.client.get_bytes("dav/item")
        self.assertEqual(b"old", body)
        unchanged, unchanged_etag = self.client.get_if_changed("dav/item", etag)
        self.assertIsNone(unchanged)
        self.assertEqual(etag, unchanged_etag)
        self.assertEqual(etag, _WebDAVHandler.requests[-1]["ifNoneMatch"])

    def test_precondition_and_rate_limit_are_normalized_without_retry(self) -> None:
        with self.assertRaises(WebDAVError) as conflict:
            self.client.put_bytes("dav/item", b"new", if_none_match="*")
        self.assertEqual(412, conflict.exception.status)
        before = len(_WebDAVHandler.requests)
        with self.assertRaises(WebDAVError) as limited:
            self.client.get_bytes("limited")
        self.assertEqual(429, limited.exception.status)
        self.assertEqual("60", limited.exception.retry_after)
        self.assertEqual(before + 1, len(_WebDAVHandler.requests))

    def test_503_retry_after_is_reported_without_automatic_retry(self) -> None:
        before = len(_WebDAVHandler.requests)
        with self.assertRaises(WebDAVError) as unavailable:
            self.client.get_bytes("unavailable")
        self.assertEqual(503, unavailable.exception.status)
        self.assertEqual("120", unavailable.exception.retry_after)
        self.assertEqual(before + 1, len(_WebDAVHandler.requests))

    def test_mkcol_accepts_existing_collection_and_rejects_missing_parent(self) -> None:
        self.client.mkcol("dav", allow_exists=True)
        with self.assertRaises(WebDAVError) as missing_parent:
            self.client.mkcol("missing/child", allow_exists=True)
        self.assertEqual(409, missing_parent.exception.status)
        self.assertNotIn("/missing/child", _WebDAVHandler.collections)

    def test_json_and_streaming_responses_enforce_explicit_size_limits(self) -> None:
        payload = b"x" * 32
        _WebDAVHandler.resources["/oversized"] = payload
        _WebDAVHandler.etags["/oversized"] = '"oversized"'
        with self.assertRaisesRegex(WebDAVError, "超过允许大小"):
            self.client.get_bytes("oversized", max_bytes=8)
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "oversized.bin"
            with self.assertRaisesRegex(WebDAVError, "超过允许大小"):
                self.client.download("oversized", target, max_bytes=8)
            self.assertFalse(target.exists())
            self.assertFalse(target.with_name("." + target.name + ".part").exists())

    def test_interrupted_short_download_never_publishes_target_or_part_file(self) -> None:
        class ShortResponse:
            status = 200
            reason = "OK"

            def __init__(self) -> None:
                self.reads = 0

            @staticmethod
            def getheaders() -> list[tuple[str, str]]:
                return []

            def read(self, _size=None) -> bytes:
                self.reads += 1
                if self.reads == 1:
                    return b"partial"
                raise http.client.IncompleteRead(b"", 10)

        class ShortConnection:
            def putrequest(self, *_args, **_kwargs) -> None:
                return

            def putheader(self, *_args, **_kwargs) -> None:
                return

            def endheaders(self) -> None:
                return

            def getresponse(self) -> ShortResponse:
                return ShortResponse()

            def close(self) -> None:
                return

        original_connection = self.client._connection
        self.client._connection = lambda _target: ShortConnection()
        try:
            with tempfile.TemporaryDirectory() as temp:
                target = Path(temp) / "short.bin"
                with self.assertRaises(WebDAVError) as interrupted:
                    self.client.download("dav/short", target, max_bytes=100)
                self.assertIsInstance(interrupted.exception.__cause__, http.client.IncompleteRead)
                self.assertFalse(target.exists())
                self.assertFalse(target.with_name("." + target.name + ".part").exists())
        finally:
            self.client._connection = original_connection

    def test_https_certificate_verification_failure_cannot_be_bypassed(self) -> None:
        client = WebDAVClient("https://example.test/dav/", "user", "password")

        class CertificateFailureConnection:
            def putrequest(self, *_args, **_kwargs) -> None:
                raise ssl.SSLCertVerificationError(1, "certificate verify failed")

            def close(self) -> None:
                return

        client._connection = lambda _target: CertificateFailureConnection()
        self.assertEqual(ssl.CERT_REQUIRED, client._ssl_context.verify_mode)
        self.assertTrue(client._ssl_context.check_hostname)
        with self.assertRaises(WebDAVError) as rejected:
            client.get_bytes("item")
        self.assertIsInstance(rejected.exception.__cause__, ssl.SSLCertVerificationError)

    def test_same_origin_redirect_keeps_auth_and_cross_origin_is_rejected(self) -> None:
        body, _ = self.client.get_bytes("redirect-same")
        self.assertEqual(b"old", body)
        self.assertEqual(2, len(_WebDAVHandler.requests))
        with self.assertRaises(RedirectRejectedError):
            self.client.get_bytes("redirect-cross")

    def test_private_http_revalidates_dns_and_pins_the_connected_address(self) -> None:
        private_answer = [(2, 1, 6, "", ("10.20.30.40", 8080))]
        public_answer = [(2, 1, 6, "", ("8.8.8.8", 8080))]
        with mock.patch(
            "webdav_sync.config.socket.getaddrinfo",
            side_effect=[private_answer, private_answer],
        ):
            client = WebDAVClient(
                "http://dav.private.test:8080/root/",
                "user",
                "password",
                allow_insecure_private_http=True,
            )
            connection = client._connection(client.url("item"))
        self.assertEqual("10.20.30.40", connection.host)

        with mock.patch(
            "webdav_sync.config.socket.getaddrinfo",
            side_effect=[private_answer, public_answer],
        ):
            rebound = WebDAVClient(
                "http://dav.private.test:8080/root/",
                "user",
                "password",
                allow_insecure_private_http=True,
            )
            with self.assertRaisesRegex(ConfigError, "私有地址"):
                rebound._connection(rebound.url("item"))

    def test_propfind_follows_750_item_pagination_without_duplicates(self) -> None:
        def page(start: int, count: int) -> bytes:
            items = []
            for index in range(start, start + count):
                items.append(
                    f"<d:response><d:href>/devices/{index}/</d:href><d:propstat><d:prop>"
                    "<d:resourcetype><d:collection/></d:resourcetype><d:getetag>\"e\"</d:getetag>"
                    "<d:getcontentlength>0</d:getcontentlength></d:prop></d:propstat></d:response>"
                )
            return ('<d:multistatus xmlns:d="DAV:">' + "".join(items) + "</d:multistatus>").encode()

        responses = [
            WebDAVResponse(207, "Multi-Status", {"x-next-page": "?page=2"}, page(0, 750)),
            WebDAVResponse(207, "Multi-Status", {}, page(750, 1)),
        ]
        original = self.client.request
        self.client.request = lambda *args, **kwargs: responses.pop(0)
        try:
            rows = self.client.propfind("devices", depth=1)
        finally:
            self.client.request = original
        self.assertEqual(751, len(rows))
        self.assertEqual(751, len({row["href"] for row in rows}))


class TaskTests(unittest.TestCase):
    def test_webdav_checkpoint_waits_for_local_build_and_then_resumes(self) -> None:
        coordinator = service_module.BuildResourceCoordinator()
        coordinator.begin_local_build()
        resumed = threading.Event()

        worker = threading.Thread(
            target=lambda: (coordinator.webdav_checkpoint(lambda: None), resumed.set()),
            daemon=True,
        )
        worker.start()
        time.sleep(0.05)
        self.assertFalse(resumed.is_set())
        coordinator.end_local_build()
        self.assertTrue(resumed.wait(1))
        worker.join(timeout=1)
    def test_terminal_status_is_published_after_history_is_written(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            manager = TaskManager(root)
            history_started = threading.Event()
            release_history = threading.Event()
            original_record_history = manager._record_history

            def blocked_record_history(state: dict) -> None:
                history_started.set()
                self.assertTrue(release_history.wait(1))
                original_record_history(state)

            manager._record_history = blocked_record_history
            task = manager.start("upload", "local-codex", lambda _context: None)
            self.assertTrue(history_started.wait(1))
            worker = manager._threads[task["taskId"]]
            task_file = root / f"{task['taskId']}.json"
            try:
                state_during_history = json.loads(task_file.read_text(encoding="utf-8"))
                self.assertEqual("running", state_during_history["status"])
            finally:
                release_history.set()
                worker.join(timeout=2)

            deadline = time.time() + 2
            while manager.current()["status"] == "running" and time.time() < deadline:
                time.sleep(0.01)
            self.assertEqual("completed", manager.current()["status"])

    def test_single_task_cancel_and_browser_reconnect(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            manager = TaskManager(Path(temp))
            started = threading.Event()

            def runner(context) -> None:
                context.update(stage="上传对象", files_total=2, files_done=0, bytes_total=10, bytes_done=0)
                started.set()
                while not context.cancel_requested:
                    time.sleep(0.01)
                context.check_cancelled()

            task = manager.start("upload", "local-codex", runner)
            self.assertTrue(started.wait(1))
            self.assertEqual(task["taskId"], manager.current()["taskId"])
            with self.assertRaises(TaskBusyError):
                manager.start("download", "remote", runner)
            manager.cancel(task["taskId"])
            deadline = time.time() + 2
            while manager.current()["status"] not in {"cancelled", "error"} and time.time() < deadline:
                time.sleep(0.01)
            self.assertEqual("cancelled", manager.current()["status"])

    def test_running_task_is_marked_interrupted_after_restart(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            task_id = str(uuid.uuid4())
            root.mkdir(parents=True, exist_ok=True)
            (root / f"{task_id}.json").write_text(json.dumps({
                "taskId": task_id,
                "action": "upload",
                "sourceId": "local-codex",
                "status": "running",
                "stage": "上传对象",
            }), encoding="utf-8")
            manager = TaskManager(root)
            state = manager.current()
            self.assertEqual("error", state["status"])
            self.assertIn("中断", state["errorSummary"])

    def test_webdav_task_error_persists_retry_duration_and_sanitized_detail(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            manager = TaskManager(Path(temp))

            def fail(_context) -> None:
                try:
                    raise RuntimeError("password=hunter2")
                except RuntimeError as cause:
                    raise WebDAVError(
                        "WebDAV GET 失败（HTTP 429）",
                        status=429,
                        reason="token=private-token",
                        retry_after="60",
                        target="https://user:pass@example.test/dav/item?token=query-secret#fragment",
                    ) from cause

            task = manager.start("download", "remote-source", fail)
            deadline = time.time() + 2
            state = manager.current()
            while state["status"] == "running" and time.time() < deadline:
                time.sleep(0.01)
                state = manager.current()

            self.assertEqual("error", state["status"])
            self.assertEqual(429, state["httpStatus"])
            self.assertEqual("60", state["retryAfter"])
            self.assertGreaterEqual(state["durationMs"], 0)
            self.assertEqual("https://example.test/dav/item", state["errorTarget"])
            self.assertIn("Retry-After: 60", state["errorSummary"])

            history = json.loads((manager.logs_root / f"{task['taskId']}.json").read_text(encoding="utf-8"))
            last_error = json.loads((manager.logs_root / "last-error.json").read_text(encoding="utf-8"))
            for field in ("errorSummary", "errorReason", "retryAfter", "errorDetail"):
                self.assertNotIn(field, history)
                self.assertIn(field, last_error)
            self.assertNotEqual(last_error["errorDetail"], last_error["errorSummary"])
            persisted = json.dumps({"state": state, "history": history, "last": last_error})
            for secret in ("hunter2", "private-token", "query-secret", "user:pass"):
                self.assertNotIn(secret, persisted)

    def test_terminal_tasks_release_worker_thread_references(self) -> None:
        outcomes = {
            "completed": lambda: None,
            "cancelled": lambda: (_ for _ in ()).throw(TaskCancelled("cancelled")),
            "error": lambda: (_ for _ in ()).throw(RuntimeError("failed")),
        }
        for expected, outcome in outcomes.items():
            with self.subTest(expected=expected), tempfile.TemporaryDirectory() as temp:
                manager = TaskManager(Path(temp))
                started = threading.Event()
                release = threading.Event()

                def runner(_context) -> None:
                    started.set()
                    self.assertTrue(release.wait(1))
                    outcome()

                task = manager.start("upload", "local-codex", runner)
                self.assertTrue(started.wait(1))
                worker = manager._threads[task["taskId"]]
                release.set()
                worker.join(timeout=2)
                self.assertFalse(worker.is_alive())
                self.assertEqual(expected, manager.current()["status"])
                self.assertNotIn(task["taskId"], manager._threads)

    def test_last_error_is_pruned_after_thirty_days(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            manager = TaskManager(Path(temp))
            last_error = manager.logs_root / "last-error.json"
            last_error.write_text('{"status":"error"}', encoding="utf-8")
            expired = time.time() - (31 * 24 * 60 * 60)
            os.utime(last_error, (expired, expired))

            manager._prune_history()

            self.assertFalse(last_error.exists())


class ServiceTransactionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), _WebDAVHandler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.base_url = f"http://127.0.0.1:{cls.server.server_port}/"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def setUp(self) -> None:
        _WebDAVHandler.requests.clear()
        _WebDAVHandler.resources = {}
        _WebDAVHandler.etags = {}
        _WebDAVHandler.collections = {"/"}
        _WebDAVHandler.delete_failures = set()
        _WebDAVHandler.put_failures = set()
        _WebDAVHandler.ignore_if_none_match = False
        _WebDAVHandler.ignore_if_match = False
        _WebDAVHandler.ignore_move_overwrite = False
        _WebDAVHandler.mkcol_existing_succeeds = False
        _WebDAVHandler.omit_etag = False
        _WebDAVHandler.lock_owner_mutation = ""
        _WebDAVHandler.lock_owner_mutate_after = 0
        _WebDAVHandler.lock_owner_gets = 0
        _WebDAVHandler.corrupt_pointer_after_put = False
        _WebDAVHandler.pointer_paths_written = set()
        _WebDAVHandler.fail_probe_delete_once = False
        _WebDAVHandler.fail_lock_delete_once = False
        _WebDAVHandler.mutate_lock_after_pointer_put = False
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source_file = self.root / "source" / "one.jsonl"
        self.source_file.parent.mkdir()
        self.source_file.write_bytes(b'{"timestamp":"2026-01-01T00:00:00Z"}\n')

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _service(self, identity: str) -> WebDAVSyncService:
        runtime = self.root / identity / "runtime"
        paths = RuntimePaths.for_identity(runtime, "guid-" + identity, "sid-" + identity)

        def inventory(source_type: str, target: Path) -> dict:
            source_files = sorted(self.source_file.parent.glob("*.jsonl"))
            return {
                "sourceId": source_type,
                "sourceType": source_type,
                "sourceSignature": [
                    {"name": path.name, "size": path.stat().st_size, "mtime": path.stat().st_mtime_ns}
                    for path in source_files
                ],
                "scanComplete": True,
                "errors": [],
                "files": [
                    {
                        "absolutePath": str(path),
                        "logicalPath": "sessions/" + path.name,
                        "originPath": "C:/Users/Source/.codex/sessions/" + path.name,
                        "sizeBytes": path.stat().st_size,
                        "rootKind": "sessions",
                        "recordFormat": "jsonl",
                        "archived": False,
                        "entrypoint": "",
                    }
                    for path in source_files
                ],
            }

        def build_remote(source: dict, raw: Path, origin_map: Path, build_root: Path) -> Path:
            target = build_root / "index"
            details = target / "CodexChatIndex.sessions"
            details.mkdir(parents=True)
            payload = {"source": source, "totalSessions": 1, "workspaces": []}
            (target / "CodexChatIndex.data.json").write_text(json.dumps(payload), encoding="utf-8")
            (target / "CodexChatIndex.search.json").write_text('{"version":1,"sessions":[]}', encoding="utf-8")
            (target / "CodexChatIndex.cache.json").write_text('{"cacheVersion":3,"files":[]}', encoding="utf-8")
            return target

        def client_factory(settings: dict) -> WebDAVClient:
            return WebDAVClient(
                settings["baseUrl"],
                settings["username"],
                settings.get("protectedPassword") or settings.get("_clearPassword") or "password",
                allow_insecure_private_http=True,
            )

        service = WebDAVSyncService(
            runtime,
            self.root / "Build-CodexChatIndex.ps1",
            paths=paths,
            client_factory=client_factory,
            password_loader=lambda settings: str(settings.get("protectedPassword") or "password"),
            password_protector=lambda password: "protected-value",
            inventory_provider=inventory,
            remote_build_runner=build_remote,
        )
        settings_payload = {
            "enabled": True,
            "baseUrl": self.base_url,
            "username": "user@example.test",
            "password": "test-only-password",
            "remoteRoot": "YujiSync",
            "deviceDisplayName": identity,
            "allowInsecurePrivateHttp": True,
        }
        service.save_settings(settings_payload)
        service.check_connection(settings_payload)
        _WebDAVHandler.requests.clear()
        return service

    @staticmethod
    def _wait(service: WebDAVSyncService) -> dict:
        deadline = time.time() + 5
        state = service.task_state()
        while state["status"] in {"running", "cancelling"} and time.time() < deadline:
            time.sleep(0.01)
            state = service.task_state()
        return state

    @staticmethod
    def _write_interrupted_service_task(
        service: WebDAVSyncService,
        action: str,
        source_id: str,
        *,
        task_id: str | None = None,
        status: str = "running",
    ) -> tuple[str, Path, Path]:
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        task_id = task_id or str(uuid.uuid4())
        tasks_root = service.paths.connection_root(settings["connectionId"]) / "tasks"
        task_root = tasks_root / task_id
        staging = task_root / "staging"
        staging.mkdir(parents=True, exist_ok=True)
        (staging / "partial.bin").write_bytes(b"partial")
        task_file = tasks_root / f"{task_id}.json"
        task_file.write_text(
            json.dumps({
                "taskId": task_id,
                "action": action,
                "sourceId": source_id,
                "status": status,
                "stage": "上传对象" if action == "upload" else "下载对象",
            }),
            encoding="utf-8",
        )
        return task_id, task_root, staging

    @staticmethod
    def _restart(service: WebDAVSyncService) -> WebDAVSyncService:
        return WebDAVSyncService(
            service.runtime_root,
            service.build_script,
            notes_file=service.notes_file,
            paths=service.paths,
            client_factory=service._client_factory,
            password_loader=service._password_loader,
            password_protector=service._password_protector,
            inventory_provider=service._inventory_provider,
            remote_build_runner=service._remote_build_runner,
            resource_coordinator=service._resource_coordinator,
        )

    @staticmethod
    def _write_valid_index(root: Path, marker: str) -> None:
        details = root / "CodexChatIndex.sessions"
        details.mkdir(parents=True)
        (root / "CodexChatIndex.data.json").write_text(
            json.dumps({"totalSessions": 1, "totalWorkspaces": 1, "workspaces": []}),
            encoding="utf-8",
        )
        (root / "CodexChatIndex.search.json").write_text(
            '{"version":1,"sessions":[]}', encoding="utf-8"
        )
        (root / "CodexChatIndex.cache.json").write_text(
            '{"cacheVersion":3,"files":[]}', encoding="utf-8"
        )
        (root / "version-marker.txt").write_text(marker, encoding="utf-8")

    @staticmethod
    def _write_valid_cache(root: Path, device_id: str, source_type: str, marker: str) -> dict:
        notes = {
            "schemaVersion": 1,
            "deviceId": device_id,
            "sourceType": source_type,
            "notes": {},
        }
        notes_bytes = canonical_json_bytes(notes)
        notes_digest = hashlib.sha256(notes_bytes).hexdigest()
        chat_digest = chat_revision_id([])
        manifest = {
            "schemaVersion": 1,
            "protocol": "YujiSync/v1",
            "deviceId": device_id,
            "sourceType": source_type,
            "chatRevisionId": chat_digest,
            "notesRevisionId": notes_digest,
            "logicalFileCount": 0,
            "logicalBytes": 0,
            "logicalFiles": [],
            "notes": {
                "path": f"notes/{notes_digest}.json",
                "size": len(notes_bytes),
                "sha256": notes_digest,
            },
        }
        manifest_bytes = canonical_json_bytes(manifest)
        manifest_digest = hashlib.sha256(manifest_bytes).hexdigest()
        pointer = {
            "schemaVersion": 1,
            "protocol": "YujiSync/v1",
            "deviceId": device_id,
            "sourceType": source_type,
            "manifestRevisionId": manifest_digest,
            "manifestPath": f"manifests/{manifest_digest}.json",
            "chatRevisionId": chat_digest,
            "notesRevisionId": notes_digest,
        }
        (root / "raw").mkdir(parents=True)
        (root / "journal" / "objects").mkdir(parents=True)
        (root / "manifest.json").write_bytes(manifest_bytes)
        (root / "pointer.json").write_bytes(canonical_json_bytes(pointer))
        (root / "notes.json").write_bytes(notes_bytes)
        (root / "origin-map.json").write_text("{}", encoding="utf-8")
        (root / "version-marker.txt").write_text(marker, encoding="utf-8")
        return pointer

    def _transaction_fixture(
        self,
        service: WebDAVSyncService,
        *,
        kind: str = "download-commit",
        phase: str = "prepared",
        had_index: bool = True,
        had_cache: bool = True,
    ) -> tuple[dict, Path, Path, Path, Path, Path]:
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        device_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        source_id = service_module.remote_source_id(settings["connectionId"], device_id, "local-codex")
        index_root = service.source_index_root(source_id)
        cache_root = service._remote_source_cache_root(settings, device_id, "local-codex")
        transaction_id = str(uuid.uuid4())
        transaction_root = service.paths.connection_root(settings["connectionId"]) / "transactions"
        transaction_root.mkdir(parents=True, exist_ok=True)
        transaction_file = transaction_root / f"{transaction_id}.json"
        index_backup = index_root.with_name(f".{index_root.name}.{transaction_id}.old")
        cache_backup = cache_root.with_name(f".{cache_root.name}.{transaction_id}.old")
        pointer = self._write_valid_cache(cache_root, device_id, "local-codex", "old-cache")
        self._write_valid_index(index_root, "old-index")
        transaction = {
            "version": 1,
            "transactionId": transaction_id,
            "connectionId": settings["connectionId"],
            "sourceId": source_id,
            "kind": kind,
            "phase": phase,
            "hadIndex": had_index,
            "hadCache": had_cache,
            "manifestRevisionId": pointer["manifestRevisionId"],
            "chatRevisionId": pointer["chatRevisionId"],
            "notesRevisionId": pointer["notesRevisionId"],
        }
        transaction_file.write_text(json.dumps(transaction), encoding="utf-8")
        return transaction, transaction_file, index_root, cache_root, index_backup, cache_backup

    @staticmethod
    def _downloaded_state(service: WebDAVSyncService, transaction: dict) -> dict:
        connection = service._state().get("connections", {}).get(transaction["connectionId"], {})
        return dict(connection.get("downloaded", {}).get(transaction["sourceId"]) or {})

    def test_prepared_download_transaction_recovers_every_interrupted_replace_stage(self) -> None:
        stages = ("before-move", "old-index", "old-both", "new-index", "new-both")
        for stage in stages:
            with self.subTest(stage=stage):
                service = self._service("Laptop-" + stage)
                transaction, transaction_file, index_root, cache_root, index_backup, cache_backup = (
                    self._transaction_fixture(service)
                )
                if stage in {"old-index", "old-both", "new-index", "new-both"}:
                    os.replace(index_root, index_backup)
                if stage in {"old-both", "new-index", "new-both"}:
                    os.replace(cache_root, cache_backup)
                if stage in {"new-index", "new-both"}:
                    self._write_valid_index(index_root, "new-index")
                if stage == "new-both":
                    self._write_valid_cache(
                        cache_root,
                        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                        "local-codex",
                        "new-cache",
                    )

                restarted = self._restart(service)

                self.assertEqual("old-index", (index_root / "version-marker.txt").read_text(encoding="utf-8"))
                self.assertEqual("old-cache", (cache_root / "version-marker.txt").read_text(encoding="utf-8"))
                self.assertFalse(transaction_file.exists())
                self.assertFalse(index_backup.exists())
                self.assertFalse(cache_backup.exists())
                self.assertFalse(restarted.get_settings().get("recoveryError"))

    def test_commit_ready_download_transaction_keeps_new_version_and_repairs_downloaded_state(self) -> None:
        service = self._service("Laptop-commit-ready")
        transaction, transaction_file, index_root, cache_root, index_backup, cache_backup = (
            self._transaction_fixture(service, phase="commit-ready")
        )
        os.replace(index_root, index_backup)
        os.replace(cache_root, cache_backup)
        self._write_valid_index(index_root, "new-index")
        self._write_valid_cache(
            cache_root,
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "local-codex",
            "new-cache",
        )
        self.assertEqual({}, self._downloaded_state(service, transaction))

        restarted = self._restart(service)

        self.assertEqual("new-index", (index_root / "version-marker.txt").read_text(encoding="utf-8"))
        self.assertEqual("new-cache", (cache_root / "version-marker.txt").read_text(encoding="utf-8"))
        downloaded = self._downloaded_state(restarted, transaction)
        self.assertEqual(transaction["manifestRevisionId"], downloaded.get("manifestRevisionId"))
        self.assertFalse(transaction_file.exists())
        self.assertFalse(index_backup.exists())
        self.assertFalse(cache_backup.exists())

    def test_first_download_prepared_transaction_removes_partial_install(self) -> None:
        service = self._service("Laptop-first-download")
        transaction, transaction_file, index_root, cache_root, index_backup, cache_backup = (
            self._transaction_fixture(service, had_index=False, had_cache=False)
        )
        shutil.rmtree(index_root)
        shutil.rmtree(cache_root)
        self._write_valid_index(index_root, "partial-new")

        restarted = self._restart(service)

        self.assertFalse(index_root.exists())
        self.assertFalse(cache_root.exists())
        self.assertFalse(transaction_file.exists())
        self.assertFalse(restarted.get_settings().get("recoveryError"))

    def test_prepared_and_commit_ready_index_rebuild_transactions_recover_correctly(self) -> None:
        for phase, expected in (("prepared", "old-index"), ("commit-ready", "new-index")):
            with self.subTest(phase=phase):
                service = self._service("Laptop-rebuild-" + phase)
                transaction, transaction_file, index_root, cache_root, index_backup, _cache_backup = (
                    self._transaction_fixture(
                        service,
                        kind="index-rebuild",
                        phase=phase,
                        had_cache=False,
                    )
                )
                os.replace(index_root, index_backup)
                self._write_valid_index(index_root, "new-index")

                restarted = self._restart(service)

                self.assertEqual(expected, (index_root / "version-marker.txt").read_text(encoding="utf-8"))
                self.assertEqual("old-cache", (cache_root / "version-marker.txt").read_text(encoding="utf-8"))
                self.assertFalse(transaction_file.exists())
                self.assertFalse(index_backup.exists())
                self.assertFalse(restarted.get_settings().get("recoveryError"))

    def test_backup_cleanup_failure_retains_transaction_and_retries_on_next_start(self) -> None:
        service = self._service("Laptop-cleanup-retry")
        transaction, transaction_file, index_root, cache_root, index_backup, cache_backup = (
            self._transaction_fixture(service, phase="commit-ready")
        )
        os.replace(index_root, index_backup)
        os.replace(cache_root, cache_backup)
        self._write_valid_index(index_root, "new-index")
        self._write_valid_cache(
            cache_root,
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "local-codex",
            "new-cache",
        )
        original_rmtree = service_module.shutil.rmtree

        def fail_backup(path, *args, **kwargs):
            if Path(path) == index_backup:
                raise PermissionError("injected locked backup")
            return original_rmtree(path, *args, **kwargs)

        service_module.shutil.rmtree = fail_backup
        try:
            first_restart = self._restart(service)
        finally:
            service_module.shutil.rmtree = original_rmtree

        self.assertTrue(transaction_file.is_file())
        self.assertTrue(index_backup.is_dir())
        self.assertIn("旧本机缓存清理失败", first_restart.get_settings().get("warning", ""))

        second_restart = self._restart(service)
        self.assertFalse(transaction_file.exists())
        self.assertFalse(index_backup.exists())
        self.assertFalse(cache_backup.exists())
        self.assertFalse(second_restart.get_settings().get("warning"))

    def test_restart_recovers_transaction_before_cleaning_interrupted_task_staging(self) -> None:
        service = self._service("Laptop-transaction-before-staging")
        transaction, transaction_file, index_root, cache_root, index_backup, cache_backup = (
            self._transaction_fixture(service)
        )
        os.replace(index_root, index_backup)
        os.replace(cache_root, cache_backup)
        task_id, task_root, staging = self._write_interrupted_service_task(
            service,
            "download",
            transaction["sourceId"],
        )

        restarted = self._restart(service)

        self.assertEqual("old-index", (index_root / "version-marker.txt").read_text(encoding="utf-8"))
        self.assertEqual("old-cache", (cache_root / "version-marker.txt").read_text(encoding="utf-8"))
        self.assertFalse(transaction_file.exists())
        self.assertFalse(index_backup.exists())
        self.assertFalse(cache_backup.exists())
        self.assertFalse(staging.exists())
        self.assertFalse(task_root.exists())
        task = restarted.task_state()
        self.assertEqual(task_id, task["taskId"])
        self.assertEqual("error", task["status"])
        self.assertEqual("传输已中断", task["stage"])

    def test_restart_cleans_interrupted_upload_and_download_staging_without_network(self) -> None:
        for action in ("upload", "download"):
            with self.subTest(action=action):
                service = self._service("Laptop-interrupted-" + action)
                settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
                source_id = action == "upload" and "local-codex" or service_module.remote_source_id(
                    settings["connectionId"],
                    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                    "local-codex",
                )
                visible_index = service.paths.sources_root / "visible-marker"
                visible_cache = service.paths.connection_root(settings["connectionId"]) / "visible-marker"
                visible_index.mkdir(parents=True)
                visible_cache.mkdir(parents=True)
                (visible_index / "keep.txt").write_text("index", encoding="utf-8")
                (visible_cache / "keep.txt").write_text("cache", encoding="utf-8")
                task_id, task_root, staging = self._write_interrupted_service_task(service, action, source_id)
                _WebDAVHandler.requests.clear()

                restarted = self._restart(service)

                self.assertFalse(staging.exists())
                self.assertFalse(task_root.exists())
                self.assertEqual("index", (visible_index / "keep.txt").read_text(encoding="utf-8"))
                self.assertEqual("cache", (visible_cache / "keep.txt").read_text(encoding="utf-8"))
                self.assertEqual([], _WebDAVHandler.requests)
                task = restarted.task_state()
                self.assertEqual(task_id, task["taskId"])
                self.assertEqual("error", task["status"])
                self.assertIn("中断", task["errorSummary"])

    def test_interrupted_staging_cleanup_failure_persists_updates_and_retries(self) -> None:
        service = self._service("Laptop-interrupted-cleanup-retry")
        task_id, task_root, staging = self._write_interrupted_service_task(service, "upload", "local-codex")
        original_rmtree = service_module.shutil.rmtree

        def fail_first(path, *args, **kwargs):
            if Path(path) == staging:
                raise PermissionError("password=first-lock")
            return original_rmtree(path, *args, **kwargs)

        with mock.patch.object(service_module.shutil, "rmtree", fail_first):
            first = self._restart(service)

        first_pending = first._connection_state(
            json.loads(first.paths.settings_file.read_text(encoding="utf-8"))
        ).get("pendingLocalCleanup", [])
        self.assertEqual(1, len(first_pending))
        self.assertEqual("upload", first_pending[0]["kind"])
        self.assertEqual(task_id, first_pending[0]["cleanupId"])
        self.assertNotIn("first-lock", json.dumps(first_pending))
        self.assertTrue(staging.exists())

        def fail_second(path, *args, **kwargs):
            if Path(path) == staging:
                raise PermissionError("second lock")
            return original_rmtree(path, *args, **kwargs)

        with mock.patch.object(service_module.shutil, "rmtree", fail_second):
            second = self._restart(first)

        second_pending = second._connection_state(
            json.loads(second.paths.settings_file.read_text(encoding="utf-8"))
        ).get("pendingLocalCleanup", [])
        self.assertEqual(1, len(second_pending))
        self.assertIn("second lock", second_pending[0]["error"])
        self.assertTrue(staging.exists())

        third = self._restart(second)
        self.assertFalse(staging.exists())
        self.assertFalse(task_root.exists())
        self.assertFalse(third._connection_state(
            json.loads(third.paths.settings_file.read_text(encoding="utf-8"))
        ).get("pendingLocalCleanup"))

    def test_interrupted_upload_retries_local_staging_when_cleanup_state_writes_fail(self) -> None:
        service = self._service("Laptop-interrupted-state-write-failure")
        task_id, task_root, staging = self._write_interrupted_service_task(
            service,
            "upload",
            "local-codex",
        )
        original_rmtree = service_module.shutil.rmtree
        original_write = service_module.write_json_atomic
        delete_attempts = 0

        def fail_staging_delete(path, *args, **kwargs):
            nonlocal delete_attempts
            if Path(path) == staging:
                delete_attempts += 1
                raise PermissionError("injected staging lock")
            return original_rmtree(path, *args, **kwargs)

        def fail_cleanup_state(path: Path, payload: dict) -> None:
            if Path(path) == service.paths.state_file:
                raise PermissionError("token=cleanup-state-secret")
            original_write(path, payload)

        with (
            mock.patch.object(service_module.shutil, "rmtree", fail_staging_delete),
            mock.patch.object(service_module, "write_json_atomic", fail_cleanup_state),
        ):
            first = self._restart(service)

        first_settings = json.loads(first.paths.settings_file.read_text(encoding="utf-8"))
        first_connection = first._connection_state(first_settings)
        self.assertEqual("error", first.task_state()["status"])
        self.assertEqual("传输已中断", first.task_state()["stage"])
        self.assertEqual(1, delete_attempts)
        self.assertTrue(staging.exists())
        self.assertFalse(first_connection.get("pendingLocalCleanup"))
        self.assertFalse(first_connection.get("pendingRemoteStagingCleanup"))
        self.assertNotIn("cleanup-state-secret", first.get_settings().get("warning", ""))

        second = self._restart(first)

        second_connection = second._connection_state(first_settings)
        self.assertFalse(staging.exists())
        self.assertFalse(task_root.exists())
        self.assertFalse(second_connection.get("pendingLocalCleanup"))
        remote_pending = second_connection.get("pendingRemoteStagingCleanup", [])
        self.assertEqual(1, len(remote_pending))
        self.assertEqual(task_id, remote_pending[0]["taskId"])

    def test_forged_interrupted_task_id_cannot_delete_outside_tasks_root(self) -> None:
        service = self._service("Laptop-forged-interrupted-task")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        tasks_root = service.paths.connection_root(settings["connectionId"]) / "tasks"
        task_file_id = str(uuid.uuid4())
        outside = service.paths.connection_root(settings["connectionId"]) / "outside"
        outside.mkdir(parents=True)
        (outside / "keep.txt").write_text("keep", encoding="utf-8")
        (tasks_root / f"{task_file_id}.json").write_text(
            json.dumps({
                "taskId": "../../outside",
                "action": "upload",
                "sourceId": "local-codex",
                "status": "running",
                "stage": "上传对象",
            }),
            encoding="utf-8",
        )

        restarted = self._restart(service)

        self.assertEqual("keep", (outside / "keep.txt").read_text(encoding="utf-8"))
        self.assertTrue(restarted.get_settings().get("warning") or restarted.get_settings().get("recoveryError"))

    def test_corrupt_or_forged_transaction_cannot_delete_outside_runtime(self) -> None:
        service = self._service("Laptop-forged")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        transactions = service.paths.connection_root(settings["connectionId"]) / "transactions"
        transactions.mkdir(parents=True, exist_ok=True)
        sentinel = self.root / "outside-runtime.txt"
        sentinel.write_text("keep", encoding="utf-8")
        transaction_id = str(uuid.uuid4())
        (transactions / f"{transaction_id}.json").write_text(json.dumps({
            "version": 1,
            "transactionId": transaction_id,
            "connectionId": settings["connectionId"],
            "sourceId": "../../../../outside-runtime.txt",
            "kind": "download-commit",
            "phase": "prepared",
            "hadIndex": True,
            "hadCache": True,
            "manifestRevisionId": "",
            "chatRevisionId": "",
            "notesRevisionId": "",
        }), encoding="utf-8")
        cleanup_id = str(uuid.uuid4())
        pending_temp = service.paths.connection_root(settings["connectionId"]) / "tasks" / cleanup_id / "staging"
        pending_temp.mkdir(parents=True)
        (pending_temp / "keep.txt").write_text("do not clean after fatal recovery", encoding="utf-8")

        def remember_pending(connection: dict) -> None:
            connection["pendingLocalCleanup"] = [{
                "kind": "download",
                "cleanupId": cleanup_id,
                "error": "previous lock",
                "lastAttemptAt": "2026-01-01T00:00:00Z",
            }]

        service._update_connection_state(settings, remember_pending)

        restarted = self._restart(service)

        self.assertEqual("keep", sentinel.read_text(encoding="utf-8"))
        self.assertTrue((pending_temp / "keep.txt").is_file())
        self.assertTrue(restarted.get_settings().get("recoveryError"))
        with self.assertRaisesRegex(Exception, "恢复"):
            restarted.clear_cache("")

    def test_corrupt_oversized_and_unknown_transaction_versions_block_mutations(self) -> None:
        cases = ("corrupt-json", "oversized", "unknown-version")
        for label in cases:
            with self.subTest(label=label):
                service = self._service("Laptop-invalid-transaction-" + label)
                settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
                transaction_id = str(uuid.uuid4())
                transaction_root = service.paths.connection_root(settings["connectionId"]) / "transactions"
                transaction_root.mkdir(parents=True, exist_ok=True)
                transaction_file = transaction_root / f"{transaction_id}.json"
                if label == "corrupt-json":
                    transaction_file.write_text("{not-json", encoding="utf-8")
                elif label == "oversized":
                    transaction_file.write_bytes(b"x" * (service_module.LOCAL_TRANSACTION_MAX_BYTES + 1))
                else:
                    source_id = service_module.remote_source_id(
                        settings["connectionId"],
                        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                        "local-codex",
                    )
                    transaction_file.write_text(json.dumps({
                        "version": 2,
                        "transactionId": transaction_id,
                        "connectionId": settings["connectionId"],
                        "sourceId": source_id,
                        "kind": "index-rebuild",
                        "phase": "prepared",
                        "hadIndex": False,
                        "hadCache": False,
                        "manifestRevisionId": "",
                        "chatRevisionId": "",
                        "notesRevisionId": "",
                    }), encoding="utf-8")

                restarted = self._restart(service)
                self.assertTrue(restarted.get_settings().get("recoveryError"))
                self.assertTrue(transaction_file.is_file())
                with self.assertRaisesRegex(Exception, "恢复"):
                    restarted.clear_cache("")

    def test_transaction_record_write_failure_leaves_old_directories_untouched(self) -> None:
        service = self._service("Laptop-transaction-write-failure")
        transaction, transaction_file, index_root, cache_root, _index_backup, _cache_backup = (
            self._transaction_fixture(service)
        )
        transaction_file.unlink()
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        staging_root = service.paths.connection_root(settings["connectionId"]) / "tasks" / "manual-commit"
        index_staging = staging_root / "index"
        cache_staging = staging_root / "cache"
        self._write_valid_index(index_staging, "new-index")
        pointer = self._write_valid_cache(
            cache_staging,
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "local-codex",
            "new-cache",
        )
        original_write = service_module.write_json_atomic

        def fail_transaction_write(path, payload):
            if Path(path).parent.name == "transactions":
                raise PermissionError("injected transaction write failure")
            return original_write(path, payload)

        service_module.write_json_atomic = fail_transaction_write
        try:
            with self.assertRaisesRegex(PermissionError, "transaction write"):
                service._commit_local_replacement(
                    settings,
                    transaction["sourceId"],
                    kind="download-commit",
                    index_staging=index_staging,
                    cache_staging=cache_staging,
                    pointer=pointer,
                )
        finally:
            service_module.write_json_atomic = original_write

        self.assertEqual("old-index", (index_root / "version-marker.txt").read_text(encoding="utf-8"))
        self.assertEqual("old-cache", (cache_root / "version-marker.txt").read_text(encoding="utf-8"))
        self.assertTrue(index_staging.is_dir())
        self.assertTrue(cache_staging.is_dir())
        self.assertEqual([], list(index_root.parent.glob(f".{index_root.name}.*.old")))
        self.assertEqual([], list(cache_root.parent.glob(f".{cache_root.name}.*.old")))

    def test_single_source_cache_failure_is_reported_and_downloaded_state_is_retained(self) -> None:
        service = self._service("Laptop-cache-failure")
        transaction, _transaction_file, index_root, cache_root, _index_backup, _cache_backup = (
            self._transaction_fixture(service)
        )
        service._remember_downloaded(
            json.loads(service.paths.settings_file.read_text(encoding="utf-8")),
            transaction["sourceId"],
            transaction,
        )
        (service.paths.connection_root(transaction["connectionId"]) / "transactions" / f"{transaction['transactionId']}.json").unlink()
        original_rmtree = service_module.shutil.rmtree

        def fail_cache(path, *args, **kwargs):
            if Path(path) == cache_root:
                raise PermissionError("password=must-not-leak")
            return original_rmtree(path, *args, **kwargs)

        service_module.shutil.rmtree = fail_cache
        try:
            result = service.clear_cache(transaction["sourceId"])
        finally:
            service_module.shutil.rmtree = original_rmtree

        self.assertFalse(result["ok"])
        self.assertEqual([], result["cleared"])
        self.assertEqual("cache", result["failed"][0]["area"])
        self.assertNotIn("must-not-leak", json.dumps(result))
        self.assertTrue(cache_root.exists())
        self.assertFalse(index_root.exists())
        self.assertTrue(self._downloaded_state(service, transaction))
        self.assertTrue(any(item["sourceId"] == transaction["sourceId"] for item in result["cache"]))

        retried = service.clear_cache(transaction["sourceId"])
        self.assertTrue(retried["ok"])
        self.assertEqual([transaction["sourceId"]], retried["cleared"])
        self.assertFalse(cache_root.exists())
        self.assertFalse(self._downloaded_state(service, transaction))
        self.assertFalse(any(item["sourceId"] == transaction["sourceId"] for item in retried["cache"]))

    def test_single_source_index_failure_is_reported_and_downloaded_state_is_retained(self) -> None:
        service = self._service("Laptop-index-failure")
        transaction, transaction_file, index_root, cache_root, _index_backup, _cache_backup = (
            self._transaction_fixture(service)
        )
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        service._remember_downloaded(settings, transaction["sourceId"], transaction)
        transaction_file.unlink()
        original_rmtree = service_module.shutil.rmtree

        def fail_index(path, *args, **kwargs):
            if Path(path) == index_root:
                raise PermissionError("injected index lock")
            return original_rmtree(path, *args, **kwargs)

        service_module.shutil.rmtree = fail_index
        try:
            result = service.clear_cache(transaction["sourceId"])
        finally:
            service_module.shutil.rmtree = original_rmtree

        self.assertFalse(result["ok"])
        self.assertEqual([], result["cleared"])
        self.assertEqual("index", result["failed"][0]["area"])
        self.assertFalse(cache_root.exists())
        self.assertTrue(index_root.exists())
        self.assertTrue(self._downloaded_state(service, transaction))

    def test_cache_delete_and_size_enumeration_failures_return_structured_results(self) -> None:
        service = self._service("Laptop-cache-delete-size-failure")
        transaction, transaction_file, index_root, cache_root, _index_backup, _cache_backup = (
            self._transaction_fixture(service)
        )
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        service._remember_downloaded(settings, transaction["sourceId"], transaction)
        transaction_file.unlink()
        original_rmtree = service_module.shutil.rmtree
        original_rglob = Path.rglob

        def fail_cache_delete(path, *args, **kwargs):
            if Path(path) == cache_root:
                raise PermissionError("password=delete-secret")
            return original_rmtree(path, *args, **kwargs)

        def fail_cache_enumeration(path: Path, pattern: str):
            if path == cache_root:
                raise PermissionError("token=enumeration-secret")
            return original_rglob(path, pattern)

        with (
            mock.patch.object(service_module.shutil, "rmtree", fail_cache_delete),
            mock.patch.object(Path, "rglob", fail_cache_enumeration),
        ):
            result = service.clear_cache(transaction["sourceId"])
            settings_result = service.get_settings()

        self.assertFalse(result["ok"])
        self.assertEqual([], result["cleared"])
        self.assertTrue(cache_root.exists())
        self.assertFalse(index_root.exists())
        self.assertTrue(self._downloaded_state(service, transaction))
        cache_failures = [
            item for item in result["failed"]
            if item["sourceId"] == transaction["sourceId"]
            and item["area"] == "cache"
            and item["path"] == str(cache_root)
        ]
        self.assertGreaterEqual(len(cache_failures), 2)
        self.assertTrue(all(set(item) == {"sourceId", "area", "path", "reason"} for item in cache_failures))
        self.assertTrue(any(item["sourceId"] == transaction["sourceId"] for item in result["cache"]))
        self.assertTrue(settings_result["ok"])
        self.assertTrue(any(
            item["sourceId"] == transaction["sourceId"]
            and item["area"] == "cache"
            and item["path"] == str(cache_root)
            for item in settings_result["cacheWarnings"]
        ))
        serialized = json.dumps({"clear": result, "settings": settings_result})
        self.assertNotIn("delete-secret", serialized)
        self.assertNotIn("enumeration-secret", serialized)

    def test_clear_all_reports_devices_root_enumeration_failure_with_exact_path(self) -> None:
        service = self._service("Laptop-devices-root-enumeration")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        devices_root = service._connection_root(settings) / "devices"
        devices_root.mkdir(parents=True, exist_ok=True)
        original_iterdir = Path.iterdir

        def fail_devices_root(path: Path):
            if path == devices_root:
                raise PermissionError("password=must-not-leak")
            return original_iterdir(path)

        with mock.patch.object(Path, "iterdir", fail_devices_root):
            result = service.clear_cache("")

        self.assertFalse(result["ok"])
        failure = next(item for item in result["failed"] if item["path"] == str(devices_root))
        self.assertEqual(settings["connectionId"], failure["sourceId"])
        self.assertEqual("cache", failure["area"])
        self.assertEqual({"sourceId", "area", "path", "reason"}, set(failure))
        self.assertNotIn("must-not-leak", json.dumps(result))

    def test_clear_all_reports_device_directory_enumeration_failure_with_exact_path(self) -> None:
        service = self._service("Laptop-device-enumeration")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        device_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        device_root = service._connection_root(settings) / "devices" / device_id
        device_root.mkdir(parents=True)
        original_iterdir = Path.iterdir

        def fail_device_root(path: Path):
            if path == device_root:
                raise PermissionError("Authorization: Basic c2VjcmV0")
            return original_iterdir(path)

        with mock.patch.object(Path, "iterdir", fail_device_root):
            result = service.clear_cache("")

        self.assertFalse(result["ok"])
        failures = [item for item in result["failed"] if item["path"] == str(device_root)]
        self.assertEqual({"local-codex", "local-claude"}, {
            service_module.parse_remote_source_id(item["sourceId"])[2] for item in failures
        })
        self.assertTrue(all(item["area"] == "cache" for item in failures))
        self.assertNotIn("c2VjcmV0", json.dumps(result))

    def test_clear_all_reports_index_root_enumeration_failure_with_exact_path(self) -> None:
        service = self._service("Laptop-index-root-enumeration")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        service.paths.sources_root.mkdir(parents=True, exist_ok=True)
        original_iterdir = Path.iterdir

        def fail_index_root(path: Path):
            if path == service.paths.sources_root:
                raise PermissionError("token=must-not-leak")
            return original_iterdir(path)

        with mock.patch.object(Path, "iterdir", fail_index_root):
            result = service.clear_cache("")

        self.assertFalse(result["ok"])
        failure = next(item for item in result["failed"] if item["path"] == str(service.paths.sources_root))
        self.assertEqual(settings["connectionId"], failure["sourceId"])
        self.assertEqual("index", failure["area"])
        self.assertNotIn("must-not-leak", json.dumps(result))

    def test_clear_all_reports_abnormal_known_cache_paths_and_ignores_unknown_names(self) -> None:
        service = self._service("Laptop-abnormal-cache-paths")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        devices_root = service._connection_root(settings) / "devices"
        broken_device_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        broken_device = devices_root / broken_device_id
        broken_device.parent.mkdir(parents=True, exist_ok=True)
        broken_device.write_text("not a directory", encoding="utf-8")
        valid_device_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        valid_device = devices_root / valid_device_id
        valid_device.mkdir()
        broken_source = valid_device / "local-codex"
        broken_source.write_text("not a directory", encoding="utf-8")
        (devices_root / "future-format").write_text("ignore", encoding="utf-8")

        result = service.clear_cache("")

        self.assertFalse(result["ok"])
        failed_paths = {item["path"] for item in result["failed"]}
        self.assertIn(str(broken_device), failed_paths)
        self.assertIn(str(broken_source), failed_paths)
        self.assertNotIn(str(devices_root / "future-format"), failed_paths)
        self.assertTrue(broken_device.exists())
        self.assertTrue(broken_source.exists())

    def test_cache_listing_tolerates_enumeration_failure_and_returns_warning(self) -> None:
        service = self._service("Laptop-cache-list-warning")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        devices_root = service._connection_root(settings) / "devices"
        devices_root.mkdir(parents=True, exist_ok=True)
        original_iterdir = Path.iterdir

        def fail_devices_root(path: Path):
            if path == devices_root:
                raise PermissionError("injected read failure")
            return original_iterdir(path)

        with mock.patch.object(Path, "iterdir", fail_devices_root):
            result = service.get_settings()

        self.assertTrue(result["ok"])
        self.assertTrue(result["cacheWarnings"])
        self.assertEqual(str(devices_root), result["cacheWarnings"][0]["path"])

    def test_downloaded_state_write_failure_is_reported_and_retry_repairs_state(self) -> None:
        service = self._service("Laptop-downloaded-state-failure")
        transaction, transaction_file, index_root, cache_root, _index_backup, _cache_backup = (
            self._transaction_fixture(service)
        )
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        service._remember_downloaded(settings, transaction["sourceId"], transaction)
        transaction_file.unlink()
        original_write = service_module.write_json_atomic

        def fail_state_write(path: Path, payload: dict) -> None:
            if Path(path) == service.paths.state_file:
                raise PermissionError("password=state-secret")
            original_write(path, payload)

        with mock.patch.object(service_module, "write_json_atomic", fail_state_write):
            result = service.clear_cache(transaction["sourceId"])

        self.assertFalse(result["ok"])
        self.assertEqual([], result["cleared"])
        self.assertFalse(index_root.exists())
        self.assertFalse(cache_root.exists())
        self.assertTrue(self._downloaded_state(service, transaction))
        self.assertEqual("state", result["failed"][0]["area"])
        self.assertEqual(str(service.paths.state_file), result["failed"][0]["path"])
        self.assertNotIn("state-secret", json.dumps(result))
        self.assertTrue(any(item["sourceId"] == transaction["sourceId"] for item in result["cache"]))

        retried = service.clear_cache(transaction["sourceId"])
        self.assertTrue(retried["ok"])
        self.assertEqual([transaction["sourceId"]], retried["cleared"])
        self.assertFalse(self._downloaded_state(service, transaction))

    def test_cache_cleanup_never_sends_remote_delete(self) -> None:
        service = self._service("Laptop-local-cache-only")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        device_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        source_id = service_module.remote_source_id(settings["connectionId"], device_id, "local-codex")
        service._remote_source_cache_root(settings, device_id, "local-codex").mkdir(parents=True)
        service.source_index_root(source_id).mkdir(parents=True)
        _WebDAVHandler.requests.clear()

        result = service.clear_cache("")

        self.assertTrue(result["ok"])
        self.assertFalse(any(request["method"] == "DELETE" for request in _WebDAVHandler.requests))

    def test_clear_all_cache_distinguishes_success_and_failure_including_orphans(self) -> None:
        service = self._service("Laptop-clear-all-partial")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        device_ids = (
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        )
        sources = []
        for device_id in device_ids:
            source_id = service_module.remote_source_id(settings["connectionId"], device_id, "local-codex")
            cache_root = service._remote_source_cache_root(settings, device_id, "local-codex")
            index_root = service.source_index_root(source_id)
            cache_root.mkdir(parents=True)
            index_root.mkdir(parents=True)
            sources.append((source_id, cache_root, index_root))
        original_rmtree = service_module.shutil.rmtree

        def fail_one(path, *args, **kwargs):
            if Path(path) == sources[1][2]:
                raise PermissionError("injected orphan index lock")
            return original_rmtree(path, *args, **kwargs)

        service_module.shutil.rmtree = fail_one
        try:
            result = service.clear_cache("")
        finally:
            service_module.shutil.rmtree = original_rmtree

        self.assertFalse(result["ok"])
        self.assertEqual([sources[0][0]], result["cleared"])
        self.assertEqual(sources[1][0], result["failed"][0]["sourceId"])
        self.assertEqual("index", result["failed"][0]["area"])
        self.assertTrue(any(item["sourceId"] == sources[1][0] for item in result["cache"]))

    def test_connection_change_succeeds_with_warning_when_old_cache_cleanup_fails(self) -> None:
        service = self._service("Laptop-change-warning")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        device_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        source_id = service_module.remote_source_id(settings["connectionId"], device_id, "local-codex")
        cache_root = service._remote_source_cache_root(settings, device_id, "local-codex")
        index_root = service.source_index_root(source_id)
        cache_root.mkdir(parents=True)
        index_root.mkdir(parents=True)
        original_rmtree = service_module.shutil.rmtree

        def fail_old_cache(path, *args, **kwargs):
            if Path(path) == cache_root:
                raise PermissionError("injected old cache lock")
            return original_rmtree(path, *args, **kwargs)

        service_module.shutil.rmtree = fail_old_cache
        try:
            result = service.save_settings({
                "enabled": True,
                "baseUrl": self.base_url,
                "username": "user@example.test",
                "password": "new-test-password",
                "remoteRoot": "YujiSyncChanged",
                "deviceDisplayName": "Laptop-change-warning",
                "allowInsecurePrivateHttp": True,
                "clearOldConnectionCache": True,
            })
        finally:
            service_module.shutil.rmtree = original_rmtree

        self.assertTrue(result["ok"])
        self.assertTrue(result["connectionChanged"])
        self.assertFalse(result["oldCacheCleanupOk"])
        self.assertIn("设置已保存", result["warning"])
        self.assertNotEqual(settings["connectionId"], result["connectionId"])
        self.assertTrue(cache_root.exists())

    def test_unregister_reports_remote_success_when_local_cleanup_fails(self) -> None:
        service = self._service("Laptop-unregister-warning")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        device_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        source_id = service_module.remote_source_id(settings["connectionId"], device_id, "local-codex")
        cache_root = service._remote_source_cache_root(settings, device_id, "local-codex")
        index_root = service.source_index_root(source_id)
        cache_root.mkdir(parents=True)
        index_root.mkdir(parents=True)
        original_rmtree = service_module.shutil.rmtree

        def fail_local(path, *args, **kwargs):
            if Path(path) == cache_root:
                raise PermissionError("injected local lock")
            return original_rmtree(path, *args, **kwargs)

        service_module.shutil.rmtree = fail_local
        try:
            result = service.unregister("Laptop-unregister-warning", clear_cache=True)
        finally:
            service_module.shutil.rmtree = original_rmtree

        self.assertTrue(result["ok"])
        self.assertTrue(result["remoteUnregistered"])
        self.assertFalse(result["localCacheCleanupOk"])
        self.assertIn("云端注销成功", result["warning"])
        self.assertTrue(cache_root.exists())

    def test_two_devices_upload_discover_download_and_clear_only_local_cache(self) -> None:
        source = self._service("Desktop")
        target = self._service("Laptop")
        source.start_upload("local-codex")
        uploaded = self._wait(source)
        self.assertEqual("completed", uploaded["status"], uploaded.get("errorSummary"))

        remote_sources = target.refresh_catalog()
        codex_sources = [item for item in remote_sources if item["remoteSourceType"] == "local-codex"]
        self.assertEqual(1, len(codex_sources))
        remote = codex_sources[0]
        self.assertTrue(remote["capabilities"]["isReadOnly"])
        self.assertFalse(remote["downloaded"])
        self.assertNotEqual(source.paths.machine_key, target.paths.machine_key)

        target.start_download(remote["id"])
        downloaded = self._wait(target)
        self.assertEqual("completed", downloaded["status"], downloaded.get("errorSummary"))
        self.assertTrue(target.source_index_root(remote["id"]).is_dir())
        self.assertTrue(next(item for item in target.cached_remote_sources() if item["id"] == remote["id"])["downloaded"])

        remote_resource_count = len(_WebDAVHandler.resources)
        target.clear_cache(remote["id"])
        self.assertEqual(remote_resource_count, len(_WebDAVHandler.resources))
        self.assertFalse(target.source_index_root(remote["id"]).exists())
        self.assertFalse(next(item for item in target.cached_remote_sources() if item["id"] == remote["id"])["downloaded"])

    def test_download_space_estimate_counts_missing_objects_materialization_and_index_budget(self) -> None:
        service = self._service("Laptop")
        mib = 1024 * 1024
        estimate = service._estimate_download_space(
            logical_bytes=100 * mib,
            object_sizes={"a" * 64: 40 * mib, "b" * 64: 60 * mib},
            reusable_digests={"a" * 64},
            existing_index_bytes=180 * mib,
        )

        self.assertEqual(60 * mib, estimate["missingObjectBytes"])
        self.assertEqual(100 * mib, estimate["materializedBytes"])
        self.assertEqual(100 * mib, estimate["journalCopyBytes"])
        self.assertGreaterEqual(estimate["indexBudgetBytes"], 180 * mib)
        self.assertGreaterEqual(estimate["safetyBytes"], 64 * mib)
        self.assertEqual(
            estimate["requiredBytes"],
            estimate["missingObjectBytes"]
            + estimate["materializedBytes"]
            + estimate["journalCopyBytes"]
            + estimate["indexBudgetBytes"]
            + estimate["safetyBytes"],
        )
        first_download = service._estimate_download_space(
            logical_bytes=100 * mib,
            object_sizes={},
            reusable_digests=set(),
            existing_index_bytes=0,
        )
        self.assertGreaterEqual(first_download["indexBudgetBytes"], 100 * mib)

    def test_disk_space_failure_at_each_download_checkpoint_preserves_old_index_and_cache(self) -> None:
        source = self._service("Desktop-disk-checkpoints")
        target = self._service("Laptop-disk-checkpoints")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        remote = next(item for item in target.refresh_catalog() if item["remoteSourceType"] == "local-codex")
        target.start_download(remote["id"])
        self.assertEqual("completed", self._wait(target)["status"])
        settings = json.loads(target.paths.settings_file.read_text(encoding="utf-8"))
        index_root = target.source_index_root(remote["id"])
        cache_root = target._remote_source_cache_root(settings, remote["deviceId"], remote["remoteSourceType"])
        (index_root / "preserve-index.txt").write_text("old-index", encoding="utf-8")
        (cache_root / "preserve-cache.txt").write_text("old-cache", encoding="utf-8")
        downloaded_before = dict(target._connection_state(settings)["downloaded"][remote["id"]])

        self.source_file.write_bytes(b'{"timestamp":"2026-01-02T00:00:00Z","changed":true}\n')
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        original_ensure = target._ensure_download_space
        for checkpoint in ("下载前", "构建前", "复制对象缓存前", "替换缓存前"):
            with self.subTest(checkpoint=checkpoint):
                def fail_checkpoint(required_bytes, stage, expected=checkpoint):
                    if stage == expected:
                        raise RuntimeError(f"{stage}磁盘空间不足：测试注入")
                    return original_ensure(required_bytes, stage)

                target._ensure_download_space = fail_checkpoint
                try:
                    target.start_download(remote["id"])
                    failed = self._wait(target)
                finally:
                    target._ensure_download_space = original_ensure
                self.assertEqual("error", failed["status"], failed)
                self.assertIn(checkpoint, failed.get("errorSummary", ""))
                self.assertEqual("old-index", (index_root / "preserve-index.txt").read_text(encoding="utf-8"))
                self.assertEqual("old-cache", (cache_root / "preserve-cache.txt").read_text(encoding="utf-8"))
                self.assertEqual(downloaded_before, target._connection_state(settings)["downloaded"][remote["id"]])

    def test_notes_only_download_replaces_notes_without_rebuilding_index(self) -> None:
        source = self._service("Desktop-notes-only-download")
        target = self._service("Laptop-notes-only-download")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        remote = next(item for item in target.refresh_catalog() if item["remoteSourceType"] == "local-codex")
        target.start_download(remote["id"])
        self.assertEqual("completed", self._wait(target)["status"])
        index_root = target.source_index_root(remote["id"])
        marker = index_root / "notes-only-preserve.txt"
        marker.write_text("keep-index", encoding="utf-8")

        source.notes_file.parent.mkdir(parents=True, exist_ok=True)
        source.notes_file.write_text(json.dumps({
            "version": 1,
            "notes": {
                "local-codex::group:test": {
                    "sourceId": "local-codex",
                    "key": "group:test",
                    "note": "updated note",
                }
            },
        }), encoding="utf-8")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])

        target._remote_build_runner = lambda *_args: (_ for _ in ()).throw(
            AssertionError("notes-only download must not rebuild index")
        )
        target.start_download(remote["id"])
        downloaded = self._wait(target)
        self.assertEqual("completed", downloaded["status"], downloaded)
        self.assertEqual("keep-index", marker.read_text(encoding="utf-8"))
        self.assertEqual("updated note", target.load_remote_notes(remote["id"])["notes"]["group:test"]["note"])
        settings = json.loads(target.paths.settings_file.read_text(encoding="utf-8"))
        cache_root = target._remote_source_cache_root(settings, remote["deviceId"], "local-codex")
        pointer = json.loads((cache_root / "pointer.json").read_text(encoding="utf-8"))
        manifest_bytes = (cache_root / "manifest.json").read_bytes()
        manifest = json.loads(manifest_bytes)
        notes_bytes = (cache_root / "notes.json").read_bytes()
        self.assertEqual(pointer["manifestRevisionId"], hashlib.sha256(manifest_bytes).hexdigest())
        self.assertEqual(pointer["notesRevisionId"], manifest["notesRevisionId"])
        self.assertEqual(manifest["notes"]["sha256"], hashlib.sha256(notes_bytes).hexdigest())

    def test_cache_metadata_transaction_recovers_without_replacing_the_index(self) -> None:
        service = self._service("Laptop-cache-metadata-recovery")
        transaction, transaction_file, index_root, cache_root, _index_backup, cache_backup = (
            self._transaction_fixture(service, kind="cache-metadata")
        )
        os.replace(cache_root, cache_backup)

        restarted = self._restart(service)

        self.assertEqual("old-index", (index_root / "version-marker.txt").read_text(encoding="utf-8"))
        self.assertEqual("old-cache", (cache_root / "version-marker.txt").read_text(encoding="utf-8"))
        self.assertFalse(transaction_file.exists())
        self.assertFalse(cache_backup.exists())
        self.assertFalse(restarted.get_settings().get("recoveryError"))

    def test_disabled_webdav_keeps_offline_cache_readable_without_remote_status_request(self) -> None:
        source = self._service("Desktop-disabled-offline")
        target = self._service("Laptop-disabled-offline")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        remote = next(item for item in target.refresh_catalog() if item["remoteSourceType"] == "local-codex")
        target.start_download(remote["id"])
        self.assertEqual("completed", self._wait(target)["status"])
        target.disable()
        _WebDAVHandler.requests.clear()

        self.assertTrue(target.source_index_root(remote["id"]).is_dir())
        self.assertTrue(target.remote_build_inputs(remote["id"])["raw"].is_dir())
        self.assertTrue(target.load_remote_notes(remote["id"])["ok"])
        status = target.source_status(remote["id"], force=True)
        self.assertEqual("disabled", status["sync"]["state"])
        self.assertEqual([], _WebDAVHandler.requests)

    def test_source_change_during_upload_remains_changed_after_upload_completes(self) -> None:
        service = self._service("Desktop-change-during-upload")
        remember_started = threading.Event()
        release_remember = threading.Event()
        original_remember = service._remember_uploaded

        def blocked_remember(settings, source_type, source_signature, pointer):
            remember_started.set()
            self.assertTrue(release_remember.wait(2))
            return original_remember(settings, source_type, source_signature, pointer)

        service._remember_uploaded = blocked_remember
        task = service.start_upload("local-codex")
        self.assertTrue(remember_started.wait(2))
        worker = service._task_manager._threads[task["taskId"]]
        try:
            self.source_file.write_bytes(b'{"timestamp":"2026-01-03T00:00:00Z","changed-after-snapshot":true}\n')
        finally:
            release_remember.set()
        worker.join(timeout=3)
        service._remember_uploaded = original_remember
        self.assertEqual("completed", service.task_state()["status"])

        service._run_status_only = lambda source_type: service._inventory_provider(
            source_type,
            self.root / "status-only.json",
        )
        status = service.source_status("local-codex", force=True)
        self.assertEqual("changed", status["sync"]["state"])
        self.assertTrue(status["sync"]["chatChanged"])

    def test_successful_download_commits_only_current_manifest_objects_to_journal(self) -> None:
        source = self._service("Desktop")
        target = self._service("Laptop")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        remote = next(item for item in target.refresh_catalog() if item["remoteSourceType"] == "local-codex")
        target.start_download(remote["id"])
        self.assertEqual("completed", self._wait(target)["status"])

        settings = json.loads(target.paths.settings_file.read_text(encoding="utf-8"))
        cache_root = target._remote_source_cache_root(
            settings,
            remote["deviceId"],
            remote["remoteSourceType"],
        )
        stale_digest = "f" * 64
        stale_object = cache_root / "journal" / "objects" / stale_digest[:2] / f"{stale_digest}.bin"
        stale_object.parent.mkdir(parents=True, exist_ok=True)
        stale_object.write_bytes(b"stale interrupted object")

        self.source_file.write_bytes(b'{"timestamp":"2026-01-02T00:00:00Z"}\n')
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        target.start_download(remote["id"])
        self.assertEqual("completed", self._wait(target)["status"])

        pointer_path = next(path for path in _WebDAVHandler.resources if path.endswith("/local-codex/manifest.json"))
        pointer = json.loads(_WebDAVHandler.resources[pointer_path])
        manifest_path = pointer_path.rsplit("/", 1)[0] + "/" + pointer["manifestPath"]
        manifest = json.loads(_WebDAVHandler.resources[manifest_path])
        expected_digests = set(target._object_sizes(manifest))
        actual_digests = {
            path.stem
            for path in (cache_root / "journal" / "objects").rglob("*.bin")
            if path.is_file()
        }
        self.assertEqual(expected_digests, actual_digests)
        self.assertFalse(stale_object.exists())

    def test_clear_all_cache_removes_orphaned_device_cache_not_present_in_catalog(self) -> None:
        service = self._service("Laptop")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        orphan_device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        orphan_source = service_module.remote_source_id(
            settings["connectionId"], orphan_device, "local-codex"
        )
        cache_root = service._remote_source_cache_root(settings, orphan_device, "local-codex")
        index_root = service.source_index_root(orphan_source)
        cache_root.mkdir(parents=True)
        index_root.mkdir(parents=True)
        (cache_root / "orphan.bin").write_bytes(b"cache")
        (index_root / "orphan.json").write_text("{}", encoding="utf-8")
        upload_journal = service._upload_journal_file(settings, "local-claude")
        upload_journal.parent.mkdir(parents=True)
        upload_journal.write_text("{}", encoding="utf-8")
        other_connection = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        other_source = service_module.remote_source_id(other_connection, orphan_device, "local-codex")
        other_cache = service.paths.connection_root(other_connection) / "devices" / orphan_device / "local-codex"
        other_index = service.paths.sources_root / other_source
        other_cache.mkdir(parents=True)
        other_index.mkdir(parents=True)
        (other_cache / "keep.bin").write_bytes(b"other connection")
        (other_index / "keep.json").write_text("{}", encoding="utf-8")

        result = service.clear_cache("")

        self.assertIn(orphan_source, result["cleared"])
        self.assertFalse(cache_root.exists())
        self.assertFalse(index_root.exists())
        self.assertTrue(upload_journal.is_file())
        self.assertTrue(other_cache.is_dir())
        self.assertTrue(other_index.is_dir())

    def test_connection_change_with_cleanup_removes_orphaned_old_connection_indexes(self) -> None:
        service = self._service("Laptop")
        old_settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        old_connection = old_settings["connectionId"]
        orphan_device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        orphan_source = service_module.remote_source_id(old_connection, orphan_device, "local-codex")
        orphan_index = service.paths.sources_root / orphan_source
        orphan_index.mkdir(parents=True)
        (orphan_index / "orphan.json").write_text("{}", encoding="utf-8")
        old_cache = service.paths.connection_root(old_connection) / "devices" / orphan_device / "local-codex"
        old_cache.mkdir(parents=True)
        (old_cache / "orphan.bin").write_bytes(b"old connection")

        changed = service.save_settings({
            "enabled": True,
            "baseUrl": self.base_url,
            "username": "user@example.test",
            "password": "new-test-password",
            "remoteRoot": "YujiSyncChanged",
            "deviceDisplayName": "Laptop",
            "allowInsecurePrivateHttp": True,
            "clearOldConnectionCache": True,
        })

        self.assertNotEqual(old_connection, changed["connectionId"])
        self.assertFalse(service.paths.connection_root(old_connection).exists())
        self.assertFalse(orphan_index.exists())

    def test_unchanged_device_catalog_reuses_cached_device_json_by_directory_etag(self) -> None:
        source = self._service("Desktop")
        target = self._service("Laptop")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        self.assertEqual(2, len(target.refresh_catalog()))

        _WebDAVHandler.requests.clear()
        self.assertEqual(2, len(target.refresh_catalog()))
        device_gets = [
            request for request in _WebDAVHandler.requests
            if request["method"] == "GET" and request["path"].endswith("/device.json")
        ]
        self.assertEqual([], device_gets)

    def test_repeated_source_status_conditionally_reads_only_the_current_pointer(self) -> None:
        source = self._service("Desktop")
        target = self._service("Laptop")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        remote = next(item for item in target.refresh_catalog() if item["remoteSourceType"] == "local-codex")

        first = target.source_status(remote["id"], force=True)
        self.assertTrue(first["ok"], first)
        _WebDAVHandler.requests.clear()
        second = target.source_status(remote["id"], force=True)
        self.assertTrue(second["ok"], second)

        pointer_gets = [
            request for request in _WebDAVHandler.requests
            if request["method"] == "GET" and request["path"].endswith("/manifest.json")
        ]
        immutable_manifest_gets = [
            request for request in _WebDAVHandler.requests
            if request["method"] == "GET" and "/manifests/" in request["path"]
        ]
        self.assertEqual(1, len(pointer_gets))
        self.assertTrue(pointer_gets[0]["ifNoneMatch"])
        self.assertEqual([], immutable_manifest_gets)

    def test_disable_and_unregister_reject_a_running_transfer(self) -> None:
        service = self._service("Desktop")
        started = threading.Event()
        release = threading.Event()

        def runner(_context) -> None:
            started.set()
            self.assertTrue(release.wait(2))

        task = service._task_manager.start("upload", "local-codex", runner)
        self.assertTrue(started.wait(1))
        worker = service._task_manager._threads[task["taskId"]]
        try:
            with self.assertRaises(TaskBusyError):
                service.disable()
            with self.assertRaises(TaskBusyError):
                service.unregister("Desktop")
        finally:
            release.set()
            worker.join(timeout=2)
        self.assertEqual("completed", service.task_state()["status"])

    def test_corrupt_download_keeps_last_successful_cache(self) -> None:
        source = self._service("Desktop")
        target = self._service("Laptop")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        remote = next(item for item in target.refresh_catalog() if item["remoteSourceType"] == "local-codex")
        target.start_download(remote["id"])
        self.assertEqual("completed", self._wait(target)["status"])
        marker = target.source_index_root(remote["id"]) / "keep.txt"
        marker.write_text("old cache", encoding="utf-8")

        pointer_path = next(path for path in _WebDAVHandler.resources if path.endswith("/local-codex/manifest.json"))
        pointer = json.loads(_WebDAVHandler.resources[pointer_path])
        source_id = remote["id"]
        settings = json.loads(target.paths.settings_file.read_text(encoding="utf-8"))
        state = json.loads(target.paths.state_file.read_text(encoding="utf-8"))
        state["connections"][settings["connectionId"]]["downloaded"][source_id]["chatRevisionId"] = "0" * 64
        target.paths.state_file.write_text(json.dumps(state), encoding="utf-8")
        shutil.rmtree(next(path for path in (target.paths.connections_root / settings["connectionId"] / "devices").rglob("journal") if path.is_dir()))
        object_path = next(path for path in _WebDAVHandler.resources if "/objects/" in path)
        _WebDAVHandler.resources[object_path] = b"corrupt"

        target.start_download(remote["id"])
        failed = self._wait(target)
        self.assertEqual("error", failed["status"])
        self.assertTrue(marker.is_file())
        self.assertEqual("old cache", marker.read_text(encoding="utf-8"))

    def test_remote_index_rebuild_failure_preserves_the_visible_index(self) -> None:
        source = self._service("Desktop")
        target = self._service("Laptop")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        remote = next(item for item in target.refresh_catalog() if item["remoteSourceType"] == "local-codex")
        target.start_download(remote["id"])
        self.assertEqual("completed", self._wait(target)["status"])
        index_root = target.source_index_root(remote["id"])
        marker = index_root / "visible-before-rebuild.txt"
        marker.write_text("keep", encoding="utf-8")

        def fail_after_partial_output(_source, _raw, _origin, build_root):
            partial = build_root / "data" / "CodexChatIndex.sources" / remote["id"]
            partial.mkdir(parents=True)
            (partial / "CodexChatIndex.data.json").write_text("{}", encoding="utf-8")
            raise RuntimeError("injected rebuild failure")

        target._remote_build_runner = fail_after_partial_output
        with self.assertRaisesRegex(RuntimeError, "injected"):
            target.rebuild_remote_index(remote["id"])
        self.assertTrue(marker.is_file())
        self.assertEqual("keep", marker.read_text(encoding="utf-8"))

    def test_successful_rebuild_records_temp_cleanup_failure_and_retries_after_restart(self) -> None:
        source = self._service("Desktop-rebuild-temp-cleanup")
        target = self._service("Laptop-rebuild-temp-cleanup")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        remote = next(item for item in target.refresh_catalog() if item["remoteSourceType"] == "local-codex")
        target.start_download(remote["id"])
        self.assertEqual("completed", self._wait(target)["status"])
        original_rmtree = service_module.shutil.rmtree
        retained: list[Path] = []

        def fail_rebuild_cleanup(path, *args, **kwargs):
            candidate = Path(path)
            if candidate.name.startswith("rebuild-") and candidate.parent.name == "tasks":
                retained.append(candidate)
                raise PermissionError("injected rebuild temp lock")
            return original_rmtree(path, *args, **kwargs)

        service_module.shutil.rmtree = fail_rebuild_cleanup
        try:
            result = target.rebuild_remote_index(remote["id"])
        finally:
            service_module.shutil.rmtree = original_rmtree

        self.assertEqual("Full", result["mode"])
        self.assertEqual(1, len(retained))
        self.assertTrue(retained[0].is_dir())
        settings = json.loads(target.paths.settings_file.read_text(encoding="utf-8"))
        connection = target._connection_state(settings)
        self.assertTrue(connection.get("pendingLocalCleanup"))
        self.assertIn("临时目录清理失败", target.get_settings().get("warning", ""))

        restarted = self._restart(target)
        self.assertFalse(retained[0].exists())
        self.assertFalse(restarted._connection_state(settings).get("pendingLocalCleanup"))

    def test_cancel_requested_during_remote_build_prevents_cache_replacement(self) -> None:
        source = self._service("Desktop")
        target = self._service("Laptop")
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])
        remote = next(item for item in target.refresh_catalog() if item["remoteSourceType"] == "local-codex")
        target.start_download(remote["id"])
        self.assertEqual("completed", self._wait(target)["status"])
        marker = target.source_index_root(remote["id"]) / "keep-after-cancel.txt"
        marker.write_text("old", encoding="utf-8")

        self.source_file.write_bytes(b'{"record":2}\n')
        source.start_upload("local-codex")
        self.assertEqual("completed", self._wait(source)["status"])

        started = threading.Event()
        release = threading.Event()
        original_runner = target._remote_build_runner

        def blocked_runner(source_info, raw, origin_map, build_root):
            started.set()
            self.assertTrue(release.wait(2))
            return original_runner(source_info, raw, origin_map, build_root)

        target._remote_build_runner = blocked_runner
        task = target.start_download(remote["id"])
        self.assertTrue(started.wait(2))
        target.cancel_task(task["taskId"])
        release.set()
        finished = self._wait(target)

        self.assertEqual("cancelled", finished["status"], finished)
        self.assertTrue(marker.is_file())
        self.assertEqual("old", marker.read_text(encoding="utf-8"))

    def test_remote_staging_delete_failure_is_persisted_and_next_manual_upload_retries(self) -> None:
        service = self._service("Desktop-staging-retry")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        wrapper = _StagingDeleteClient(service._client(settings))
        service._client = lambda _settings=None: wrapper

        first_task = service.start_upload("local-codex")
        first = self._wait(service)

        self.assertEqual("completed", first["status"], first.get("errorSummary"))
        self.assertIn("新版本有效", first.get("warning", ""))
        connection = service._connection_state(settings)
        pending = connection.get("pendingRemoteStagingCleanup", [])
        self.assertEqual(1, len(pending))
        self.assertEqual(
            {"connectionId", "sourceType", "taskId", "error"},
            set(pending[0]),
        )
        self.assertEqual(settings["connectionId"], pending[0]["connectionId"])
        self.assertEqual("local-codex", pending[0]["sourceType"])
        self.assertEqual(first_task["taskId"], pending[0]["taskId"])
        self.assertNotIn("remote-staging-secret", json.dumps(pending))
        pointer_path = (
            f"/{settings['remoteRoot']}/v1/devices/{service.device['deviceId']}"
            "/local-codex/manifest.json"
        )
        self.assertIn(pointer_path, _WebDAVHandler.resources)

        wrapper.delete_error = "second cleanup lock"
        service.start_upload("local-codex")
        repeated = self._wait(service)
        self.assertEqual("completed", repeated["status"], repeated.get("errorSummary"))
        repeated_pending = service._connection_state(settings).get("pendingRemoteStagingCleanup", [])
        self.assertEqual(1, len(repeated_pending))
        self.assertIn("second cleanup lock", repeated_pending[0]["error"])

        wrapper.fail_staging_delete = False
        _WebDAVHandler.requests.clear()
        service.start_upload("local-codex")
        second = self._wait(service)

        self.assertEqual("completed", second["status"], second.get("errorSummary"))
        self.assertFalse(service._connection_state(settings).get("pendingRemoteStagingCleanup"))
        expected_task_root = (
            f"/{settings['remoteRoot']}/v1/devices/{service.device['deviceId']}"
            f"/local-codex/staging/{first_task['taskId']}"
        )
        self.assertTrue(any(
            request["method"] == "DELETE" and request["path"].rstrip("/") == expected_task_root
            for request in _WebDAVHandler.requests
        ))
        self.assertFalse(any(
            request["method"] == "DELETE" and request["path"].rstrip("/").endswith("/staging")
            for request in _WebDAVHandler.requests
        ))

    def test_manual_upload_retries_pending_remote_staging_for_every_local_source(self) -> None:
        service = self._service("Desktop-staging-cross-source")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        pending_task_id = str(uuid.uuid4())
        service._remember_remote_staging_cleanup(
            settings,
            "local-claude",
            pending_task_id,
            WebDAVError("previous cleanup failed"),
        )
        remote_task_root = (
            f"/{settings['remoteRoot']}/v1/devices/{service.device['deviceId']}"
            f"/local-claude/staging/{pending_task_id}"
        )
        _WebDAVHandler.collections.add(remote_task_root)
        _WebDAVHandler.resources[remote_task_root + "/manifest.json"] = b"partial"
        _WebDAVHandler.requests.clear()

        service.start_upload("local-codex")
        completed = self._wait(service)

        self.assertEqual("completed", completed["status"], completed.get("errorSummary"))
        self.assertNotIn(remote_task_root, _WebDAVHandler.collections)
        self.assertFalse(service._connection_state(settings).get("pendingRemoteStagingCleanup"))
        self.assertTrue(any(
            request["method"] == "DELETE" and request["path"].rstrip("/") == remote_task_root
            for request in _WebDAVHandler.requests
        ))

    def test_pointer_commit_failure_still_records_remote_staging_cleanup_failure(self) -> None:
        service = self._service("Desktop-staging-pointer-failure")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        wrapper = _StagingDeleteClient(service._client(settings))
        service._client = lambda _settings=None: wrapper
        pointer_path = (
            f"/{settings['remoteRoot']}/v1/devices/{service.device['deviceId']}"
            "/local-codex/manifest.json"
        )
        _WebDAVHandler.put_failures.add(pointer_path)

        task = service.start_upload("local-codex")
        failed = self._wait(service)

        self.assertEqual("error", failed["status"])
        self.assertNotIn(pointer_path, _WebDAVHandler.resources)
        pending = service._connection_state(settings).get("pendingRemoteStagingCleanup", [])
        self.assertEqual(task["taskId"], pending[0]["taskId"])
        self.assertEqual("local-codex", pending[0]["sourceType"])

    def test_pointer_commit_remains_effective_when_remote_staging_cleanup_fails(self) -> None:
        service = self._service("Desktop-staging-pointer")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        wrapper = _StagingDeleteClient(service._client(settings))
        service._client = lambda _settings=None: wrapper

        task = service.start_upload("local-codex")
        completed = self._wait(service)

        pointer_path = (
            f"/{settings['remoteRoot']}/v1/devices/{service.device['deviceId']}"
            "/local-codex/manifest.json"
        )
        self.assertEqual("completed", completed["status"], completed.get("errorSummary"))
        self.assertIn("新版本有效，但远端暂存清理待重试", completed.get("warning", ""))
        pointer = json.loads(_WebDAVHandler.resources[pointer_path])
        self.assertTrue(pointer["manifestRevisionId"])
        self.assertEqual(task["taskId"], service._connection_state(settings)["pendingRemoteStagingCleanup"][0]["taskId"])

    def test_cancelled_upload_records_remote_staging_cleanup_failure(self) -> None:
        service = self._service("Desktop-staging-cancel")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        wrapper = _StagingDeleteClient(service._client(settings))
        wrapper.pause_after_staging_manifest = True
        service._client = lambda _settings=None: wrapper

        task = service.start_upload("local-codex")
        self.assertTrue(wrapper.staging_manifest_written.wait(2))
        service.cancel_task(task["taskId"])
        wrapper.release_staging_manifest.set()
        cancelled = self._wait(service)

        self.assertEqual("cancelled", cancelled["status"])
        pending = service._connection_state(settings).get("pendingRemoteStagingCleanup", [])
        self.assertEqual(task["taskId"], pending[0]["taskId"])
        self.assertEqual("local-codex", pending[0]["sourceType"])

    def test_interrupted_upload_defers_remote_staging_cleanup_until_manual_source_refresh(self) -> None:
        service = self._service("Desktop-staging-interrupted")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        task_id, _task_root, _local_staging = self._write_interrupted_service_task(
            service,
            "upload",
            "local-codex",
        )
        remote_task_root = (
            f"/{settings['remoteRoot']}/v1/devices/{service.device['deviceId']}"
            f"/local-codex/staging/{task_id}"
        )
        _WebDAVHandler.collections.add(remote_task_root)
        _WebDAVHandler.resources[remote_task_root + "/manifest.json"] = b"partial"
        _WebDAVHandler.requests.clear()

        restarted = self._restart(service)

        self.assertEqual([], _WebDAVHandler.requests)
        self.assertIn(remote_task_root, _WebDAVHandler.collections)
        pending = restarted._connection_state(settings).get("pendingRemoteStagingCleanup", [])
        self.assertEqual(task_id, pending[0]["taskId"])
        restarted.check_connection({
            "baseUrl": self.base_url,
            "username": "user@example.test",
            "password": "test-only-password",
            "remoteRoot": settings["remoteRoot"],
            "deviceDisplayName": "Desktop-staging-interrupted",
            "allowInsecurePrivateHttp": True,
        })

        self.assertIn(remote_task_root, _WebDAVHandler.collections)
        self.assertTrue(restarted._connection_state(settings).get("pendingRemoteStagingCleanup"))
        self.assertFalse(any("/v1/devices" in request["path"] for request in _WebDAVHandler.requests))

        restarted.refresh_catalog()

        self.assertNotIn(remote_task_root, _WebDAVHandler.collections)
        self.assertFalse(restarted._connection_state(settings).get("pendingRemoteStagingCleanup"))

    def test_pending_remote_cleanup_is_retried_by_the_next_noop_upload(self) -> None:
        service = self._service("Desktop")
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        old_object = next(path for path in _WebDAVHandler.resources if "/objects/" in path)

        self.source_file.write_bytes(b'{"record":2}\n')
        _WebDAVHandler.delete_failures.add(old_object)
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        self.assertIn(old_object, _WebDAVHandler.resources)

        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        self.assertNotIn(old_object, _WebDAVHandler.resources)
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        connection = service._state()["connections"][settings["connectionId"]]
        self.assertNotIn("local-codex", connection.get("pendingCleanup", {}))

    def test_pending_cleanup_merges_old_and_new_failures_without_losing_digests(self) -> None:
        service = self._service("Desktop")
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        first_object = next(path for path in _WebDAVHandler.resources if "/objects/" in path)

        self.source_file.write_bytes(b'{"record":2}\n')
        _WebDAVHandler.delete_failures.add(first_object)
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        second_object = next(
            path for path in _WebDAVHandler.resources
            if "/objects/" in path and path != first_object
        )

        self.source_file.write_bytes(b'{"record":3}\n')
        _WebDAVHandler.delete_failures.update({first_object, second_object})
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])

        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        connection = service._state()["connections"][settings["connectionId"]]
        pending = connection.get("pendingCleanup", {}).get("local-codex", {})
        expected = {Path(first_object).stem, Path(second_object).stem}
        self.assertEqual(expected, set(pending.get("objectDigests") or []))
        self.assertTrue(expected.issubset({Path(path).stem for path in _WebDAVHandler.resources if "/objects/" in path}))

    def test_notes_only_upload_reuses_chat_manifest_without_repacking_or_object_requests(self) -> None:
        service = self._service("Desktop")
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        pointer_path = next(path for path in _WebDAVHandler.resources if path.endswith("/local-codex/manifest.json"))
        before = json.loads(_WebDAVHandler.resources[pointer_path])
        service.notes_file.write_text(json.dumps({
            "version": 1,
            "notes": {
                "local-codex::group:one": {
                    "sourceId": "local-codex",
                    "key": "group:one",
                    "note": "changed note",
                }
            },
        }), encoding="utf-8")
        _WebDAVHandler.requests.clear()
        original_create_snapshot = service_module.create_snapshot

        def reject_repack(*_args, **_kwargs):
            raise AssertionError("notes-only upload must not rebuild the chat snapshot")

        service_module.create_snapshot = reject_repack
        try:
            service.start_upload("local-codex")
            completed = self._wait(service)
        finally:
            service_module.create_snapshot = original_create_snapshot
        self.assertEqual("completed", completed["status"], completed.get("errorSummary"))
        after = json.loads(_WebDAVHandler.resources[pointer_path])
        self.assertEqual(before["chatRevisionId"], after["chatRevisionId"])
        self.assertNotEqual(before["notesRevisionId"], after["notesRevisionId"])
        object_requests = [
            request for request in _WebDAVHandler.requests
            if "/objects/" in request["path"] and request["method"] in {"PUT", "GET"}
        ]
        self.assertEqual([], object_requests)

    def test_changed_chat_upload_skips_objects_already_referenced_by_the_current_manifest(self) -> None:
        first_bucket = hashlib.sha256(b"sessions/one.jsonl").hexdigest()[:2]
        second_file = None
        for index in range(256):
            name = f"stable-{index:03d}.jsonl"
            if hashlib.sha256(f"sessions/{name}".encode()).hexdigest()[:2] != first_bucket:
                second_file = self.source_file.parent / name
                break
        self.assertIsNotNone(second_file)
        second_file.write_bytes(b'{"stable":true}\n')
        service = self._service("Desktop")
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        pointer_path = next(path for path in _WebDAVHandler.resources if path.endswith("/local-codex/manifest.json"))
        pointer = json.loads(_WebDAVHandler.resources[pointer_path])
        manifest_path = pointer_path.rsplit("/", 1)[0] + "/" + pointer["manifestPath"]
        manifest = json.loads(_WebDAVHandler.resources[manifest_path])
        stable_item = next(item for item in manifest["logicalFiles"] if item["logicalPath"].endswith(second_file.name))
        stable_digest = stable_item["storage"]["objectSha256"]

        self.source_file.write_bytes(b'{"changed":true}\n')
        _WebDAVHandler.requests.clear()
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        stable_requests = [
            request for request in _WebDAVHandler.requests
            if stable_digest in request["path"] and request["method"] in {"PUT", "GET"}
        ]
        self.assertEqual([], stable_requests)

    def test_manual_retry_reuses_objects_uploaded_before_pointer_commit_failed(self) -> None:
        service = self._service("Desktop")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        pointer_path = (
            f"/{settings['remoteRoot']}/v1/devices/{service.device['deviceId']}"
            "/local-codex/manifest.json"
        )
        _WebDAVHandler.put_failures.add(pointer_path)

        service.start_upload("local-codex")
        first = self._wait(service)
        self.assertEqual("error", first["status"])
        first_object_puts = [
            request for request in _WebDAVHandler.requests
            if request["method"] == "PUT" and "/objects/" in request["path"]
        ]
        self.assertTrue(first_object_puts)

        _WebDAVHandler.requests.clear()
        service.start_upload("local-codex")
        second = self._wait(service)
        self.assertEqual("completed", second["status"], second.get("errorSummary"))
        repeated_object_requests = [
            request for request in _WebDAVHandler.requests
            if request["method"] in {"PUT", "GET"} and "/objects/" in request["path"]
        ]
        self.assertEqual([], repeated_object_requests)
        journal_file = service._remote_source_cache_root(
            settings, str(service.device["deviceId"]), "local-codex"
        ) / "journal" / "uploaded-objects.json"
        self.assertFalse(journal_file.exists())

    def _check_payload(self, identity: str = "Desktop") -> dict:
        return {
            "baseUrl": self.base_url,
            "username": "user@example.test",
            "password": "test-only-password",
            "remoteRoot": "YujiSync",
            "deviceDisplayName": identity,
            "allowInsecurePrivateHttp": True,
        }

    def test_connection_probe_records_standard_mode_and_cleans_random_root(self) -> None:
        service = self._service("Desktop")
        _WebDAVHandler.requests.clear()
        result = service.check_connection(self._check_payload())

        self.assertTrue(result["ok"])
        self.assertEqual("standard", result["commitMode"])
        self.assertEqual("标准条件请求模式检查通过", result["message"])
        self.assertTrue(all(result["capabilities"].values()))
        self.assertFalse(any(".yuji-probe-" in path for path in _WebDAVHandler.resources))
        self.assertFalse(any(".yuji-probe-" in path for path in _WebDAVHandler.collections))
        self.assertFalse(any("/v1/devices" in request["path"] for request in _WebDAVHandler.requests))
        self.assertTrue(any("/YujiSync/.yuji-probe-" in request["path"] for request in _WebDAVHandler.requests))
        self.assertTrue(any(request["ifMatch"] for request in _WebDAVHandler.requests if request["method"] == "PUT"))

        saved = service.get_settings()["lastCheck"]
        self.assertEqual("standard", saved["commitMode"])
        self.assertEqual(result["capabilities"], saved["capabilities"])

    def test_probe_uses_move_create_mode_when_only_if_none_match_is_ignored(self) -> None:
        service = self._service("Desktop-if-none")
        _WebDAVHandler.ignore_if_none_match = True

        result = service.check_connection(self._check_payload("Desktop-if-none"))

        self.assertTrue(result["ok"])
        self.assertEqual("move-create", result["commitMode"])
        self.assertFalse(result["capabilities"]["ifNoneMatch"])
        self.assertTrue(result["capabilities"]["ifMatchRejectsInvalid"])
        self.assertTrue(result["capabilities"]["ifMatchAllowsValid"])
        self.assertTrue(result["capabilities"]["moveNoOverwrite"])
        self.assertEqual("坚果云兼容提交模式检查通过", result["message"])

    def test_probe_uses_remote_lock_mode_when_both_conditions_are_ignored(self) -> None:
        service = self._service("Desktop-lock-mode")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True

        result = service.check_connection(self._check_payload("Desktop-lock-mode"))

        self.assertTrue(result["ok"])
        self.assertEqual("remote-lock", result["commitMode"])
        self.assertFalse(result["capabilities"]["ifNoneMatch"])
        self.assertFalse(result["capabilities"]["ifMatchRejectsInvalid"])
        self.assertTrue(result["capabilities"]["moveNoOverwrite"])
        self.assertTrue(result["capabilities"]["mkcolExisting"])

    def test_probe_blocks_sync_when_move_overwrite_false_is_ignored(self) -> None:
        service = self._service("Desktop-unsafe-move")
        _WebDAVHandler.ignore_move_overwrite = True

        result = service.check_connection(self._check_payload("Desktop-unsafe-move"))

        self.assertFalse(result["ok"])
        self.assertEqual("blocked", result["commitMode"])
        self.assertFalse(result["capabilities"]["moveNoOverwrite"])
        self.assertIn("同步已被阻止", result["message"])

    def test_probe_records_every_capability_even_when_multiple_checks_fail(self) -> None:
        service = self._service("Desktop-multiple-probe-failures")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True
        _WebDAVHandler.ignore_move_overwrite = True
        _WebDAVHandler.mkcol_existing_succeeds = True
        _WebDAVHandler.requests.clear()

        result = service.check_connection(self._check_payload("Desktop-multiple-probe-failures"))

        self.assertFalse(result["ok"])
        self.assertFalse(result["capabilities"]["ifNoneMatch"])
        self.assertFalse(result["capabilities"]["ifMatchRejectsInvalid"])
        self.assertTrue(result["capabilities"]["ifMatchAllowsValid"])
        self.assertFalse(result["capabilities"]["moveNoOverwrite"])
        self.assertFalse(result["capabilities"]["mkcolExisting"])
        for marker in ("if-none.bin", "if-match-invalid.bin", "if-match-valid.bin", "move-source.bin", "/collection"):
            self.assertTrue(any(marker in request["path"] for request in _WebDAVHandler.requests), marker)

    def test_probe_cleanup_failure_is_restricted_and_retried_by_next_check(self) -> None:
        service = self._service("Desktop-probe-cleanup-retry")
        _WebDAVHandler.fail_probe_delete_once = True

        first = service.check_connection(self._check_payload("Desktop-probe-cleanup-retry"))

        self.assertTrue(first["ok"])
        self.assertFalse(first["probeCleanupOk"])
        self.assertIn("探针清理", first["warning"])
        pending = service._state().get("pendingProbes", [])
        self.assertEqual(1, len(pending))
        self.assertEqual({"connectionFingerprint", "probeId", "error"}, set(pending[0]))
        self.assertTrue(uuid.UUID(pending[0]["probeId"]))
        self.assertFalse(any("path" in item for item in pending))

        second = service.check_connection(self._check_payload("Desktop-probe-cleanup-retry"))

        self.assertTrue(second["ok"])
        self.assertFalse(service._state().get("pendingProbes"))
        self.assertFalse(any(".yuji-probe-" in path for path in _WebDAVHandler.resources))
        self.assertFalse(any(".yuji-probe-" in path for path in _WebDAVHandler.collections))

    def test_probe_failure_and_cancellation_leave_no_random_remote_directory(self) -> None:
        service = self._service("Desktop-probe-interruption")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))

        class InterruptingClient:
            def __init__(self, delegate: WebDAVClient, error: Exception) -> None:
                self.delegate = delegate
                self.error = error

            def __getattr__(self, name: str):
                return getattr(self.delegate, name)

            def propfind(self, path: str, **kwargs):
                if ".yuji-probe-" in str(path):
                    raise self.error
                return self.delegate.propfind(path, **kwargs)

        for error in (WebDAVError("probe failure"), TaskCancelled("probe cancelled")):
            with self.subTest(error=type(error).__name__):
                service._temporary_client = lambda _temporary, current=error: InterruptingClient(
                    service._client(settings), current
                )
                with self.assertRaises(type(error)):
                    service.check_connection(self._check_payload("Desktop-probe-interruption"))
                self.assertFalse(any(".yuji-probe-" in path for path in _WebDAVHandler.resources))
                self.assertFalse(any(".yuji-probe-" in path for path in _WebDAVHandler.collections))

    def test_ignored_conditions_without_reliable_lock_mkcol_block_upload(self) -> None:
        service = self._service("Desktop-no-safe-lock")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True
        _WebDAVHandler.mkcol_existing_succeeds = True
        result = service.check_connection(self._check_payload("Desktop-no-safe-lock"))
        _WebDAVHandler.requests.clear()

        self.assertFalse(result["ok"])
        self.assertEqual("blocked", result["commitMode"])
        with self.assertRaisesRegex(ConfigError, "安全提交模式"):
            service.start_upload("local-codex")
        self.assertEqual([], _WebDAVHandler.requests)

    def test_upload_requires_a_safe_capability_check_for_current_connection(self) -> None:
        service = self._service("Desktop-no-capabilities")
        service._update_state(lambda state: state.update({"lastCheck": {}}))

        try:
            with self.assertRaisesRegex(ConfigError, "安全提交模式"):
                service.start_upload("local-codex")
        finally:
            running = service.task_state()
            if running.get("status") in {"running", "cancelling"}:
                service.cancel_task(str(running["taskId"]))
                self._wait(service)

        self.assertFalse(any("/v1/devices" in request["path"] for request in _WebDAVHandler.requests))

    def test_check_before_saving_changed_connection_preserves_matching_capabilities(self) -> None:
        service = self._service("Desktop-check-before-save")
        changed = self._check_payload("Desktop-check-before-save")
        changed["remoteRoot"] = "YujiSyncChanged"

        checked = service.check_connection(changed)
        saved = service.save_settings(changed)

        self.assertTrue(checked["ok"])
        self.assertEqual("standard", saved["lastCheck"]["commitMode"])
        self.assertEqual(
            service._connection_fingerprint(changed),
            saved["lastCheck"]["connectionFingerprint"],
        )

    def test_move_create_mode_uses_staging_move_for_immutable_files_and_first_pointer(self) -> None:
        service = self._service("Desktop-move-create-upload")
        _WebDAVHandler.ignore_if_none_match = True
        checked = service.check_connection(self._check_payload("Desktop-move-create-upload"))
        self.assertEqual("move-create", checked["commitMode"])
        _WebDAVHandler.requests.clear()

        service.start_upload("local-codex")
        completed = self._wait(service)

        self.assertEqual("completed", completed["status"], completed.get("errorSummary"))
        direct_creates = [
            request for request in _WebDAVHandler.requests
            if request["method"] == "PUT"
            and (
                "/objects/" in request["path"]
                or "/notes/" in request["path"]
                or request["path"].endswith("/device.json")
                or request["path"].endswith("/manifest.json")
            )
            and "/staging/" not in request["path"]
        ]
        self.assertEqual([], [request for request in direct_creates if request["ifNoneMatch"] == "*"])
        pointer_path = next(path for path in _WebDAVHandler.resources if path.endswith("/local-codex/manifest.json"))
        self.assertTrue(any(
            request["method"] == "MOVE"
            and urlsplit(request["destination"]).path == pointer_path
            and request["overwrite"] == "F"
            for request in _WebDAVHandler.requests
        ))

    def test_move_create_mode_never_overwrites_a_conflicting_existing_object(self) -> None:
        service = self._service("Desktop-move-create-conflict")
        _WebDAVHandler.ignore_if_none_match = True
        service.check_connection(self._check_payload("Desktop-move-create-conflict"))
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        object_path = next(path for path in _WebDAVHandler.resources if "/objects/" in path and path.endswith(".bin"))
        pointer_path = next(path for path in _WebDAVHandler.resources if path.endswith("/local-codex/manifest.json"))
        _WebDAVHandler.resources[object_path] = b"conflicting-existing-object"
        _WebDAVHandler.etags[object_path] = '"conflicting-object"'
        _WebDAVHandler.resources.pop(pointer_path)
        _WebDAVHandler.etags.pop(pointer_path, None)
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        service._clear_upload_journal(settings, "local-codex")
        service._forget_pointer(settings, str(service.device["deviceId"]), "local-codex")
        _WebDAVHandler.requests.clear()

        service.start_upload("local-codex")
        failed = self._wait(service)

        self.assertEqual("error", failed["status"])
        self.assertIn("内容", failed.get("errorSummary", ""))
        self.assertEqual(b"conflicting-existing-object", _WebDAVHandler.resources[object_path])
        self.assertFalse(any(
            request["method"] == "PUT" and request["path"] == object_path
            for request in _WebDAVHandler.requests
        ))

    def test_move_create_mode_keeps_if_match_for_existing_pointer_updates(self) -> None:
        service = self._service("Desktop-move-create-update")
        _WebDAVHandler.ignore_if_none_match = True
        service.check_connection(self._check_payload("Desktop-move-create-update"))
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        pointer_path = next(path for path in _WebDAVHandler.resources if path.endswith("/local-codex/manifest.json"))
        self.source_file.write_bytes(b'{"record":2}\n')
        _WebDAVHandler.requests.clear()

        service.start_upload("local-codex")
        completed = self._wait(service)

        self.assertEqual("completed", completed["status"], completed.get("errorSummary"))
        pointer_updates = [
            request for request in _WebDAVHandler.requests
            if request["method"] == "PUT" and request["path"] == pointer_path
        ]
        self.assertEqual(1, len(pointer_updates))
        self.assertTrue(pointer_updates[0]["ifMatch"])
        self.assertFalse(pointer_updates[0]["ifNoneMatch"])

    def test_remote_lock_mode_acquires_verifies_and_releases_source_lock(self) -> None:
        service = self._service("Desktop-remote-lock-upload")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True
        checked = service.check_connection(self._check_payload("Desktop-remote-lock-upload"))
        self.assertEqual("remote-lock", checked["commitMode"])
        _WebDAVHandler.requests.clear()

        service.start_upload("local-codex")
        completed = self._wait(service)

        self.assertEqual("completed", completed["status"], completed.get("errorSummary"))
        lock_root = next(
            request["path"].rstrip("/") for request in _WebDAVHandler.requests
            if request["method"] == "MKCOL" and request["path"].endswith("/locks/commit")
        )
        owner_path = lock_root + "/owner.json"
        owner_put = next(
            request for request in _WebDAVHandler.requests
            if request["method"] == "PUT" and request["path"] == owner_path
        )
        owner = json.loads(owner_put["body"])
        self.assertEqual(str(service.device["deviceId"]), owner["deviceId"])
        self.assertEqual("local-codex", owner["sourceType"])
        self.assertTrue(uuid.UUID(owner["taskId"]))
        self.assertTrue(uuid.UUID(owner["lockToken"]))
        self.assertTrue(owner["leaseUntil"])
        self.assertTrue(any(
            request["method"] == "GET" and request["path"] == owner_path
            for request in _WebDAVHandler.requests
        ))
        self.assertTrue(any(
            request["method"] == "DELETE" and request["path"].rstrip("/") == lock_root
            for request in _WebDAVHandler.requests
        ))

    def test_two_remote_lock_contenders_cannot_both_acquire_the_same_source(self) -> None:
        service = self._service("Desktop-lock-race")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True
        service.check_connection(self._check_payload("Desktop-lock-race"))
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        service._ensure_source_layout(
            service._client(settings), settings, str(service.device["deviceId"]), "local-codex"
        )
        barrier = threading.Barrier(2)
        acquired: list[dict] = []
        failed: list[Exception] = []

        def contend() -> None:
            task_id = str(uuid.uuid4())
            client = service._client(settings)
            barrier.wait()
            try:
                acquired.append(
                    service._acquire_remote_commit_lock(client, settings, "local-codex", task_id)
                )
            except Exception as error:
                failed.append(error)

        workers = [threading.Thread(target=contend) for _ in range(2)]
        for worker in workers:
            worker.start()
        for worker in workers:
            worker.join(timeout=3)

        self.assertEqual(1, len(acquired))
        self.assertEqual(1, len(failed))
        self.assertIn("正在", str(failed[0]))
        service._release_remote_commit_lock(service._client(settings), settings, acquired[0])

    def test_expired_remote_lock_is_double_read_then_recompeted(self) -> None:
        service = self._service("Desktop-lock-expired-recompete")
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        client = service._client(settings)
        service._ensure_source_layout(
            client, settings, str(service.device["deviceId"]), "local-codex"
        )
        first = service._acquire_remote_commit_lock(
            client, settings, "local-codex", str(uuid.uuid4())
        )
        owner_resource = "/" + first["ownerPath"]
        owner = json.loads(_WebDAVHandler.resources[owner_resource])
        owner["leaseUntil"] = "2000-01-01T00:00:00Z"
        _WebDAVHandler.resources[owner_resource] = canonical_json_bytes(owner)
        _WebDAVHandler.etags[owner_resource] = '"expired-owner"'
        _WebDAVHandler.requests.clear()

        second = service._acquire_remote_commit_lock(
            service._client(settings), settings, "local-codex", str(uuid.uuid4())
        )

        self.assertNotEqual(first["lockToken"], second["lockToken"])
        owner_reads = [
            request for request in _WebDAVHandler.requests
            if request["method"] == "GET" and request["path"] == owner_resource
        ]
        self.assertGreaterEqual(len(owner_reads), 2)
        self.assertTrue(any(
            request["method"] == "DELETE" and request["path"].rstrip("/") == "/" + first["lockRoot"]
            for request in _WebDAVHandler.requests
        ))
        self.assertTrue(any(
            request["method"] == "MKCOL" and request["path"].rstrip("/") == "/" + first["lockRoot"]
            for request in _WebDAVHandler.requests
        ))
        self.assertTrue(service._release_remote_commit_lock(service._client(settings), settings, second))
        self.assertFalse(service._connection_state(settings).get("pendingRemoteLockCleanup"))

    def test_remote_lock_token_change_stops_before_pointer_commit(self) -> None:
        service = self._service("Desktop-lock-token-change")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True
        service.check_connection(self._check_payload("Desktop-lock-token-change"))
        _WebDAVHandler.lock_owner_mutation = "token"
        _WebDAVHandler.lock_owner_mutate_after = 2

        service.start_upload("local-codex")
        failed = self._wait(service)

        self.assertEqual("error", failed["status"])
        self.assertIn("锁", failed.get("errorSummary", ""))
        self.assertFalse(any(
            path.endswith("/local-codex/manifest.json") and "/staging/" not in path
            for path in _WebDAVHandler.resources
        ))

    def test_remote_lock_expiry_stops_before_pointer_commit(self) -> None:
        service = self._service("Desktop-lock-expiry")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True
        service.check_connection(self._check_payload("Desktop-lock-expiry"))
        _WebDAVHandler.lock_owner_mutation = "expired"
        _WebDAVHandler.lock_owner_mutate_after = 2

        service.start_upload("local-codex")
        failed = self._wait(service)

        self.assertEqual("error", failed["status"])
        self.assertIn("租约", failed.get("errorSummary", ""))
        self.assertFalse(any(
            path.endswith("/local-codex/manifest.json") and "/staging/" not in path
            for path in _WebDAVHandler.resources
        ))

    def test_remote_lock_disappearance_stops_and_keeps_restricted_cleanup_state(self) -> None:
        service = self._service("Desktop-lock-lost")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True
        service.check_connection(self._check_payload("Desktop-lock-lost"))
        _WebDAVHandler.lock_owner_mutation = "lost"
        _WebDAVHandler.lock_owner_mutate_after = 2

        service.start_upload("local-codex")
        failed = self._wait(service)

        self.assertEqual("error", failed["status"])
        self.assertIn("锁", failed.get("errorSummary", ""))
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        pending = service._connection_state(settings).get("pendingRemoteLockCleanup", [])
        self.assertEqual(1, len(pending))
        self.assertEqual(
            {"connectionId", "sourceType", "taskId", "lockToken", "error"},
            set(pending[0]),
        )
        self.assertFalse(any(
            path.endswith("/local-codex/manifest.json") and "/staging/" not in path
            for path in _WebDAVHandler.resources
        ))

    def test_remote_lock_pointer_readback_mismatch_never_starts_old_object_cleanup(self) -> None:
        service = self._service("Desktop-lock-pointer-readback")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True
        service.check_connection(self._check_payload("Desktop-lock-pointer-readback"))
        _WebDAVHandler.corrupt_pointer_after_put = True
        _WebDAVHandler.pointer_paths_written.clear()
        _WebDAVHandler.requests.clear()

        service.start_upload("local-codex")
        failed = self._wait(service)

        self.assertEqual("error", failed["status"])
        self.assertIn("读回", failed.get("errorSummary", ""))
        self.assertFalse(any(
            request["method"] == "DELETE"
            and any(part in request["path"] for part in ("/objects/", "/manifests/", "/notes/"))
            for request in _WebDAVHandler.requests
        ))

    def test_remote_lock_token_change_after_pointer_commit_stops_before_old_cleanup(self) -> None:
        service = self._service("Desktop-lock-post-commit-loss")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True
        service.check_connection(self._check_payload("Desktop-lock-post-commit-loss"))
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        old_object = next(path for path in _WebDAVHandler.resources if "/objects/" in path)
        self.source_file.write_bytes(b'{"record":2}\n')
        _WebDAVHandler.mutate_lock_after_pointer_put = True
        _WebDAVHandler.requests.clear()

        service.start_upload("local-codex")
        failed = self._wait(service)

        self.assertEqual("error", failed["status"])
        self.assertIn("锁", failed.get("errorSummary", ""))
        self.assertIn(old_object, _WebDAVHandler.resources)
        self.assertFalse(any(
            request["method"] == "DELETE" and request["path"] == old_object
            for request in _WebDAVHandler.requests
        ))

    def test_remote_lock_cleanup_failure_is_retried_by_next_manual_upload(self) -> None:
        service = self._service("Desktop-lock-cleanup-retry")
        _WebDAVHandler.ignore_if_none_match = True
        _WebDAVHandler.ignore_if_match = True
        service.check_connection(self._check_payload("Desktop-lock-cleanup-retry"))
        _WebDAVHandler.fail_lock_delete_once = True

        service.start_upload("local-codex")
        first = self._wait(service)

        self.assertEqual("completed", first["status"], first.get("errorSummary"))
        settings = json.loads(service.paths.settings_file.read_text(encoding="utf-8"))
        pending = service._connection_state(settings).get("pendingRemoteLockCleanup", [])
        self.assertEqual(1, len(pending))
        self.assertEqual(
            {"connectionId", "sourceType", "taskId", "lockToken", "error"},
            set(pending[0]),
        )
        self.assertFalse(any("path" in item for item in pending))

        service.start_upload("local-codex")
        second = self._wait(service)

        self.assertEqual("completed", second["status"], second.get("errorSummary"))
        self.assertFalse(service._connection_state(settings).get("pendingRemoteLockCleanup"))

    def test_large_deletion_requires_snapshot_specific_confirmation(self) -> None:
        for index in range(24):
            (self.source_file.parent / f"extra-{index:02d}.jsonl").write_bytes(b'{"record":1}\n')
        service = self._service("Desktop")
        service.start_upload("local-codex")
        self.assertEqual("completed", self._wait(service)["status"])
        pointer_path = next(path for path in _WebDAVHandler.resources if path.endswith("/local-codex/manifest.json"))
        original_pointer = bytes(_WebDAVHandler.resources[pointer_path])

        for path in self.source_file.parent.glob("extra-*.jsonl"):
            path.unlink()
        service.start_upload("local-codex")
        confirmation = self._wait(service)
        self.assertEqual("needs-confirmation", confirmation["status"])
        self.assertTrue(confirmation["confirmationToken"])
        self.assertEqual(original_pointer, _WebDAVHandler.resources[pointer_path])

        service.start_upload("local-codex", confirmation["confirmationToken"])
        completed = self._wait(service)
        self.assertEqual("completed", completed["status"], completed.get("errorSummary"))
        pointer = json.loads(_WebDAVHandler.resources[pointer_path])
        self.assertEqual(1, pointer["logicalFileCount"])


if __name__ == "__main__":
    unittest.main()
