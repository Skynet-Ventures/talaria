"""Configuration for the Talaria push relay.

Everything is environment-driven so the plugin works identically whether
it is loaded inside a hermes process or run as a standalone sidecar.
See ``.env.example`` at the repository root for the full list.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger("talaria_push")

# Event kinds the relay knows how to emit.
ALL_EVENT_KINDS = (
    "approval",
    "long_task",
    "response",
    "mention",
    "routine",
    "gateway",
)

# Routine remains a recognized wire/display kind for compatibility and the
# synthetic presentation probe, but no live producer may emit it until Hermes
# supplies immutable job creator/delivery provenance.
DEFAULT_EVENT_KINDS = tuple(
    kind for kind in ALL_EVENT_KINDS if kind != "routine"
)

APNS_HOSTS = {
    "dev": "https://api.sandbox.push.apple.com",
    "prod": "https://api.push.apple.com",
}


def _truthy(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def hermes_root() -> Path:
    """Return the root hermes home (never a profile-scoped subdirectory).

    Device registrations are shared across all profiles/bots, so the store
    must live under the *root* home even when this process was started with
    ``hermes -p <profile>`` (which points ``HERMES_HOME`` at
    ``<root>/profiles/<name>``).

    Prefers the upstream helper when hermes is importable; falls back to
    unwrapping the path by hand for standalone sidecar installs.
    """
    try:
        from hermes_constants import get_default_hermes_root  # type: ignore

        return Path(get_default_hermes_root())
    except Exception:
        pass
    home = Path(os.environ.get("HERMES_HOME", "~/.hermes")).expanduser()
    if home.parent.name == "profiles" and home.parent.parent.name:
        return home.parent.parent
    return home


def current_bot() -> str:
    """Best-effort name of the bot (hermes profile) this process runs as."""
    override = os.environ.get("TALARIA_PUSH_BOT_NAME", "").strip()
    if override:
        return override

    # Hermes multiplexes profile work in one process by installing a
    # context-local HERMES_HOME override. Resolve through the pinned helper,
    # rather than reading the process environment directly, or pushes from a
    # secondary profile will be attributed to whichever profile launched the
    # process. Keep this import optional for the standalone sidecar.
    home: Optional[Path] = None
    try:
        from hermes_constants import get_hermes_home  # type: ignore

        home = Path(get_hermes_home())
    except Exception:
        pass
    if home is None:
        home = Path(os.environ.get("HERMES_HOME", "~/.hermes")).expanduser()
    if home.parent.name == "profiles":
        return home.name
    return "default"


def data_dir() -> Path:
    """``~/.hermes/talaria-push/`` (created on demand, 0700)."""
    d = hermes_root() / "talaria-push"
    try:
        d.mkdir(mode=0o700, parents=True, exist_ok=True)
        # mkdir(mode=...) is umask-filtered and ignored when the dir already
        # exists — enforce explicitly.
        os.chmod(d, 0o700)
    except OSError as exc:  # pragma: no cover - fs corner cases
        logger.warning("talaria-push: could not prepare data dir %s: %s", d, exc)
    return d


def devices_path() -> Path:
    return data_dir() / "devices.json"


@dataclass
class APNsSettings:
    """APNs token-auth credentials (``TALARIA_APNS_*``)."""

    key_p8_path: str = ""
    key_id: str = ""
    team_id: str = ""
    topic: str = ""          # the iOS app bundle id
    default_env: str = "dev"  # fallback when a device did not say

    @classmethod
    def from_env(cls) -> "APNsSettings":
        env = os.environ.get("TALARIA_APNS_ENV", "dev").strip().lower()
        if env not in APNS_HOSTS:
            logger.warning(
                "talaria-push: TALARIA_APNS_ENV=%r is not dev|prod; using dev", env
            )
            env = "dev"
        return cls(
            key_p8_path=os.environ.get("TALARIA_APNS_KEY_P8_PATH", "").strip(),
            key_id=os.environ.get("TALARIA_APNS_KEY_ID", "").strip(),
            team_id=os.environ.get("TALARIA_APNS_TEAM_ID", "").strip(),
            topic=os.environ.get("TALARIA_APNS_TOPIC", "").strip(),
            default_env=env,
        )

    @property
    def configured(self) -> bool:
        return bool(self.key_p8_path and self.key_id and self.team_id and self.topic)

    def missing(self) -> List[str]:
        out = []
        if not self.key_p8_path:
            out.append("TALARIA_APNS_KEY_P8_PATH")
        elif not Path(self.key_p8_path).expanduser().is_file():
            out.append(f"TALARIA_APNS_KEY_P8_PATH (file not found: {self.key_p8_path})")
        if not self.key_id:
            out.append("TALARIA_APNS_KEY_ID")
        if not self.team_id:
            out.append("TALARIA_APNS_TEAM_ID")
        if not self.topic:
            out.append("TALARIA_APNS_TOPIC")
        return out


@dataclass
class RelaySettings:
    """Behavioural knobs (``TALARIA_PUSH_*``)."""

    disabled: bool = False
    # Event kinds this process may emit. In-process hook mode and sidecar
    # mode overlap on some kinds; running both unfiltered would double-push.
    enabled_events: List[str] = field(default_factory=lambda: list(DEFAULT_EVENT_KINDS))
    long_task_min_s: float = 600.0
    # @handles that count as a mention of "this" agent in inbound messages.
    # Defaults to the current profile name.
    mention_handles: List[str] = field(default_factory=list)
    approval_dedupe_window_s: float = 45.0

    @classmethod
    def from_env(cls) -> "RelaySettings":
        s = cls()
        s.disabled = _truthy(os.environ.get("TALARIA_PUSH_DISABLE", ""))
        raw_events = os.environ.get("TALARIA_PUSH_EVENTS", "").strip()
        if raw_events:
            wanted = [e.strip() for e in raw_events.split(",") if e.strip()]
            unknown = [e for e in wanted if e not in ALL_EVENT_KINDS]
            if unknown:
                logger.warning(
                    "talaria-push: ignoring unknown TALARIA_PUSH_EVENTS entries: %s",
                    ", ".join(unknown),
                )
            s.enabled_events = [e for e in wanted if e in ALL_EVENT_KINDS]
        try:
            s.long_task_min_s = float(
                os.environ.get("TALARIA_PUSH_LONG_TASK_MIN_S", "600")
            )
        except ValueError:
            logger.warning("talaria-push: bad TALARIA_PUSH_LONG_TASK_MIN_S; using 600")
        raw_handles = os.environ.get("TALARIA_PUSH_MENTION_HANDLES", "").strip()
        if raw_handles:
            s.mention_handles = [
                h.strip().lstrip("@").lower()
                for h in raw_handles.split(",")
                if h.strip().lstrip("@")
            ]
        else:
            s.mention_handles = [current_bot().lower()]
        return s

    def event_enabled(self, kind: str) -> bool:
        return not self.disabled and kind in self.enabled_events


@dataclass
class SidecarSettings:
    """Standalone sidecar connection settings (``TALARIA_GATEWAY_*``)."""

    base_url: str = "http://127.0.0.1:9119"
    token: str = ""
    health_interval_s: float = 15.0
    health_failures_for_offline: int = 3
    session_rescan_debounce_s: float = 2.0

    @classmethod
    def from_env(cls) -> "SidecarSettings":
        s = cls()
        raw = os.environ.get("TALARIA_GATEWAY_URL", "").strip()
        if raw:
            s.base_url = raw.rstrip("/")
        s.token = os.environ.get("TALARIA_GATEWAY_TOKEN", "").strip()
        try:
            s.health_interval_s = float(
                os.environ.get("TALARIA_PUSH_HEALTH_INTERVAL_S", "15")
            )
        except ValueError:
            pass
        return s

    @property
    def ws_url(self) -> str:
        scheme = "wss" if self.base_url.startswith("https") else "ws"
        host = self.base_url.split("://", 1)[-1]
        return f"{scheme}://{host}/api/ws"


_apns_settings: Optional[APNsSettings] = None
_relay_settings: Optional[RelaySettings] = None


def apns_settings(refresh: bool = False) -> APNsSettings:
    global _apns_settings
    if _apns_settings is None or refresh:
        _apns_settings = APNsSettings.from_env()
    return _apns_settings


def relay_settings(refresh: bool = False) -> RelaySettings:
    global _relay_settings
    if _relay_settings is None or refresh:
        _relay_settings = RelaySettings.from_env()
    return _relay_settings
