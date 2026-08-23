"""Fan-out dispatcher — turns relay events into APNs sends.

One process-wide :class:`PushDispatcher` owns:

- the :class:`~.apns.APNsClient` (HTTP/2 + cached provider JWT),
- the :class:`~.devices.DeviceStore` (``~/.hermes/talaria-push/devices.json``),
- a daemon worker thread draining a bounded queue, so hook callbacks on
  agent threads never block on network I/O,
- an in-memory dedupe window so the same logical event (e.g. one approval
  observed twice) never double-buzzes a phone.

Payload contract (shared with the Talaria iOS client — see HANDOFF spec):

.. code-block:: json

    {
      "aps": {
        "alert": {"title": "...", "body": "..."},
        "sound": "default",
        "thread-id": "<bot>",
        "category": "TALARIA_APPROVAL",
        "interruption-level": "time-sensitive"
      },
      "kind": "approval",
      "bot": "<profile name>",
      "session_id": "<hermes session id>",
      "approval_request_id": "<uuid hex or empty>",
      "title": "...",
      "body": "...",
      "deeplink": "talaria://approvals"
    }

``kind`` is one of ``approval | long_task | response | mention | routine |
gateway``.
Deep-link routing follows the HANDOFF spec: approval -> Approvals screen,
gateway -> Connections screen, everything else -> that bot's chat.
"""

from __future__ import annotations

import hashlib
import base64
import io
import json
import logging
import os
import queue
import stat
import threading
import time
import urllib.parse
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from .apns import APNsClient
from .config import apns_settings, relay_settings
from .devices import get_store

logger = logging.getLogger("talaria_push")

_QUEUE_MAX = 256
_TITLE_MAX = 120
_BODY_MAX = 900  # Readability ceiling; the serialized byte budget is authoritative.
# APNs rejects payloads at 4096 bytes. Keep a margin for provider-side JSON
# framing/encoding changes; response bodies are duplicated in aps.alert.body
# and the top-level body, so a character-only cap is not sufficient.
APNS_PAYLOAD_SAFE_BYTES = 3800
BOT_DISPLAY_NAME_KEY = "bot_display_name"
BOT_AVATAR_KEY = "bot_avatar"
BOT_AVATAR_MIME_KEY = "mime"
BOT_AVATAR_DATA_KEY = "data"
_AVATAR_SOURCE_MAX_BYTES = 256 * 1024
_AVATAR_PAYLOAD_MAX_BYTES = 1400
_AVATAR_EDGE_PX = 40
_AVATAR_MIME_ALLOWLIST = {"image/png", "image/jpeg"}
_PROFILE_META_MAX_BYTES = 128 * 1024

# APNs category per event kind (the iOS client registers matching
# UNNotificationCategory actions — TALARIA_APPROVAL carries the
# actionable Approve / Later buttons).
CATEGORIES = {
    "approval": "TALARIA_APPROVAL",
    "long_task": "TALARIA_TASK",
    "response": "TALARIA_RESPONSE",
    "mention": "TALARIA_MENTION",
    "routine": "TALARIA_ROUTINE",
    "gateway": "TALARIA_GATEWAY",
}

# interruption-level per kind. "time-sensitive" needs the Time Sensitive
# Notifications capability on the app id ("critical" would need a special
# Apple entitlement, so the relay deliberately stops at time-sensitive).
INTERRUPTION_LEVELS = {
    "approval": "time-sensitive",
    "gateway": "time-sensitive",
    "response": "active",
    "mention": "active",
    "long_task": "active",
    "routine": "active",
}

_DEFAULT_DEDUPE_S = 20.0
DEFAULT_TEST_KIND = "mention"

# Never leave an actionable approval in APNs after Hermes' normal blocking
# timeout. Other notifications also receive finite relevance windows so a
# phone coming online days later does not present stale operational state.
_EXPIRATION_TTL_S = {
    "approval": 5 * 60,
    "gateway": 10 * 60,
    "mention": 60 * 60,
    "response": 60 * 60,
    "long_task": 24 * 60 * 60,
    "routine": 24 * 60 * 60,
}


