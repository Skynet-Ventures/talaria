"""Hermes plugin hook handlers — the in-process half of the relay.

Wired by the plugin's ``register(ctx)`` (see the plugin ``__init__.py``)
into the hook surface documented in ``hermes_cli/plugins.py::VALID_HOOKS``:

======================  =====================================================
hook                    used for
======================  =====================================================
pre_approval_request    ``approval`` pushes. Fires in whatever process runs
                        the blocked agent (``hermes serve`` for WS/iOS
                        sessions, ``hermes gateway`` for messaging sessions,
                        the CLI for terminal runs). Kwargs per upstream:
                        command, description, pattern_key, pattern_keys,
                        session_key, surface, turn_id, tool_call_id,
                        session_id?. ``session_key`` is the durable identity
                        used by ``session.resume`` and ``approval.pending``;
                        the runtime ``session_id`` is never substituted into
                        an actionable push. NOTE: the hook does NOT carry the
                        approval ``request_id`` — see the README's gap
                        table. Hook-mode pushes therefore send
                        ``approval_request_id: ""`` and the iOS client
                        resolves the concrete id via the ``approval.pending``
                        RPC (or answers FIFO without an id, which
                        ``approval.respond`` supports).
post_approval_response  clears the approval dedupe entry so a re-prompt
                        after deny/timeout can buzz again.
pre_llm_call            records the turn start time per (session_id,
                        turn_id) — the "long task" stopwatch.
post_llm_call           fires once when Hermes has a final assistant response
                        ready (the pinned hook is non-interrupted and carries
                        no completed/failed flags). Used for ``response``
                        pushes only for Talaria/Desktop-addressable turns;
                        kwargs follow the pinned Hermes 18a15 shape: session_id,
                        task_id, turn_id, user_message, assistant_response,
                        conversation_history, model, platform.
on_session_end          fires at the end of every turn with completed /
                        failed / interrupted / platform. Used only for
                        ``long_task`` pushes (elapsed >= threshold) when
                        ``response`` pushes are disabled. Cron completion does
                        not carry immutable creator/delivery provenance and is
                        therefore never admitted to Talaria push.
pre_gateway_dispatch    ``mention`` pushes: observes every user-originated
                        inbound MessageEvent in the messaging gateway
                        (Telegram / Discord / A2A / ...) and scans for
                        @<handle> mentions of this bot. Observer only —
                        always returns None so dispatch is never altered.
======================  =====================================================

Every handler is wrapped so an exception can never propagate into the
agent / gateway pipeline (the upstream dispatcher isolates callbacks too;
this is belt and braces).
"""

from __future__ import annotations

import logging
import re
import threading
import time
from typing import Any, Dict, Optional, Tuple

from . import push as push_mod
from .config import current_bot, relay_settings

logger = logging.getLogger("talaria_push")

# (session_id, turn_id) -> monotonic start time
_turn_starts: Dict[Tuple[str, str], float] = {}
_turn_lock = threading.Lock()
_TURN_MAP_MAX = 512

# Surfaces whose approval prompts should push. "gateway" covers both the
# messaging gateway and the WS server (desktop/iOS sessions). "cli" means a
# human is already at the terminal; "smart" means an auxiliary LLM decides
# without a human prompt (unless it escalates, which re-fires as "gateway").
_DEFAULT_APPROVAL_SURFACES = {"gateway"}

# Only these Hermes session platforms have a Talaria/Desktop conversation that
# can truthfully receive a source-qualified response push. Standalone TUI,
# messaging adapters, CLI/server/tool sessions, cron, and missing/future
# platform values fail closed.
_RESPONSE_PUSH_PLATFORMS = frozenset({"talaria", "desktop"})


