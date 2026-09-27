from __future__ import annotations

import base64
import ctypes
import hashlib
import ipaddress
import json
import os
import re
import socket
import sys
import uuid
from ctypes import wintypes
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit, urlunsplit


DEFAULT_WEBDAV_URL = "https://dav.jianguoyun.com/dav/"
DEFAULT_REMOTE_ROOT = "YujiSync"
_CONNECTION_FIELDS = ("baseUrl", "username", "remoteRoot")


class ConfigError(ValueError):
    pass


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def derive_machine_key(machine_guid: str, user_sid: str) -> str:
    machine_guid = str(machine_guid or "").strip()
    user_sid = str(user_sid or "").strip()
    if not machine_guid or not user_sid:
        raise ConfigError("无法取得稳定的 Windows 设备身份，WebDAV 已停止")
    return hashlib.sha256(f"{machine_guid}\n{user_sid}".encode("utf-8")).hexdigest()[:16]


def _read_machine_guid() -> str:
    if not sys.platform.startswith("win"):
        raise ConfigError("WebDAV 设备身份只支持 Windows")
    try:
        import winreg

        flags = winreg.KEY_READ
        if hasattr(winreg, "KEY_WOW64_64KEY"):
            flags |= winreg.KEY_WOW64_64KEY
        with winreg.OpenKey(
            winreg.HKEY_LOCAL_MACHINE,
            r"SOFTWARE\Microsoft\Cryptography",
            0,
            flags,
        ) as key:
            value, _kind = winreg.QueryValueEx(key, "MachineGuid")
    except (OSError, ImportError) as error:
        raise ConfigError("无法读取 Windows MachineGuid，WebDAV 已停止") from error
    value = str(value or "").strip()
    if not value:
        raise ConfigError("Windows MachineGuid 为空，WebDAV 已停止")
    return value


def _read_current_user_sid() -> str:
    if not sys.platform.startswith("win"):
        raise ConfigError("WebDAV 设备身份只支持 Windows")

    token_query = 0x0008
    token_user = 1
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    kernel32.LocalFree.restype = wintypes.HLOCAL
    advapi32.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi32.OpenProcessToken.restype = wintypes.BOOL
    advapi32.GetTokenInformation.argtypes = [
        wintypes.HANDLE,
        ctypes.c_int,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD),
    ]
    advapi32.GetTokenInformation.restype = wintypes.BOOL
    advapi32.ConvertSidToStringSidW.argtypes = [ctypes.c_void_p, ctypes.POINTER(wintypes.LPWSTR)]
    advapi32.ConvertSidToStringSidW.restype = wintypes.BOOL
    token_handle = wintypes.HANDLE()
    if not advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), token_query, ctypes.byref(token_handle)):
        raise ConfigError("无法打开当前 Windows 用户令牌")
    try:
        required = wintypes.DWORD()
        advapi32.GetTokenInformation(token_handle, token_user, None, 0, ctypes.byref(required))
        if not required.value:
            raise ConfigError("无法读取当前 Windows 用户 SID")
        buffer = ctypes.create_string_buffer(required.value)
        if not advapi32.GetTokenInformation(
            token_handle,
            token_user,
            buffer,
            required,
            ctypes.byref(required),
        ):
            raise ConfigError("无法读取当前 Windows 用户 SID")
        sid_pointer = ctypes.cast(buffer, ctypes.POINTER(ctypes.c_void_p))[0]
        sid_text = wintypes.LPWSTR()
        if not advapi32.ConvertSidToStringSidW(sid_pointer, ctypes.byref(sid_text)):
            raise ConfigError("无法转换当前 Windows 用户 SID")
        try:
            value = str(sid_text.value or "").strip()
        finally:
            kernel32.LocalFree(ctypes.cast(sid_text, wintypes.HLOCAL))
    finally:
        kernel32.CloseHandle(token_handle)
    if not value:
        raise ConfigError("当前 Windows 用户 SID 为空")
    return value