def _safe_text(value: Any) -> str:
    """Return APNs-safe text without letting malformed hook data leak out.

    Hermes normally supplies strings, but provider output can contain lone
    UTF-16 surrogates and a plugin hook should never turn an unusual response
    object into an APNs/JSON failure. Preserve normal whitespace used by
    markdown while dropping non-printing controls and replacing surrogates.
    """
    if value is None:
        return ""
    if isinstance(value, str):
        text = value
    else:
        try:
            text = str(value)
        except Exception:
            return ""
    out = []
    for char in text:
        code = ord(char)
        if 0xD800 <= code <= 0xDFFF:
            out.append("\ufffd")
        elif code in (9, 10, 13) or (code >= 0x20 and code != 0x7F):
            out.append(char)
    return "".join(out)


def _truncate(text: Any, limit: int) -> str:
    text = _safe_text(text).strip()
    if limit <= 0:
        return ""
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


@dataclass(frozen=True)
class ProfileAvatar:
    """Tiny, metadata-free local portrait safe to embed in one APNs payload."""

    mime: str
    data: bytes


@dataclass(frozen=True)
class ProfilePresentation:
    """Display-only profile identity; raw routing identity remains separate."""

    display_name: str
    avatar: Optional[ProfileAvatar] = None


def response_display_name(bot: Any, configured_display_name: Any = "") -> str:
    """Return a truthful response title without inventing a friendly alias."""
    configured = _truncate(configured_display_name, _TITLE_MAX)
    if configured:
        return configured
    raw = _truncate(bot, _TITLE_MAX)
    return "Hermes" if raw == "default" or not raw else raw


def _current_profile_home() -> Optional[Path]:
    """Resolve the hook's context-local profile home, never another roster row."""
    try:
        from hermes_constants import get_hermes_home  # type: ignore

        return Path(get_hermes_home()).expanduser().resolve()
    except Exception:
        raw = os.environ.get("HERMES_HOME", "").strip()
        return Path(raw).expanduser().resolve() if raw else None


