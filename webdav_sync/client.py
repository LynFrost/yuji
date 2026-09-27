from __future__ import annotations

import base64
import http.client
import io
import re
import ssl
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterable
from urllib.parse import quote, unquote, urljoin, urlsplit

from .config import ConfigError, resolve_private_http_addresses, validate_webdav_url


ERROR_BODY_LIMIT = 64 * 1024
DEFAULT_JSON_LIMIT = 256 * 1024
STREAM_BUFFER_SIZE = 256 * 1024
REDIRECT_STATUSES = {301, 302, 307, 308}


class WebDAVError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        status: int | None = None,
        reason: str = "",
        retry_after: str = "",
        target: str = "",
    ) -> None:
        super().__init__(message)
        self.status = status
        self.reason = reason
        self.retry_after = retry_after
        self.target = target


class RedirectRejectedError(WebDAVError):
    pass


@dataclass
class WebDAVResponse:
    status: int
    reason: str
    headers: dict[str, str]
    body: bytes = b""

    @property
    def etag(self) -> str:
        return self.headers.get("etag", "")


def _origin(url: str) -> tuple[str, str, int]:
    parsed = urlsplit(url)
    port = parsed.port or (443 if parsed.scheme.casefold() == "https" else 80)
    return parsed.scheme.casefold(), (parsed.hostname or "").casefold(), port


def _safe_error_text(raw: bytes, content_type: str = "") -> str:
    charset = "utf-8"
    match = re.search(r"charset=([A-Za-z0-9._-]+)", content_type, re.IGNORECASE)
    if match:
        charset = match.group(1)
    try:
        text = raw.decode(charset, errors="replace")
    except LookupError:
        text = raw.decode("utf-8", errors="replace")
    text = re.sub(r"<[^>]+>", " ", text)
    text = "".join(character if character in "\r\n\t" or ord(character) >= 32 else " " for character in text)
    return re.sub(r"\s+", " ", text).strip()[:8192]