@dataclass(frozen=True)
class RuntimePaths:
    runtime_root: Path
    machine_key: str

    @classmethod
    def for_identity(cls, runtime_root: Path, machine_guid: str, user_sid: str) -> "RuntimePaths":
        return cls(Path(runtime_root), derive_machine_key(machine_guid, user_sid))

    @classmethod
    def for_current_user(cls, runtime_root: Path) -> "RuntimePaths":
        return cls.for_identity(Path(runtime_root), _read_machine_guid(), _read_current_user_sid())

    @property
    def local_root(self) -> Path:
        return self.runtime_root / "CodexChatIndex.local" / self.machine_key

    @property
    def device_file(self) -> Path:
        return self.local_root / "CodexChatIndex.device.json"

    @property
    def settings_file(self) -> Path:
        return self.local_root / "CodexChatIndex.webdav.json"

    @property
    def state_file(self) -> Path:
        return self.local_root / "CodexChatIndex.webdav-state.json"

    @property
    def ui_state_file(self) -> Path:
        return self.local_root / "CodexChatIndex.ui-state.json"

    @property
    def webdav_root(self) -> Path:
        return self.local_root / "CodexChatIndex.webdav"

    @property
    def connections_root(self) -> Path:
        return self.webdav_root / "connections"

    @property
    def sources_root(self) -> Path:
        return self.local_root / "CodexChatIndex.sources"

    def connection_root(self, connection_id: str) -> Path:
        return self.connections_root / safe_uuid(connection_id)


def safe_uuid(value: str) -> str:
    try:
        return str(uuid.UUID(str(value or "")))
    except (ValueError, AttributeError) as error:
        raise ConfigError("无效的 connectionId 或 deviceId") from error


def read_json(path: Path, default: dict | None = None) -> dict:
    if not path.is_file():
        return dict(default or {})
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ConfigError(f"配置文件无法读取：{path.name}") from error
    if not isinstance(value, dict):
        raise ConfigError(f"配置文件格式无效：{path.name}")
    return value


def write_json_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    text = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=False) + "\n"
    try:
        temporary.write_text(text, encoding="utf-8", newline="\n")
        os.replace(temporary, path)
    finally:
        try:
            temporary.unlink(missing_ok=True)
        except OSError:
            pass


def load_or_create_device(paths: RuntimePaths) -> dict:
    if paths.device_file.is_file():
        device = read_json(paths.device_file)
        try:
            device_id = safe_uuid(str(device.get("deviceId") or ""))
        except ConfigError as error:
            raise ConfigError("本机 WebDAV 设备文件损坏") from error
        if int(device.get("version") or 0) != 1:
            raise ConfigError("不支持的本机 WebDAV 设备文件版本")
        return {"version": 1, "deviceId": device_id, "createdAt": str(device.get("createdAt") or "")}
    device = {"version": 1, "deviceId": str(uuid.uuid4()), "createdAt": utc_now()}
    write_json_atomic(paths.device_file, device)
    return device


class _DataBlob(ctypes.Structure):
    _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_ubyte))]


def _blob_from_bytes(value: bytes) -> tuple[_DataBlob, ctypes.Array]:
    buffer = ctypes.create_string_buffer(value, len(value))
    return _DataBlob(len(value), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_ubyte))), buffer


def protect_password(password: str) -> str:
    if not sys.platform.startswith("win"):
        raise ConfigError("DPAPI 只支持 Windows")
    value = str(password or "")
    if not value:
        raise ConfigError("密码不能为空")
    source_blob, source_buffer = _blob_from_bytes(value.encode("utf-8"))
    output_blob = _DataBlob()
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    crypt32.CryptProtectData.argtypes = [
        ctypes.POINTER(_DataBlob),
        wintypes.LPCWSTR,
        ctypes.POINTER(_DataBlob),
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(_DataBlob),
    ]
    crypt32.CryptProtectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    kernel32.LocalFree.restype = wintypes.HLOCAL
    if not crypt32.CryptProtectData(
        ctypes.byref(source_blob),
        "Yuji WebDAV",
        None,
        None,
        None,
        0x1,
        ctypes.byref(output_blob),
    ):
        raise ConfigError("Windows DPAPI 无法保存 WebDAV 密码")
    try:
        encrypted = ctypes.string_at(output_blob.pbData, output_blob.cbData)
    finally:
        kernel32.LocalFree(ctypes.cast(output_blob.pbData, wintypes.HLOCAL))
    return base64.b64encode(encrypted).decode("ascii")