def _read_current_profile_meta(home: Path) -> Dict[str, Any]:
    """Read only the context profile's bounded profile.yaml with safe YAML.

    Hermes' public ``read_profile_meta`` projection deliberately drops
    ``ui_meta``. Bot Mode's visible configured title lives at
    ``ui_meta['hermes-bots']['title']``, so this narrow read is the only way to
    preserve the desktop-authored name without consulting another profile.
    """
    path = home / "profile.yaml"
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            return {}
        if info.st_size <= 0 or info.st_size > _PROFILE_META_MAX_BYTES:
            return {}
        import yaml  # type: ignore

        value = yaml.safe_load(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except Exception:
        return {}


def _configured_profile_display_name(meta: Dict[str, Any]) -> str:
    ui_meta = meta.get("ui_meta")
    bot_mode = ui_meta.get("hermes-bots") if isinstance(ui_meta, dict) else None
    title = bot_mode.get("title") if isinstance(bot_mode, dict) else None
    if isinstance(title, str) and title.strip():
        return title
    display_name = meta.get("display_name")
    return display_name if isinstance(display_name, str) else ""


def _avatar_mime(data: bytes) -> str:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    return ""


def _read_bounded_avatar_source(home: Path) -> Optional[bytes]:
    """Open the exact context-local avatar without following any symlink.

    Directory-relative ``open`` plus ``O_NOFOLLOW`` closes the lstat/read race:
    once opened, a later path replacement cannot change the inode read below.
    Platforms missing these primitives fail closed to the app icon.
    """
    nofollow = getattr(os, "O_NOFOLLOW", None)
    directory = getattr(os, "O_DIRECTORY", None)
    if nofollow is None or directory is None:
        return None
    home_fd: Optional[int] = None
    assets_fd: Optional[int] = None
    avatar_fd: Optional[int] = None
    try:
        home_fd = os.open(home, os.O_RDONLY | directory | nofollow)
        assets_fd = os.open(
            "assets", os.O_RDONLY | directory | nofollow, dir_fd=home_fd)
        avatar_fd = os.open(
            "avatar.png", os.O_RDONLY | nofollow, dir_fd=assets_fd)
        info = os.fstat(avatar_fd)
        if not stat.S_ISREG(info.st_mode):
            return None
        if info.st_size <= 0 or info.st_size > _AVATAR_SOURCE_MAX_BYTES:
            return None
        chunks: List[bytes] = []
        remaining = info.st_size
        while remaining:
            chunk = os.read(avatar_fd, min(remaining, 64 * 1024))
            if not chunk:
                return None
            chunks.append(chunk)
            remaining -= len(chunk)
        # Reject growth after fstat instead of reading an unbounded replacement.
        if os.read(avatar_fd, 1):
            return None
        return b"".join(chunks)
    except (OSError, TypeError, ValueError):
        return None
    finally:
        for descriptor in (avatar_fd, assets_fd, home_fd):
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass


def _bounded_profile_avatar(home: Path) -> Optional[ProfileAvatar]:
    """Read only ``<context home>/assets/avatar.png`` and re-encode to a tiny image.

    No URL, token, or arbitrary metadata path crosses this boundary. Symlinks,
    non-regular files, oversized inputs, unsupported formats, and unavailable
    optional image tooling all fail closed to the ordinary app-icon fallback.
    """
    source = _read_bounded_avatar_source(home)
    if source is None:
        return None

    try:
        from PIL import Image  # type: ignore
    except ImportError:
        mime = _avatar_mime(source)
        if mime in _AVATAR_MIME_ALLOWLIST and len(source) <= _AVATAR_PAYLOAD_MAX_BYTES:
            return ProfileAvatar(mime, source)
        return None

    try:
        with Image.open(io.BytesIO(source)) as image:
            if image.width <= 0 or image.height <= 0:
                return None
            if image.width > 4096 or image.height > 4096:
                return None
            resampling = getattr(getattr(Image, "Resampling", Image), "LANCZOS")
            image.thumbnail((_AVATAR_EDGE_PX, _AVATAR_EDGE_PX), resampling)

            png = io.BytesIO()
            image.save(png, format="PNG", optimize=True)
            png_data = png.getvalue()
            if 0 < len(png_data) <= _AVATAR_PAYLOAD_MAX_BYTES:
                return ProfileAvatar("image/png", png_data)

            rgba = image.convert("RGBA")
            flattened = Image.new("RGB", rgba.size, (255, 255, 255))
            flattened.paste(rgba, mask=rgba.getchannel("A"))
            jpeg = io.BytesIO()
            flattened.save(jpeg, format="JPEG", quality=72, optimize=True)
            jpeg_data = jpeg.getvalue()
            if 0 < len(jpeg_data) <= _AVATAR_PAYLOAD_MAX_BYTES:
                return ProfileAvatar("image/jpeg", jpeg_data)
            return None
    except Exception:
        return None


def current_profile_presentation(bot: str) -> ProfilePresentation:
    """Resolve display_name/avatar from the exact context-local profile."""
    home = _current_profile_home()
    configured = ""
    avatar: Optional[ProfileAvatar] = None
    if home is not None:
        meta = _read_current_profile_meta(home)
        configured = _configured_profile_display_name(meta)
        avatar = _bounded_profile_avatar(home)
    return ProfilePresentation(
        display_name=response_display_name(bot, configured),
        avatar=avatar,
    )


def _payload_size(payload: Dict[str, Any]) -> int:
    """Return a conservative compact JSON size for an APNs payload.

    Hermes/httpx currently emits UTF-8 JSON directly, but measuring with
    ``ensure_ascii=True`` also covers transports that escape CJK/emoji before
    sending. The resulting budget is intentionally conservative.
    """
    try:
        return len(json.dumps(
            payload,
            ensure_ascii=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8"))
    except (TypeError, ValueError):
        # Keep payload construction fail-open for legacy/custom event extras;
        # APNsClient remains the final delivery boundary and will report an
        # unserialisable payload without taking down the hook worker.
        return APNS_PAYLOAD_SAFE_BYTES + 1


def _fit_payload_body(payload: Dict[str, Any], source_body: Any) -> None:
    """Fit optional presentation around immutable routing identity.

    Raw ``bot``, ``gateway_id``, and ``session_id`` are never shortened or
    removed. If those fixed fields cannot fit after every optional display and
    duplicated route field is reduced, raise instead of handing APNs an
    oversized payload.
    """
    if _payload_size(payload) <= APNS_PAYLOAD_SAFE_BYTES:
        return

    # The response text is the notification's meaning; the portrait is an
    # optional decoration. Drop it before shortening the body. This also makes
    # source stamping safe when gateway_id/deeplink are added after the first
    # event-level fit.
    if BOT_AVATAR_KEY in payload:
        payload.pop(BOT_AVATAR_KEY, None)
        if _payload_size(payload) <= APNS_PAYLOAD_SAFE_BYTES:
            return

    # The URL duplicates the raw, source-qualified routing fields consumed by
    # the notification delegate. It is useful for external URL handoff but is
    # optional inside an APNs tap and may be much larger after source stamping.
    payload.pop("deeplink", None)
    if _payload_size(payload) <= APNS_PAYLOAD_SAFE_BYTES:
        return

    # Display identity is duplicated in the actual alert title. Response
    # tracing is diagnostic only. Shed each optional copy before spending even
    # one byte of the user-visible response or title.
    for key in (BOT_DISPLAY_NAME_KEY, "title", "task_id", "turn_id"):
        payload.pop(key, None)
        if _payload_size(payload) <= APNS_PAYLOAD_SAFE_BYTES:
            return

    text = _safe_text(source_body).strip()
    aps = payload.get("aps")
    alert = aps.get("alert") if isinstance(aps, dict) else None
    if not isinstance(alert, dict):
        return

    full_body = _truncate(text, _BODY_MAX)
    full_title = _safe_text(alert.get("title", "")).strip()

    def set_body(value: str, *, duplicate: bool = True) -> None:
        alert["body"] = value
        if duplicate:
            payload["body"] = value

    def fit_prefix(
        text: str, limit: int, setter: Callable[[str], None],
    ) -> tuple[str, bool]:
        """Set the longest Unicode-character prefix that fits the byte cap."""
        high = min(len(text), limit)
        # When the complete string is within the character ceiling it has no
        # ellipsis. Under conservative ensure_ascii JSON, `Done.` can therefore
        # be *smaller* than `Don…`; test that non-monotonic endpoint explicitly
        # before binary-searching the ellipsized prefixes below it.
        complete = _truncate(text, high)
        setter(complete)
        if _payload_size(payload) <= APNS_PAYLOAD_SAFE_BYTES:
            return complete, True

        low = 0
        high -= 1
        best = ""
        found = False
        while low <= high:
            mid = (low + high) // 2
            candidate = _truncate(text, mid)
            setter(candidate)
            if _payload_size(payload) <= APNS_PAYLOAD_SAFE_BYTES:
                best = candidate
                found = True
                low = mid + 1
            else:
                high = mid - 1
        setter(best)
        return best, found

    # A short response such as "Done." must not disappear merely because a
    # cosmetic title is unusually expensive once escaped. Shorten the real
    # title first only when that lets the complete response (and its duplicate)
    # survive. Byte measurement makes this safe for emoji/CJK without slicing a
    # UTF-8 sequence.
    alert["title"] = full_title
    set_body(full_body)
    best_title, title_fit = fit_prefix(
        full_title, _TITLE_MAX, lambda value: alert.__setitem__("title", value))
    if title_fit:
        return

    # A normal-size title is more useful intact beside a long response. Restore
    # it, then find the largest response prefix while retaining the top-level
    # duplicate consumed by older clients and the notification extension.
    alert["title"] = full_title
    best_body, body_fit = fit_prefix(
        text, _BODY_MAX, lambda value: set_body(value))
    if body_fit and (best_body or not text):
        return

    # The top-level body duplicates aps.alert.body. Drop only this compatibility
    # copy before allowing a non-empty visible response to be crowded out.
    payload.pop("body", None)
    alert["title"] = full_title
    set_body(full_body, duplicate=False)
    best_title, title_fit = fit_prefix(
        full_title, _TITLE_MAX, lambda value: alert.__setitem__("title", value))
    if title_fit:
        return

    alert["title"] = full_title
    best_body, body_fit = fit_prefix(
        text, _BODY_MAX, lambda value: set_body(value, duplicate=False))
    if body_fit and (best_body or not text):
        return

    # If a pathological title left room only for an empty response, keep at
    # least a measured response prefix and the smallest truthful title whenever
    # the fixed authority permits both.
    if text and full_title:
        alert["title"] = _truncate(full_title, 1)
        best_body, body_fit = fit_prefix(
            text, _BODY_MAX, lambda value: set_body(value, duplicate=False))
        if body_fit and best_body:
            return

    alert["title"] = ""
    best_body, body_fit = fit_prefix(
        text, _BODY_MAX, lambda value: set_body(value, duplicate=False))
    if body_fit and (best_body or not text):
        return

    # An alert title is optional at the absolute boundary. Removing the empty
    # key is the final way to prove that fixed route + visible body can fit; do
    # not refuse (or return an empty body) over the JSON cost of `"title":""`.
    alert.pop("title", None)
    best_body, body_fit = fit_prefix(
        text, _BODY_MAX, lambda value: set_body(value, duplicate=False))
    if body_fit:
        return

    size = _payload_size(payload)
    logger.warning(
        "talaria-push: refusing oversized payload (%d bytes) with fixed routing authority",
        size,
    )
    raise ValueError(
        f"APNs payload fixed routing authority exceeds {APNS_PAYLOAD_SAFE_BYTES} bytes"
    )


def build_deeplink(
    kind: str, bot: str, session_id: str = "", gateway_id: str = "",
) -> str:
    """Deep-link routing data per the HANDOFF spec.

    Route space matches the iOS client's DeepLink parser exactly:
    talaria://approvals, talaria://connections, talaria://bot/<id>.
    """
    if kind == "approval":
        return "talaria://approvals"
    if kind == "gateway":
        return "talaria://connections"
    base = f"talaria://bot/{urllib.parse.quote(bot or 'default', safe='')}"
    query: list[str] = []
    if session_id:
        query.append(f"session_id={urllib.parse.quote(session_id, safe='')}")
    if kind == "response" and gateway_id:
        query.append(f"gateway_id={urllib.parse.quote(gateway_id, safe='')}")
    if query:
        return base + "?" + "&".join(query)
    return base


@dataclass
class PushEvent:
    """One logical notification, before device fan-out."""

    kind: str                       # approval | long_task | response | mention | routine | gateway
    bot: str                        # hermes profile ("default" for the root profile)
    title: str
    body: str
    session_id: str = ""
    approval_request_id: str = ""
    collapse_id: Optional[str] = None
    dedupe_key: Optional[str] = None
    dedupe_window_s: float = _DEFAULT_DEDUPE_S
    extra: Dict[str, Any] = field(default_factory=dict)
    expiration: Optional[int] = None

    def __post_init__(self) -> None:
        if self.expiration is None:
            ttl = _EXPIRATION_TTL_S.get(self.kind, 60 * 60)
            self.expiration = int(time.time()) + ttl

    def apns_payload(self) -> Dict[str, Any]:
        aps: Dict[str, Any] = {
            "alert": {
                "title": _truncate(self.title, _TITLE_MAX),
                "body": _truncate(self.body, _BODY_MAX),
            },
            "sound": "default",
            "thread-id": self.bot or "hermes",
            "category": CATEGORIES.get(self.kind, "TALARIA_EVENT"),
            "interruption-level": INTERRUPTION_LEVELS.get(self.kind, "active"),
            "mutable-content": 1,
        }
        payload: Dict[str, Any] = {
            "aps": aps,
            "kind": self.kind,
            "bot": self.bot,
            "session_id": self.session_id,
            "approval_request_id": self.approval_request_id,
            "title": _truncate(self.title, _TITLE_MAX),
            "body": _truncate(self.body, _BODY_MAX),
            "deeplink": build_deeplink(self.kind, self.bot, self.session_id),
        }
        for key, value in self.extra.items():
            # Custom keys must not collide with the reserved contract keys.
            if key not in payload:
                payload[key] = value
        _fit_payload_body(payload, self.body)
        return payload


def payload_for_device(event: PushEvent, device: Dict[str, Any]) -> Dict[str, Any]:
    """Bind one logical event to one app registration's source identity."""
    payload = event.apns_payload()
    gateway_id = str(device.get("gateway_id") or "").strip()
    if gateway_id:
        payload["gateway_id"] = gateway_id
        if event.kind == "response":
            payload["deeplink"] = build_deeplink(
                event.kind, event.bot, event.session_id, gateway_id,
            )
    # Source stamping (especially the response deeplink) changes the JSON
    # size, so budget once more after binding the concrete device identity.
    _fit_payload_body(payload, event.body)
    return payload


def synthetic_test_event(kind: str) -> PushEvent:
    """Build a display-only test that can never authorize a live action."""
    return PushEvent(
        kind=kind,
        bot="talaria-test",
        title="Talaria test push",
        body=f"Relay is working — this is a {kind!r}-shaped test notification.",
        session_id="",
        approval_request_id="",
        collapse_id="talaria-test",
        dedupe_key=None,
    )


class PushDispatcher:
    """Queue + worker thread + dedupe around the APNs client."""

    def __init__(self) -> None:
        self._queue: "queue.Queue[PushEvent]" = queue.Queue(maxsize=_QUEUE_MAX)
        self._worker: Optional[threading.Thread] = None
        self._worker_lock = threading.Lock()
        self._client: Optional[APNsClient] = None
        self._dedupe: Dict[str, float] = {}
        self._dedupe_lock = threading.Lock()
        self._warned_unconfigured = False

    # -- public API ---------------------------------------------------------

    def notify(self, event: PushEvent) -> bool:
        """Enqueue one event for fan-out. Returns False when suppressed.

        Never raises and never blocks on network — safe to call from
        agent/gateway hook callbacks.
        """
        settings = relay_settings()
        if not settings.event_enabled(event.kind):
            logger.debug("talaria-push: kind %r disabled; dropping", event.kind)
            return False
        # A final response is the completion notification for a normal
        # non-interrupted turn. When that kind is enabled, the legacy duration-based event
        # would buzz for the same turn as well. Keep this guard in the shared
        # dispatcher so sidecar and hook mode cannot reintroduce the duplicate.
        if event.kind == "long_task" and settings.event_enabled("response"):
            logger.debug(
                "talaria-push: long_task suppressed while response events are enabled"
            )
            return False
        if not self._apns_ready():
            return False
        if self._is_duplicate(event):
            logger.debug(
                "talaria-push: dedupe suppressed %s (%s)",
                event.kind, event.dedupe_key,
            )
            return False
        try:
            self._queue.put_nowait(event)
        except queue.Full:
            # Shed oldest first: a stale push is worth less than a fresh one.
            try:
                self._queue.get_nowait()
                self._queue.put_nowait(event)
            except Exception:
                logger.warning("talaria-push: queue full; dropped %s", event.kind)
                return False
        self._ensure_worker()
        return True

    def clear_dedupe(self, dedupe_key: str) -> None:
        """Forget a dedupe entry (e.g. once an approval was answered)."""
        with self._dedupe_lock:
            self._dedupe.pop(dedupe_key, None)

    def flush_for_test(self, timeout: float = 15.0) -> None:
        """Block until the queue drains (used by /test endpoint + tests)."""
        deadline = time.time() + timeout
        while not self._queue.empty() and time.time() < deadline:
            time.sleep(0.05)

    # -- internals ----------------------------------------------------------

    def _apns_ready(self) -> bool:
        settings = apns_settings()
        if settings.configured:
            self._warned_unconfigured = False
            return True
        if not self._warned_unconfigured:
            logger.warning(
                "talaria-push: APNs not configured; missing %s — pushes disabled",
                ", ".join(settings.missing()),
            )
            self._warned_unconfigured = True
        return False

    def _is_duplicate(self, event: PushEvent) -> bool:
        key = event.dedupe_key
        if not key:
            return False
        now = time.time()
        with self._dedupe_lock:
            # opportunistic GC so the map can't grow unbounded
            if len(self._dedupe) > 512:
                self._dedupe = {
                    k: t for k, t in self._dedupe.items() if now - t < 3600
                }
            last = self._dedupe.get(key)
            if last is not None and now - last < event.dedupe_window_s:
                return True
            self._dedupe[key] = now
            return False

    def _ensure_worker(self) -> None:
        with self._worker_lock:
            if self._worker is not None and self._worker.is_alive():
                return
            self._worker = threading.Thread(
                target=self._run, name="talaria-push-worker", daemon=True
            )
            self._worker.start()

    def _get_client(self) -> APNsClient:
        if self._client is None:
            self._client = APNsClient(apns_settings())
        return self._client

    def _run(self) -> None:
        while True:
            event = self._queue.get()
            try:
                self._fan_out(event)
            except Exception as exc:  # never kill the worker
                logger.warning("talaria-push: fan-out failed: %s", exc)

    def _fan_out(self, event: PushEvent) -> None:
        store = get_store()
        devices = store.for_bot(event.bot)
        if not devices:
            logger.debug(
                "talaria-push: no registered device matches bot %r; dropping %s",
                event.bot, event.kind,
            )
            return
        client = self._get_client()
        for dev in devices:
            token = dev["device_token"]
            # Stamp the registration's source per device. Without it two
            # gateways that both expose `default` are indistinguishable on the
            # phone, and an actionable approval can reach the wrong machine.
            payload = payload_for_device(event, dev)
            result = client.send(
                token,
                payload,
                environment=dev.get("environment"),
                push_type="alert",
                priority=10,
                collapse_id=event.collapse_id,
                expiration=event.expiration,
            )
            if result.should_unregister:
                # 410 Unregistered / 400 BadDeviceToken — token is dead.
                logger.info(
                    "talaria-push: pruning dead device …%s (%s %s)",
                    token[-8:], result.status, result.reason,
                )
                store.remove(token)
                continue
            store.mark_result(token, result.ok)
            if result.ok:
                logger.info(
                    "talaria-push: sent %s to …%s (apns-id %s)",
                    event.kind, token[-8:], result.apns_id or "?",
                )
            elif result.retryable:
                # One bounded retry after a short pause; APNs hiccups are
                # usually transient, and approvals are time-boxed upstream.
                # ExpiredProviderToken cleared the JWT cache in APNsClient;
                # remint and retry immediately. Back-pressure/server failures
                # retain the one-second bound.
                if not (result.status == 403 and result.reason == "ExpiredProviderToken"):
                    time.sleep(1.0)
                retry = client.send(
                    token, payload,
                    environment=dev.get("environment"),
                    collapse_id=event.collapse_id,
                    expiration=event.expiration,
                )
                if retry.should_unregister:
                    store.remove(token)
                    continue
                store.mark_result(token, retry.ok)
                if not retry.ok:
                    logger.warning(
                        "talaria-push: retry failed for …%s (%s %s)",
                        token[-8:], retry.status, retry.reason,
                    )


_dispatcher: Optional[PushDispatcher] = None
_dispatcher_lock = threading.Lock()


def get_dispatcher() -> PushDispatcher:
    global _dispatcher
    if _dispatcher is None:
        with _dispatcher_lock:
            if _dispatcher is None:
                _dispatcher = PushDispatcher()
    return _dispatcher


def stable_hash(*parts: str) -> str:
    """Short stable hash for dedupe/collapse keys."""
    joined = "\x1f".join(_safe_text(p) for p in parts)
    return hashlib.sha256(joined.encode("utf-8", "replace")).hexdigest()[:16]


# -- payload/event builders (shared by hook mode and sidecar mode) ----------


def approval_event(
    *,
    bot: str,
    session_id: str,
    description: str = "",
    command: str = "",
    approval_request_id: str = "",
    pattern_key: str = "",
) -> PushEvent:
    body = description or command or "A command is waiting for your approval."
    if description and command and command not in description:
        body = f"{description}\n{command}"
    return PushEvent(
        kind="approval",
        bot=bot,
        title=f"{bot} needs approval",
        body=body,
        session_id=session_id,
        approval_request_id=approval_request_id,
        collapse_id=f"approval-{stable_hash(bot, session_id)}",
        dedupe_key=(
            f"approval:{approval_request_id}"
            if approval_request_id
            else f"approval:{stable_hash(bot, session_id, pattern_key, command)}"
        ),
        dedupe_window_s=relay_settings().approval_dedupe_window_s,
    )


def long_task_event(
    *, bot: str, session_id: str, duration_s: float,
    ok: bool = True, summary: str = "",
) -> PushEvent:
    minutes = max(1, int(duration_s // 60))
    verdict = "finished" if ok else "stopped"
    body = summary or f"A {minutes}-minute task just {verdict}."
    return PushEvent(
        kind="long_task",
        bot=bot,
        title=f"{bot}: long task {verdict}",
        body=body,
        session_id=session_id,
        collapse_id=f"task-{stable_hash(bot, session_id)}",
        dedupe_key=f"long_task:{stable_hash(bot, session_id, str(int(duration_s)))}",
    )


def response_event(
    *,
    bot: str,
    session_id: str,
    turn_id: str = "",
    task_id: str = "",
    response: str = "",
    assistant_response: Optional[str] = None,
    display_name: str = "",
    avatar: Optional[ProfileAvatar] = None,
) -> PushEvent:
    """Build the final assistant-response notification.

    ``post_llm_call`` calls this with ``assistant_response`` in the pinned
    Hermes shape; ``response`` remains the concise builder-facing name and is
    useful to sidecar/tests. The full identity tuple is part of the dedupe key
    so two turns with the same text never suppress one another.
    """
    if assistant_response is not None:
        response = assistant_response
    bot_text = _safe_text(bot).strip()
    session_text = _safe_text(session_id).strip()
    turn_text = _safe_text(turn_id).strip()
    task_text = _safe_text(task_id).strip()
    response_text = _safe_text(response)
    title = response_display_name(bot_text, display_name)
    identity = stable_hash(
        bot_text,
        session_text,
        turn_text,
        task_text,
        response_text,
    )
    extra: Dict[str, Any] = {
        "task_id": task_text,
        "turn_id": turn_text,
        BOT_DISPLAY_NAME_KEY: title,
    }
    if avatar is not None and avatar.mime in _AVATAR_MIME_ALLOWLIST \
            and 0 < len(avatar.data) <= _AVATAR_PAYLOAD_MAX_BYTES:
        extra[BOT_AVATAR_KEY] = {
            BOT_AVATAR_MIME_KEY: avatar.mime,
            BOT_AVATAR_DATA_KEY: base64.b64encode(avatar.data).decode("ascii"),
        }
    return PushEvent(
        kind="response",
        bot=bot_text,
        title=title,
        body=response_text,
        session_id=session_text,
        collapse_id=f"response-{stable_hash(bot_text, session_text)}",
        dedupe_key=f"response:{identity}",
        extra=extra,
    )


def mention_event(
    *, bot: str, platform: str, sender: str, text: str, session_id: str = "",
) -> PushEvent:
    who = sender or "someone"
    where = f" on {platform}" if platform else ""
    return PushEvent(
        kind="mention",
        bot=bot,
        title=f"{who} mentioned @{bot}{where}",
        body=text or "(no message text)",
        session_id=session_id,
        collapse_id=f"mention-{stable_hash(bot, platform, sender)}",
        dedupe_key=f"mention:{stable_hash(bot, platform, sender, text)}",
        extra={"platform": platform, "sender": who},
    )


def routine_event(
    *, bot: str, routine: str = "", session_id: str = "",
    ok: bool = True, detail: str = "", display_name: str = "",
) -> PushEvent:
    name = routine or "routine"
    verdict = "finished" if ok else "failed"
    title = response_display_name(bot, display_name)
    return PushEvent(
        kind="routine",
        bot=bot,
        title=title,
        body=detail or f"The scheduled routine {verdict}.",
        session_id=session_id,
        collapse_id=f"routine-{stable_hash(bot, name)}",
        dedupe_key=f"routine:{stable_hash(bot, name, session_id, verdict)}",
        extra={"routine": name, BOT_DISPLAY_NAME_KEY: title},
    )


def gateway_event(*, online: bool, base_url: str = "", detail: str = "") -> PushEvent:
    state = "recovered" if online else "offline"
    return PushEvent(
        kind="gateway",
        bot="hermes",
        title=f"Gateway {state}",
        body=detail or (
            "The Hermes gateway is reachable again."
            if online
            else "The Hermes gateway stopped responding."
        ),
        collapse_id="gateway-state",
        dedupe_key=f"gateway:{state}:{stable_hash(base_url)}",
        dedupe_window_s=120.0,
        extra={"gateway_url": base_url} if base_url else {},
    )