class WebDAVClient:
    def __init__(
        self,
        base_url: str,
        username: str,
        password: str,
        *,
        allow_insecure_private_http: bool = False,
        timeout: float = 30.0,
    ) -> None:
        self.base_url = validate_webdav_url(base_url, allow_insecure_private_http)
        self._allow_insecure_private_http = bool(allow_insecure_private_http)
        self.username = str(username or "")
        self._password = str(password or "")
        if not self.username or not self._password:
            raise ConfigError("WebDAV 用户名和密码不能为空")
        self.timeout = timeout
        credentials = f"{self.username}:{self._password}".encode("utf-8")
        self._authorization = "Basic " + base64.b64encode(credentials).decode("ascii")
        self._ssl_context = ssl.create_default_context()

    def url(self, path: str = "") -> str:
        if not path:
            return self.base_url
        candidate = str(path)
        decoded = unquote(candidate)
        parsed = urlsplit(decoded)
        if (
            not candidate
            or "\\" in candidate
            or "\x00" in candidate
            or candidate.startswith("/")
            or parsed.scheme
            or parsed.netloc
            or parsed.query
            or parsed.fragment
            or any(part in {"", ".", ".."} for part in decoded.split("/"))
        ):
            raise ValueError("WebDAV 路径必须是根目录内的规范相对路径")
        return urljoin(self.base_url, quote(candidate, safe="/%:@!$&'()*+,;=-._~"))

    def _connection(self, target_url: str) -> http.client.HTTPConnection:
        parsed = urlsplit(target_url)
        if parsed.scheme == "https":
            return http.client.HTTPSConnection(
                parsed.hostname,
                parsed.port or 443,
                timeout=self.timeout,
                context=self._ssl_context,
            )
        if not self._allow_insecure_private_http:
            raise ConfigError("公开网络 HTTP WebDAV 地址被拒绝")
        addresses = resolve_private_http_addresses(parsed.hostname or "", parsed.port or 80)
        return http.client.HTTPConnection(addresses[0], parsed.port or 80, timeout=self.timeout)

    @staticmethod
    def _host_header(target_url: str) -> str:
        parsed = urlsplit(target_url)
        return parsed.netloc

    @staticmethod
    def _request_target(target_url: str) -> str:
        parsed = urlsplit(target_url)
        target = parsed.path or "/"
        if parsed.query:
            target += "?" + parsed.query
        return target

    def request(
        self,
        method: str,
        path: str,
        *,
        body: bytes | Path | BinaryIO | None = None,
        headers: dict[str, str] | None = None,
        expected: Iterable[int] = (200,),
        max_response_bytes: int = DEFAULT_JSON_LIMIT,
        output_path: Path | None = None,
        _target_url: str | None = None,
        _redirects: int = 0,
    ) -> WebDAVResponse:
        target_url = _target_url or self.url(path)
        if _origin(target_url) != _origin(self.base_url):
            raise RedirectRejectedError("WebDAV 跨主机重定向已被拒绝", target=target_url)
        if _redirects > 4:
            raise WebDAVError("WebDAV 重定向次数过多", target=target_url)

        request_headers = {
            "Authorization": self._authorization,
            "Host": self._host_header(target_url),
            "User-Agent": "Yuji/V0.29 WebDAV",
            "Connection": "close",
        }
        request_headers.update(headers or {})
        stream: BinaryIO | None = None
        close_stream = False
        if isinstance(body, bytes):
            request_headers["Content-Length"] = str(len(body))
            stream = io.BytesIO(body)
            close_stream = True
        elif isinstance(body, Path):
            request_headers["Content-Length"] = str(body.stat().st_size)
            stream = body.open("rb")
            close_stream = True
        elif body is not None:
            stream = body
            if "Content-Length" not in request_headers:
                raise ValueError("stream requests require Content-Length")
        else:
            request_headers.setdefault("Content-Length", "0")

        connection = self._connection(target_url)
        try:
            connection.putrequest(method.upper(), self._request_target(target_url), skip_host=True)
            for name, value in request_headers.items():
                connection.putheader(name, value)
            connection.endheaders()
            if stream is not None:
                while True:
                    chunk = stream.read(STREAM_BUFFER_SIZE)
                    if not chunk:
                        break
                    connection.send(chunk)
            response = connection.getresponse()
            response_headers = {name.casefold(): value for name, value in response.getheaders()}

            if response.status in REDIRECT_STATUSES:
                location = response_headers.get("location", "")
                response.read(ERROR_BODY_LIMIT)
                redirected = urljoin(target_url, location)
                if not location or _origin(redirected) != _origin(target_url):
                    raise RedirectRejectedError(
                        "WebDAV 跨主机重定向已被拒绝，Authorization 未转发",
                        status=response.status,
                        target=redirected,
                    )
                if stream is not None and hasattr(stream, "seek"):
                    stream.seek(0)
                return self.request(
                    method,
                    path,
                    body=stream,
                    headers={key: value for key, value in request_headers.items() if key not in {"Authorization", "Connection"}},
                    expected=expected,
                    max_response_bytes=max_response_bytes,
                    output_path=output_path,
                    _target_url=redirected,
                    _redirects=_redirects + 1,
                )

            if response.status not in set(expected):
                raw = response.read(ERROR_BODY_LIMIT + 1)
                reason = _safe_error_text(raw[:ERROR_BODY_LIMIT], response_headers.get("content-type", ""))
                summary = f"WebDAV {method.upper()} 失败（HTTP {response.status}）"
                if reason:
                    summary += f"：{reason}"
                raise WebDAVError(
                    summary,
                    status=response.status,
                    reason=reason,
                    retry_after=response_headers.get("retry-after", ""),
                    target=target_url,
                )

            if output_path is not None:
                output_path.parent.mkdir(parents=True, exist_ok=True)
                temporary = output_path.with_name("." + output_path.name + ".part")
                total = 0
                try:
                    with temporary.open("wb") as output:
                        while True:
                            chunk = response.read(STREAM_BUFFER_SIZE)
                            if not chunk:
                                break
                            total += len(chunk)
                            if max_response_bytes and total > max_response_bytes:
                                raise WebDAVError("WebDAV 响应超过允许大小", status=response.status, target=target_url)
                            output.write(chunk)
                    temporary.replace(output_path)
                finally:
                    temporary.unlink(missing_ok=True)
                response_body = b""
            else:
                response_body = response.read(max_response_bytes + 1 if max_response_bytes else None)
                if max_response_bytes and len(response_body) > max_response_bytes:
                    raise WebDAVError("WebDAV 响应超过允许大小", status=response.status, target=target_url)
            return WebDAVResponse(response.status, response.reason, response_headers, response_body)
        except (ssl.SSLError, OSError, http.client.HTTPException) as error:
            if isinstance(error, WebDAVError):
                raise
            raise WebDAVError(f"WebDAV 连接失败：{error}", target=target_url) from error
        finally:
            if close_stream and stream is not None:
                stream.close()
            connection.close()

    def put_bytes(
        self,
        path: str,
        data: bytes,
        *,
        if_match: str = "",
        if_none_match: str = "",
        content_type: str = "application/octet-stream",
    ) -> str:
        headers = {"Content-Type": content_type}
        if if_match:
            headers["If-Match"] = if_match
        if if_none_match:
            headers["If-None-Match"] = if_none_match
        return self.request("PUT", path, body=data, headers=headers, expected=(200, 201, 204)).etag

    def put_file(self, path: str, file_path: Path, *, if_none_match: str = "") -> str:
        headers = {"Content-Type": "application/octet-stream"}
        if if_none_match:
            headers["If-None-Match"] = if_none_match
        return self.request("PUT", path, body=file_path, headers=headers, expected=(200, 201, 204)).etag

    def get_bytes(self, path: str, *, max_bytes: int = DEFAULT_JSON_LIMIT) -> tuple[bytes, str]:
        response = self.request("GET", path, expected=(200,), max_response_bytes=max_bytes)
        return response.body, response.etag

    def get_if_changed(
        self,
        path: str,
        etag: str,
        *,
        max_bytes: int = DEFAULT_JSON_LIMIT,
    ) -> tuple[bytes | None, str]:
        headers = {"If-None-Match": etag} if etag else {}
        response = self.request(
            "GET",
            path,
            headers=headers,
            expected=(200, 304),
            max_response_bytes=max_bytes,
        )
        if response.status == 304:
            return None, response.etag or etag
        return response.body, response.etag

    def get_optional(self, path: str, *, max_bytes: int = DEFAULT_JSON_LIMIT) -> tuple[bytes | None, str]:
        try:
            return self.get_bytes(path, max_bytes=max_bytes)
        except WebDAVError as error:
            if error.status == 404:
                return None, ""
            raise

    def download(self, path: str, output_path: Path, *, max_bytes: int = 0) -> str:
        return self.request(
            "GET",
            path,
            expected=(200,),
            max_response_bytes=max_bytes,
            output_path=output_path,
        ).etag

    def mkcol(self, path: str, *, allow_exists: bool = True) -> None:
        expected = (200, 201, 204, 405) if allow_exists else (200, 201, 204)
        self.request("MKCOL", path, expected=expected, max_response_bytes=0)

    def delete(self, path: str, *, allow_missing: bool = True) -> None:
        expected = (200, 202, 204, 404) if allow_missing else (200, 202, 204)
        self.request("DELETE", path, expected=expected, max_response_bytes=0)

    def move(self, source: str, destination: str, *, overwrite: bool = False) -> None:
        self.request(
            "MOVE",
            source,
            headers={"Destination": self.url(destination), "Overwrite": "T" if overwrite else "F"},
            expected=(201, 204),
            max_response_bytes=0,
        )

    def propfind(self, path: str, *, depth: int = 1) -> list[dict]:
        request_body = b'<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/></d:prop></d:propfind>'
        rows: list[dict] = []
        seen_hrefs: set[str] = set()
        next_url = self.url(path)
        visited_pages: set[str] = set()
        while next_url:
            if next_url in visited_pages or len(visited_pages) >= 10000:
                raise WebDAVError("WebDAV PROPFIND 分页循环或页数异常")
            visited_pages.add(next_url)
            response = self.request(
                "PROPFIND",
                path,
                body=request_body,
                headers={"Depth": str(depth), "Content-Type": "application/xml; charset=utf-8"},
                expected=(207,),
                max_response_bytes=16 * 1024 * 1024,
                _target_url=next_url,
            )
            try:
                root = ET.fromstring(response.body)
            except ET.ParseError as error:
                raise WebDAVError("WebDAV PROPFIND 返回无效 XML", status=response.status) from error
            for item in root.findall("{DAV:}response"):
                href = item.findtext("{DAV:}href", default="")
                prop = item.find(".//{DAV:}prop")
                if not href or prop is None or href in seen_hrefs:
                    continue
                seen_hrefs.add(href)
                resource_type = prop.find("{DAV:}resourcetype")
                rows.append(
                    {
                        "href": href,
                        "etag": prop.findtext("{DAV:}getetag", default=""),
                        "size": int(prop.findtext("{DAV:}getcontentlength", default="0") or 0),
                        "isCollection": resource_type is not None and resource_type.find("{DAV:}collection") is not None,
                    }
                )
            continuation = response.headers.get("x-next-page", "") or response.headers.get("next-page", "")
            if not continuation:
                for element in root.iter():
                    local_name = element.tag.rsplit("}", 1)[-1].casefold()
                    if local_name in {"next-page", "nextpage", "continuation", "continuation-href"} and (element.text or "").strip():
                        continuation = (element.text or "").strip()
                        break
            next_url = urljoin(next_url, continuation) if continuation else ""
        return rows