def unprotect_password(protected_password: str) -> str:
    if not sys.platform.startswith("win"):
        raise ConfigError("DPAPI 只支持 Windows")
    try:
        encrypted = base64.b64decode(str(protected_password or ""), validate=True)
    except (ValueError, TypeError) as error:
        raise ConfigError("已保存的 WebDAV 密码格式无效") from error
    source_blob, source_buffer = _blob_from_bytes(encrypted)
    output_blob = _DataBlob()
    crypt32 = ctypes.WinDLL("crypt32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    crypt32.CryptUnprotectData.argtypes = [
        ctypes.POINTER(_DataBlob),
        ctypes.POINTER(wintypes.LPWSTR),
        ctypes.POINTER(_DataBlob),
        ctypes.c_void_p,
        ctypes.c_void_p,
        wintypes.DWORD,
        ctypes.POINTER(_DataBlob),
    ]
    crypt32.CryptUnprotectData.restype = wintypes.BOOL
    kernel32.LocalFree.argtypes = [wintypes.HLOCAL]
    kernel32.LocalFree.restype = wintypes.HLOCAL
    if not crypt32.CryptUnprotectData(
        ctypes.byref(source_blob), None, None, None, None, 0x1, ctypes.byref(output_blob)
    ):
        raise ConfigError("已保存的 WebDAV 密码无法由当前 Windows 用户解密，请重新输入")
    try:
        clear = ctypes.string_at(output_blob.pbData, output_blob.cbData)
    finally:
        kernel32.LocalFree(ctypes.cast(output_blob.pbData, wintypes.HLOCAL))
    try:
        return clear.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ConfigError("已保存的 WebDAV 密码内容无效，请重新输入") from error


def _default_port(scheme: str) -> int:
    return 443 if scheme == "https" else 80


def _is_private_address(value: str) -> bool:
    address = ipaddress.ip_address(value.split("%")[0])
    return address.is_loopback or address.is_link_local or address.is_private


def resolve_private_http_addresses(hostname: str, port: int) -> tuple[str, ...]:
    try:
        addresses = {item[4][0] for item in socket.getaddrinfo(hostname, port, type=socket.SOCK_STREAM)}
    except socket.gaierror as error:
        raise ConfigError("无法解析局域网 WebDAV 地址") from error
    if not addresses or not all(_is_private_address(address) for address in addresses):
        raise ConfigError("HTTP 只允许回环、链路本地或 RFC1918 私有地址")
    return tuple(sorted(addresses, key=lambda value: (ipaddress.ip_address(value.split("%")[0]).version, value)))


def _validate_private_http_host(hostname: str, port: int) -> None:
    resolve_private_http_addresses(hostname, port)


def validate_webdav_url(value: str, allow_insecure_private_http: bool = False) -> str:
    raw = str(value or "").strip()
    if not raw:
        raise ConfigError("WebDAV URL 不能为空")
    try:
        parsed = urlsplit(raw)
        port = parsed.port or _default_port(parsed.scheme.casefold())
    except ValueError as error:
        raise ConfigError("WebDAV URL 格式无效") from error
    scheme = parsed.scheme.casefold()
    if scheme not in {"https", "http"} or not parsed.hostname:
        raise ConfigError("WebDAV URL 必须是 http 或 https 地址")
    if parsed.username is not None or parsed.password is not None:
        raise ConfigError("WebDAV URL 中不能包含用户名或密码")
    if parsed.query or parsed.fragment:
        raise ConfigError("WebDAV URL 中不能包含查询参数或 fragment")
    if scheme == "http":
        if not allow_insecure_private_http:
            raise ConfigError("公开网络 HTTP WebDAV 地址被拒绝")
        _validate_private_http_host(parsed.hostname, port)
    path = parsed.path or "/"
    if not path.endswith("/"):
        path += "/"
    netloc = parsed.hostname
    if ":" in netloc and not netloc.startswith("["):
        netloc = f"[{netloc}]"
    if parsed.port is not None:
        netloc += f":{parsed.port}"
    return urlunsplit((scheme, netloc, path, "", ""))