def _safe_text(value: Any) -> str:
    """Coerce hook values without allowing malformed objects to escape."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    try:
        return str(value)
    except Exception:
        return ""


def _strict_text(value: Any) -> Optional[str]:
    """Read a pinned string field without inventing an identity."""
    if value is None:
        return ""
    if not isinstance(value, str):
        return None
    return value.strip()


def _approval_surfaces() -> set:
    import os

    raw = os.environ.get("TALARIA_PUSH_APPROVAL_SURFACES", "").strip()
    if not raw:
        return set(_DEFAULT_APPROVAL_SURFACES)
    return {s.strip().lower() for s in raw.split(",") if s.strip()}


def _never_raise(fn):
    def wrapper(*args: Any, **kwargs: Any):
        try:
            return fn(*args, **kwargs)
        except Exception as exc:
            logger.warning("talaria-push: hook %s failed: %s", fn.__name__, exc)
            return None

    return wrapper


# ---------------------------------------------------------------------------
# approval
# ---------------------------------------------------------------------------


@_never_raise
def on_pre_approval_request(**kwargs: Any) -> None:
    surface = str(kwargs.get("surface") or "")
    if surface not in _approval_surfaces():
        return None
    session_key = str(kwargs.get("session_key") or "").strip()
    if not session_key:
        # A runtime session_id cannot be resumed after a cold notification
        # launch. Sending an approval-shaped payload with it would display an
        # action Talaria cannot source-qualify or answer, so fail closed.
        logger.warning(
            "talaria-push: approval hook omitted actionable push without session_key"
        )
        return None
    bot = current_bot()
    event = push_mod.approval_event(
        bot=bot,
        session_id=session_key,
        description=str(kwargs.get("description") or ""),
        command=str(kwargs.get("command") or ""),
        # Not available on the hook surface (see module docstring / README).
        approval_request_id="",
        pattern_key=str(kwargs.get("pattern_key") or ""),
    )
    push_mod.get_dispatcher().notify(event)
    return None


@_never_raise
def on_post_approval_response(**kwargs: Any) -> None:
    """Clear the dedupe entry once the approval was answered/timed out."""
    bot = current_bot()
    session_id = str(kwargs.get("session_key") or "").strip()
    if not session_id:
        return None
    key = "approval:" + push_mod.stable_hash(
        bot,
        session_id,
        str(kwargs.get("pattern_key") or ""),
        str(kwargs.get("command") or ""),
    )
    push_mod.get_dispatcher().clear_dedupe(key)
    return None


# ---------------------------------------------------------------------------
# final responses / long task
# ---------------------------------------------------------------------------


@_never_raise
def on_post_llm_call(**kwargs: Any) -> None:
    """Push a final assistant response when Hermes makes it ready.

    Hermes invokes this observer after the tool loop has produced a final
    response and has not been interrupted. Keep explicit event filtering here
    as well as in the dispatcher so alternate hosts with a lightweight
    dispatcher preserve the same allow-list semantics.
    """
    settings = relay_settings()
    if not settings.event_enabled("response"):
        return None

    response = kwargs.get("assistant_response")
    # The pinned hook contract carries a string. Do not stringify arbitrary
    # malformed objects into a notification, and do not emit an empty alert.
    if not isinstance(response, str) or not response.strip():
        return None

    platform = kwargs.get("platform")
    if not isinstance(platform, str) or platform not in _RESPONSE_PUSH_PLATFORMS:
        return None

    bot = _strict_text(current_bot())
    session_id = _strict_text(kwargs.get("session_id"))
    turn_id = _strict_text(kwargs.get("turn_id"))
    task_id = _strict_text(kwargs.get("task_id"))
    if not bot or not session_id or turn_id is None or task_id is None:
        # A response without its profile/session cannot be source-qualified
        # on the receiving device, so fail closed.
        return None

    presentation = push_mod.current_profile_presentation(bot)
    push_mod.get_dispatcher().notify(push_mod.response_event(
        bot=bot,
        session_id=session_id,
        turn_id=turn_id,
        task_id=task_id,
        assistant_response=response,
        display_name=presentation.display_name,
        avatar=presentation.avatar,
    ))
    return None


@_never_raise
def on_pre_llm_call(**kwargs: Any) -> None:
    session_id = str(kwargs.get("session_id") or "")
    turn_id = str(kwargs.get("turn_id") or "")
    if not session_id:
        return None
    key = (session_id, turn_id)
    with _turn_lock:
        # setdefault: pre_llm_call fires once per turn *before* the tool
        # loop, but be defensive against future multi-fire semantics.
        _turn_starts.setdefault(key, time.monotonic())
        if len(_turn_starts) > _TURN_MAP_MAX:
            # Shed oldest entries; losing one stopwatch only costs one push.
            for stale in sorted(_turn_starts, key=_turn_starts.get)[:64]:
                _turn_starts.pop(stale, None)
    return None


@_never_raise
def on_session_end(**kwargs: Any) -> None:
    session_id = _safe_text(kwargs.get("session_id"))
    turn_id = _safe_text(kwargs.get("turn_id"))
    platform = _safe_text(kwargs.get("platform"))
    completed = bool(kwargs.get("completed"))
    failed = bool(kwargs.get("failed"))
    interrupted = bool(kwargs.get("interrupted"))

    with _turn_lock:
        started = _turn_starts.pop((session_id, turn_id), None)
    duration = (time.monotonic() - started) if started is not None else 0.0

    bot = current_bot()
    dispatcher = push_mod.get_dispatcher()

    if platform.strip().lower() == "cron":
        # Fail closed. This hook omits job id/name, creator surface, origin and
        # delivery target. A Slack-owned cron and a Talaria-created routine are
        # identical here, so emitting would fan messaging work out to Talaria.
        return None

    if interrupted:
        return None  # the user stopped it themselves; no point buzzing them
    settings = relay_settings()
    # ``response`` replaces the old duration-only completion buzz for normal
    # turns. The dispatcher repeats this guard for sidecar-originated events.
    if settings.event_enabled("response"):
        return None
    threshold = settings.long_task_min_s
    if (
        settings.event_enabled("long_task")
        and started is not None
        and duration >= threshold > 0
    ):
        dispatcher.notify(push_mod.long_task_event(
            bot=bot,
            session_id=session_id,
            duration_s=duration,
            ok=completed and not failed,
        ))
    return None


# ---------------------------------------------------------------------------
# mentions (messaging gateway inbound, incl. A2A agent-to-agent messages)
# ---------------------------------------------------------------------------

_mention_re_cache: Dict[str, re.Pattern] = {}


def _mention_pattern(handle: str) -> re.Pattern:
    pat = _mention_re_cache.get(handle)
    if pat is None:
        pat = re.compile(
            r"(?<![\w@])@" + re.escape(handle) + r"(?![\w-])", re.IGNORECASE
        )
        _mention_re_cache[handle] = pat
    return pat


@_never_raise
def on_pre_gateway_dispatch(
    event: Any = None, gateway: Any = None, session_store: Any = None,
    **_ignored: Any,
) -> Optional[dict]:
    # Observer only: ALWAYS return None so dispatch flow is never altered.
    if event is None:
        return None
    text = str(getattr(event, "text", "") or "")
    if "@" not in text:
        return None
    handles = relay_settings().mention_handles
    matched = next(
        (h for h in handles if _mention_pattern(h).search(text)), None
    )
    if matched is None:
        return None

    source = getattr(event, "source", None)
    platform = ""
    try:
        raw_platform = getattr(source, "platform", None)
        platform = str(getattr(raw_platform, "value", raw_platform) or "")
    except Exception:
        pass
    sender = str(
        getattr(event, "user_name", None)
        or getattr(event, "user_id", None)
        or ""
    )
    bot = current_bot()
    push_mod.get_dispatcher().notify(push_mod.mention_event(
        bot=bot,
        platform=platform,
        sender=sender,
        text=text,
    ))
    return None


# ---------------------------------------------------------------------------
# registration
# ---------------------------------------------------------------------------

HOOKS = {
    "pre_approval_request": on_pre_approval_request,
    "post_approval_response": on_post_approval_response,
    "pre_llm_call": on_pre_llm_call,
    "post_llm_call": on_post_llm_call,
    "on_session_end": on_session_end,
    "pre_gateway_dispatch": on_pre_gateway_dispatch,
}


def register_hooks(ctx: Any) -> None:
    """Called from the plugin's ``register(ctx)``."""
    for name, callback in HOOKS.items():
        ctx.register_hook(name, callback)
    logger.info(
        "talaria-push: registered %d hooks (bot=%s, events=%s)",
        len(HOOKS), current_bot(), ",".join(relay_settings().enabled_events),
    )