def validate_remote_root(value: str) -> str:
    candidate = str(value or DEFAULT_REMOTE_ROOT).strip().strip("/")
    if not candidate or "\\" in candidate or "//" in candidate or "\x00" in candidate:
        raise ConfigError("远端根目录格式无效")
    parts = candidate.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise ConfigError("远端根目录不能包含空段、. 或 ..")
    return "/".join(parts)


def default_public_settings(device_display_name: str = "") -> dict:
    return {
        "version": 1,
        "connectionId": "",
        "enabled": False,
        "baseUrl": DEFAULT_WEBDAV_URL,
        "username": "",
        "passwordSaved": False,
        "remoteRoot": DEFAULT_REMOTE_ROOT,
        "deviceDisplayName": str(device_display_name or os.environ.get("COMPUTERNAME") or socket.gethostname() or "").strip(),
        "allowInsecurePrivateHttp": False,
    }


def load_raw_settings(paths: RuntimePaths) -> dict:
    return read_json(paths.settings_file, {})


def load_public_settings(paths: RuntimePaths) -> dict:
    raw = load_raw_settings(paths)
    public = default_public_settings()
    for key in (
        "version",
        "connectionId",
        "enabled",
        "baseUrl",
        "username",
        "remoteRoot",
        "deviceDisplayName",
        "allowInsecurePrivateHttp",
    ):
        if key in raw:
            public[key] = raw[key]
    public["passwordSaved"] = bool(raw.get("protectedPassword"))
    return public


def save_settings(
    paths: RuntimePaths,
    payload: dict,
    *,
    protect: Callable[[str], str] = protect_password,
) -> dict:
    if not isinstance(payload, dict):
        raise ConfigError("设置必须是 JSON 对象")
    existing = load_raw_settings(paths)
    allow_http = bool(payload.get("allowInsecurePrivateHttp", False))
    base_url = validate_webdav_url(
        str(payload.get("baseUrl") or DEFAULT_WEBDAV_URL),
        allow_insecure_private_http=allow_http,
    )
    username = str(payload.get("username") or "").strip()
    if not username:
        raise ConfigError("用户名不能为空")
    remote_root = validate_remote_root(str(payload.get("remoteRoot") or DEFAULT_REMOTE_ROOT))
    display_name = str(payload.get("deviceDisplayName") or "").strip()
    if not display_name:
        raise ConfigError("设备显示名不能为空")
    if len(display_name) > 80 or any(ord(character) < 32 for character in display_name):
        raise ConfigError("设备显示名格式无效")

    material = {"baseUrl": base_url, "username": username, "remoteRoot": remote_root}
    connection_changed = not existing or any(str(existing.get(key) or "") != str(material[key]) for key in _CONNECTION_FIELDS)
    clear_password = str(payload.get("password") or "")
    if connection_changed and not clear_password:
        raise ConfigError("URL、用户名或远端根目录变化后必须重新输入密码")
    protected_password = protect(clear_password) if clear_password else str(existing.get("protectedPassword") or "")
    if not protected_password:
        raise ConfigError("密码不能为空")

    connection_id = str(uuid.uuid4()) if connection_changed else safe_uuid(str(existing.get("connectionId") or ""))
    settings = {
        "version": 1,
        "connectionId": connection_id,
        "enabled": bool(payload.get("enabled", True)),
        **material,
        "protectedPassword": protected_password,
        "deviceDisplayName": display_name,
        "allowInsecurePrivateHttp": allow_http,
    }
    write_json_atomic(paths.settings_file, settings)
    return settings


def decrypt_settings_password(settings: dict) -> str:
    protected = str(settings.get("protectedPassword") or "")
    if not protected:
        raise ConfigError("WebDAV 密码尚未保存")
    return unprotect_password(protected)
