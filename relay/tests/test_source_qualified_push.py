import os
import asyncio
import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "talaria-push"))

from talaria_push_relay.devices import DeviceStore, DeviceValidationError
from talaria_push_relay.apns import APNsResult
from talaria_push_relay.apns import APNsClient
from talaria_push_relay import events
from talaria_push_relay import push as push_module
from talaria_push_relay.config import (
    ALL_EVENT_KINDS, RelaySettings, SidecarSettings, current_bot,
)
from talaria_push_relay.sidecar import Sidecar
from talaria_push_relay.push import (
    DEFAULT_TEST_KIND,
    APNS_PAYLOAD_SAFE_BYTES,
    BOT_AVATAR_KEY,
    BOT_DISPLAY_NAME_KEY,
    ProfileAvatar,
    ProfilePresentation,
    PushDispatcher,
    PushEvent,
    payload_for_device,
    response_event,
    routine_event,
    synthetic_test_event,
)


class _Store:
    def __init__(self):
        self.removed = []
        self.results = []

    def for_bot(self, _bot):
        return [{"device_token": "ab" * 32, "environment": "dev", "gateway_id": "gw"}]

    def remove(self, token):
        self.removed.append(token)

    def mark_result(self, token, ok):
        self.results.append((token, ok))


class _Client:
    def __init__(self, results):
        self.results = list(results)
        self.calls = []

    def send(self, token, payload, **kwargs):
        self.calls.append((token, payload, kwargs))
        return self.results.pop(0)


class _Dispatcher:
    def __init__(self):
        self.events = []

    def notify(self, event):
        self.events.append(event)


class _ProfileStore:
    def __init__(self, devices):
        self.devices = devices
        self.bots = []
        self.results = []

    def for_bot(self, bot):
        self.bots.append(bot)
        return [
            device for device in self.devices
            if not device.get("profile_filter")
            or bot in device["profile_filter"]
        ]

    def remove(self, token):
        pass

    def mark_result(self, token, ok):
        self.results.append((token, ok))


class SourceQualifiedPushTests(unittest.TestCase):
    def test_response_payload_byte_budget_handles_ascii_cjk_and_emoji(self):
        for text in (
            "ascii response " * 1_000,
            "回答済みです。" * 1_000,
            "✅🌍✨" * 1_000,
        ):
            event = response_event(
                bot="researcher",
                session_id="session-42",
                turn_id="turn-7",
                task_id="task-3",
                response=text,
            )
            payload = payload_for_device(
                event, {"gateway_id": "gateway-with-a-long-but-valid-id"}
            )
            encoded = json.dumps(
                payload,
                ensure_ascii=True,
                separators=(",", ":"),
                allow_nan=False,
            ).encode("utf-8")
            self.assertLessEqual(len(encoded), APNS_PAYLOAD_SAFE_BYTES)
            self.assertEqual(payload["body"], payload["aps"]["alert"]["body"])
            self.assertEqual(payload["gateway_id"], "gateway-with-a-long-but-valid-id")
            # The URL is an optional duplicate of these immutable raw route
            # fields and is deliberately the first metadata shed at the byte
            # boundary. When retained, it must still encode the exact source.
            if "deeplink" in payload:
                self.assertIn("session_id=session-42", payload["deeplink"])
                self.assertIn(
                    "gateway_id=gateway-with-a-long-but-valid-id",
                    payload["deeplink"])

    def test_post_stamp_adversarial_unicode_display_preserves_raw_route_under_budget(self):
        raw_bot = "default"
        raw_session = "session-" + ("s" * 2_300)
        raw_gateway = "g" * 128
        event = response_event(
            bot=raw_bot,
            display_name="🛰️" * 120,
            session_id=raw_session,
            response="✅" * 900,
        )

        payload = payload_for_device(event, {"gateway_id": raw_gateway})
        encoded = json.dumps(
            payload, ensure_ascii=True, separators=(",", ":"),
            allow_nan=False).encode("utf-8")

        self.assertLessEqual(len(encoded), APNS_PAYLOAD_SAFE_BYTES)
        self.assertEqual(payload["bot"], raw_bot)
        self.assertEqual(payload["session_id"], raw_session)
        self.assertEqual(payload["gateway_id"], raw_gateway)

    def test_emoji_display_and_max_gateway_never_crowd_out_short_response(self):
        raw_gateway = "g" * 128
        for emoji_count in (90, 120):
            for session_id in ("stored-emoji", "s" * 3_425):
                with self.subTest(
                    emoji_count=emoji_count, session_length=len(session_id),
                ):
                    display_name = "🛰️" * emoji_count
                    event = response_event(
                        bot="default",
                        display_name=display_name,
                        session_id=session_id,
                        turn_id="turn",
                        task_id="task",
                        response="Done.",
                    )

                    payload = payload_for_device(
                        event, {"gateway_id": raw_gateway})
                    encoded = json.dumps(
                        payload, ensure_ascii=True, separators=(",", ":"),
                        allow_nan=False).encode("utf-8")

                    self.assertLessEqual(len(encoded), APNS_PAYLOAD_SAFE_BYTES)
                    self.assertEqual(payload["bot"], "default")
                    self.assertEqual(payload["session_id"], session_id)
                    self.assertEqual(payload["gateway_id"], raw_gateway)
                    self.assertEqual(payload["aps"]["alert"]["body"], "Done.")
                    if "body" in payload:
                        self.assertEqual(payload["body"], "Done.")
                    if session_id == "stored-emoji":
                        self.assertTrue(payload["aps"]["alert"]["title"])

    def test_ordinary_skynet_title_and_avatar_are_unchanged(self):
        avatar = ProfileAvatar("image/png", b"small-skynet-avatar")
        event = response_event(
            bot="default", display_name="Skynet", avatar=avatar,
            session_id="stored-skynet", response="Done.")

        payload = payload_for_device(event, {"gateway_id": "mini"})

        self.assertEqual(payload["title"], "Skynet")
        self.assertEqual(payload[BOT_DISPLAY_NAME_KEY], "Skynet")
        self.assertEqual(payload["aps"]["alert"]["title"], "Skynet")
        self.assertEqual(payload["body"], "Done.")
        self.assertIn(BOT_AVATAR_KEY, payload)
        self.assertEqual(
            payload[BOT_AVATAR_KEY][push_module.BOT_AVATAR_DATA_KEY],
            __import__("base64").b64encode(avatar.data).decode("ascii"))

    def test_payload_fails_closed_when_fixed_raw_authority_cannot_fit(self):
        event = response_event(
            bot="default",
            display_name="Skynet",
            session_id="s" * 4_000,
            response="Done.",
        )
        with self.assertRaisesRegex(ValueError, "fixed routing authority"):
            payload_for_device(event, {"gateway_id": "g" * 128})

    def test_current_bot_honors_hermes_context_home_override(self):
        try:
            import hermes_constants
        except ImportError:
            self.skipTest("pinned Hermes runtime is not installed in this test environment")

        token = hermes_constants.set_hermes_home_override(
            "/tmp/hermes/profiles/secondary"
        )
        try:
            with patch.dict(os.environ, {"TALARIA_PUSH_BOT_NAME": ""}):
                self.assertEqual(current_bot(), "secondary")
            with patch.dict(os.environ, {"TALARIA_PUSH_BOT_NAME": "explicit-bot"}):
                self.assertEqual(current_bot(), "explicit-bot")
        finally:
            hermes_constants.reset_hermes_home_override(token)

    def test_response_kind_is_default_enabled_and_has_payload_contract(self):
        self.assertIn("response", ALL_EVENT_KINDS)
        settings = RelaySettings()
        self.assertTrue(settings.event_enabled("response"))
        self.assertFalse(settings.event_enabled("routine"))

        with patch("talaria_push_relay.push.time.time", return_value=1_000):
            event = response_event(
                bot="researcher",
                session_id="session-42",
                turn_id="turn-7",
                task_id="task-3",
                response="\x00  \ud800 " + "answer " * 200,
            )
        payload = event.apns_payload()

        self.assertEqual(payload["kind"], "response")
        self.assertEqual(payload["bot"], "researcher")
        self.assertEqual(payload["title"], "researcher")
        self.assertEqual(payload[BOT_DISPLAY_NAME_KEY], "researcher")
        self.assertEqual(payload["session_id"], "session-42")
        self.assertEqual(payload["task_id"], "task-3")
        self.assertEqual(payload["turn_id"], "turn-7")
        self.assertEqual(payload["aps"]["category"], "TALARIA_RESPONSE")
        self.assertEqual(payload["aps"]["interruption-level"], "active")
        self.assertEqual(payload["deeplink"], "talaria://bot/researcher?session_id=session-42")
        self.assertLessEqual(len(payload["body"]), 900)
        self.assertNotIn("\x00", payload["body"])
        self.assertIn("\ufffd", payload["body"])
        self.assertEqual(event.expiration, 4_600)

    def test_response_dedupe_includes_bot_session_turn_task_and_body(self):
        base = {
            "bot": "worker",
            "session_id": "session",
            "turn_id": "turn",
            "task_id": "task",
            "response": "same answer",
        }
        events_by_identity = [
            response_event(**base),
            response_event(**{**base, "bot": "other-worker"}),
            response_event(**{**base, "session_id": "other-session"}),
            response_event(**{**base, "turn_id": "other-turn"}),
            response_event(**{**base, "task_id": "other-task"}),
            response_event(**{**base, "response": "other answer"}),
        ]
        self.assertEqual(len({event.dedupe_key for event in events_by_identity}), 6)

    def test_response_hook_dispatches_exact_profile_and_session(self):
        dispatcher = _Dispatcher()
        settings = RelaySettings(enabled_events=list(ALL_EVENT_KINDS))
        with patch.object(events, "current_bot", return_value="ops-bot"), \
             patch.object(events, "relay_settings", return_value=settings), \
             patch.object(events.push_mod, "current_profile_presentation",
                          return_value=ProfilePresentation("Operations")), \
             patch.object(events.push_mod, "get_dispatcher", return_value=dispatcher):
            events.on_post_llm_call(
                session_id="durable-session",
                task_id="task-9",
                turn_id="turn-4",
                user_message="What changed?",
                assistant_response="Done.",
                conversation_history=[],
                model="hermes-test",
                platform="talaria",
            )

        self.assertEqual(len(dispatcher.events), 1)
        event = dispatcher.events[0]
        self.assertEqual(event.kind, "response")
        self.assertEqual(event.bot, "ops-bot")
        self.assertEqual(event.title, "Operations")
        self.assertEqual(event.session_id, "durable-session")
        self.assertEqual(event.extra, {
            "task_id": "task-9",
            "turn_id": "turn-4",
            BOT_DISPLAY_NAME_KEY: "Operations",
        })

    def test_response_platform_policy_allows_only_talaria_addressable_surfaces(self):
        settings = RelaySettings(enabled_events=["response"])
        cases = (
            ("talaria", True),
            ("desktop", True),
            (None, False),
            ("", False),
            (" ", False),
            (123, False),
            ([], False),
            ("cli", False),
            ("tui", False),
            ("api_server", False),
            ("webui", False),
            ("tool", False),
            ("subagent", False),
            ("relay", False),
            ("slack", False),
            ("webhook", False),
            ("telegram", False),
            ("discord", False),
            ("whatsapp", False),
            ("signal", False),
            ("cron", False),
            ("unknown", False),
            ("TALARIA", False),
            ("tui_gateway", False),
        )

        for platform, should_push in cases:
            with self.subTest(platform=platform):
                dispatcher = _Dispatcher()
                with patch.object(events, "current_bot", return_value="ops-bot"), \
                     patch.object(events, "relay_settings", return_value=settings), \
                     patch.object(events.push_mod, "current_profile_presentation",
                                  return_value=ProfilePresentation("Operations")), \
                     patch.object(events.push_mod, "get_dispatcher",
                                  return_value=dispatcher):
                    events.on_post_llm_call(
                        session_id="durable-session",
                        task_id="task-9",
                        turn_id="turn-4",
                        assistant_response="Done.",
                        platform=platform,
                    )

                self.assertEqual(len(dispatcher.events), int(should_push))

    def test_response_hook_does_not_fan_messaging_finals_out_to_talaria(self):
        dispatcher = _Dispatcher()
        settings = RelaySettings(enabled_events=["response"])
        common = {
            "task_id": "task",
            "turn_id": "turn",
            "assistant_response": "Done.",
        }

        with patch.object(events, "current_bot", return_value="ops-bot"), \
             patch.object(events, "relay_settings", return_value=settings), \
             patch.object(events.push_mod, "current_profile_presentation",
                          return_value=ProfilePresentation("Operations")), \
             patch.object(events.push_mod, "get_dispatcher", return_value=dispatcher):
            events.on_post_llm_call(
                session_id="agent:main:slack:channel:qa",
                platform="slack",
                **common,
            )
            events.on_post_llm_call(
                session_id="agent:main:webhook:qa-pr-watch",
                platform="webhook",
                **common,
            )

            self.assertEqual(dispatcher.events, [])

            events.on_post_llm_call(
                session_id="talaria-session",
                platform="talaria",
                **common,
            )
            events.on_post_llm_call(
                session_id="desktop-chat",
                platform="desktop",
                **common,
            )

        self.assertEqual(
            [(event.kind, event.session_id) for event in dispatcher.events],
            [("response", "talaria-session"), ("response", "desktop-chat")],
        )

    def test_response_title_uses_configured_name_but_raw_profile_still_routes(self):
        event = response_event(
            bot="default",
            display_name="Mercury",
            session_id="stored-42",
            response="Done.",
        )
        payload = payload_for_device(event, {"gateway_id": "foreign"})

        self.assertEqual(payload["title"], "Mercury")
        self.assertEqual(payload["aps"]["alert"]["title"], "Mercury")
        self.assertEqual(payload[BOT_DISPLAY_NAME_KEY], "Mercury")
        self.assertEqual(payload["bot"], "default")
        self.assertIn("/default?", payload["deeplink"])
        self.assertIn("gateway_id=foreign", payload["deeplink"])

    def test_response_title_default_falls_back_to_hermes_without_suffix(self):
        default = response_event(bot="default", session_id="stored", response="Done")
        named = response_event(bot="researcher", session_id="stored", response="Done")

        self.assertEqual(default.title, "Hermes")
        self.assertEqual(default.extra[BOT_DISPLAY_NAME_KEY], "Hermes")
        self.assertEqual(named.title, "researcher")
        self.assertNotIn("response ready", default.title.lower())
        self.assertNotIn("response ready", named.title.lower())

    def test_context_profile_metadata_is_authoritative_for_display_name(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            (home / "profile.yaml").write_text(
                json.dumps({"ui_meta": {"hermes-bots": {"title": "Skynet"}}}),
                encoding="utf-8")
            safe_yaml = types.SimpleNamespace(safe_load=json.loads)
            with patch.dict(sys.modules, {"yaml": safe_yaml}), \
                 patch.object(push_module, "_current_profile_home", return_value=home):
                presentation = push_module.current_profile_presentation("default")

        self.assertEqual(presentation.display_name, "Skynet")
        self.assertIsNone(presentation.avatar)
        ordinary = payload_for_device(response_event(
            bot="default",
            display_name=presentation.display_name,
            session_id="stored-skynet",
            response="Done."), {"gateway_id": "mini"})
        self.assertEqual(ordinary["aps"]["alert"]["title"], "Skynet")
        self.assertEqual(ordinary["title"], "Skynet")
        self.assertEqual(ordinary[BOT_DISPLAY_NAME_KEY], "Skynet")

    def test_bot_mode_title_precedes_core_display_name_and_bad_yaml_falls_back(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            profile = home / "profile.yaml"
            safe_yaml = types.SimpleNamespace(safe_load=json.loads)
            with patch.dict(sys.modules, {"yaml": safe_yaml}), \
                 patch.object(push_module, "_current_profile_home", return_value=home):
                profile.write_text(
                    json.dumps({
                        "display_name": "Core Name",
                        "ui_meta": {"hermes-bots": {"title": "Bot Mode Name"}},
                    }),
                    encoding="utf-8")
                self.assertEqual(
                    push_module.current_profile_presentation("raw").display_name,
                    "Bot Mode Name")

                profile.write_text(
                    json.dumps({"display_name": "Core Name"}), encoding="utf-8")
                self.assertEqual(
                    push_module.current_profile_presentation("raw").display_name,
                    "Core Name")

                for malformed in (
                    json.dumps(["not", "a", "mapping"]),
                    json.dumps({"ui_meta": ["wrong"], "display_name": {"wrong": "type"}}),
                    json.dumps({"ui_meta": {"hermes-bots": {"title": ["wrong"]}}}),
                    "{malformed",
                ):
                    profile.write_text(malformed, encoding="utf-8")
                    self.assertEqual(
                        push_module.current_profile_presentation("raw").display_name,
                        "raw")

    def test_missing_or_malformed_context_avatar_falls_back_without_payload_bytes(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            (home / "assets").mkdir()
            (home / "assets" / "avatar.png").write_bytes(b"not-an-image")
            with patch.object(push_module, "_current_profile_home", return_value=home), \
                 patch.object(push_module, "_read_current_profile_meta",
                              return_value={"display_name": "Configured Bot"}):
                presentation = push_module.current_profile_presentation("raw-profile")
        event = response_event(
            bot="raw-profile", display_name=presentation.display_name,
            avatar=presentation.avatar, session_id="stored", response="Done")

        self.assertIsNone(presentation.avatar)
        self.assertNotIn(BOT_AVATAR_KEY, event.apns_payload())

    def test_context_avatar_uses_assets_layout_and_ignores_root_decoy(self):
        # Valid 1x1 PNG; small enough for the no-Pillow fallback and also safe
        # for an installed Pillow to decode/re-encode.
        png = __import__("base64").b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            assets = home / "assets"
            assets.mkdir()
            (assets / "avatar.png").write_bytes(png)
            # A root-level decoy must never be consulted.
            (home / "avatar.png").write_bytes(b"not-the-profile-asset")

            avatar = push_module._bounded_profile_avatar(home)

        self.assertIsNotNone(avatar)
        self.assertIn(avatar.mime, {"image/png", "image/jpeg"})
        self.assertLessEqual(len(avatar.data), 1400)

    def test_context_avatar_rejects_symlink_even_inside_assets_directory(self):
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            assets = home / "assets"
            assets.mkdir()
            target = home / "decoy.png"
            target.write_bytes(b"\x89PNG\r\n\x1a\nsecret-decoy")
            (assets / "avatar.png").symlink_to(target)

            self.assertIsNone(push_module._bounded_profile_avatar(home))

    def test_context_avatar_rejects_symlinked_assets_parent(self):
        png = __import__("base64").b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        with tempfile.TemporaryDirectory() as root, \
             tempfile.TemporaryDirectory() as outside:
            home = Path(root)
            outside_assets = Path(outside)
            (outside_assets / "avatar.png").write_bytes(png)
            (home / "assets").symlink_to(outside_assets, target_is_directory=True)

            self.assertIsNone(push_module._bounded_profile_avatar(home))

    def test_context_avatar_open_fd_ignores_path_swap_decoy(self):
        png = __import__("base64").b64decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        with tempfile.TemporaryDirectory() as root:
            home = Path(root)
            assets = home / "assets"
            assets.mkdir()
            avatar_path = assets / "avatar.png"
            opened_inode = assets / "opened-avatar.png"
            avatar_path.write_bytes(png)
            real_fstat = os.fstat
            swapped = False

            def swap_after_open(fd):
                nonlocal swapped
                info = real_fstat(fd)
                if not swapped:
                    swapped = True
                    avatar_path.rename(opened_inode)
                    avatar_path.write_bytes(b"not-the-opened-image")
                return info

            with patch.object(push_module.os, "fstat", side_effect=swap_after_open):
                avatar = push_module._bounded_profile_avatar(home)

            self.assertTrue(swapped)
            self.assertIsNotNone(avatar)
            self.assertEqual(avatar_path.read_bytes(), b"not-the-opened-image")

    def test_bounded_inline_avatar_keeps_payload_under_safe_limit_or_drops_first(self):
        tiny_png = (
            b"\x89PNG\r\n\x1a\n" + b"bounded-avatar"
        )
        short = response_event(
            bot="default", display_name="Hermes", session_id="stored",
            response="Done.", avatar=ProfileAvatar("image/png", tiny_png))
        short_payload = payload_for_device(short, {"gateway_id": "homelab"})
        short_bytes = json.dumps(
            short_payload, ensure_ascii=True, separators=(",", ":"),
            allow_nan=False).encode("utf-8")

        self.assertIn(BOT_AVATAR_KEY, short_payload)
        self.assertLessEqual(len(short_bytes), APNS_PAYLOAD_SAFE_BYTES)
        self.assertEqual(short_payload["bot"], "default")

        large_avatar = ProfileAvatar(
            "image/png", b"\x89PNG\r\n\x1a\n" + b"x" * 1390)
        long = response_event(
            bot="default", display_name="Hermes", session_id="stored",
            response="answer " * 500, avatar=large_avatar)
        long_payload = payload_for_device(long, {"gateway_id": "homelab"})
        long_bytes = json.dumps(
            long_payload, ensure_ascii=True, separators=(",", ":"),
            allow_nan=False).encode("utf-8")

        self.assertNotIn(BOT_AVATAR_KEY, long_payload,
                         "portrait must drop before response text is over-truncated")
        self.assertLessEqual(len(long_bytes), APNS_PAYLOAD_SAFE_BYTES)

    def test_response_hook_filters_cron_empty_and_malformed_payloads(self):
        dispatcher = _Dispatcher()
        settings = RelaySettings(enabled_events=["response"])

        class _BadString:
            def __str__(self):
                raise RuntimeError("bad value")

        with patch.object(events, "current_bot", return_value="ops-bot"), \
             patch.object(events, "relay_settings", return_value=settings), \
             patch.object(events.push_mod, "get_dispatcher", return_value=dispatcher):
            events.on_post_llm_call(
                session_id="cron-session",
                assistant_response="scheduled answer",
                platform="cron",
            )
            events.on_post_llm_call(
                session_id="session", assistant_response="  ", platform="talaria")
            events.on_post_llm_call(
                session_id="session", assistant_response=None, platform="talaria")
            events.on_post_llm_call(
                session_id="session", assistant_response={"text": "x"},
                platform="talaria")
            events.on_post_llm_call(
                session_id=_BadString(), assistant_response="answer",
                platform="talaria")

        self.assertEqual(dispatcher.events, [])

    def test_response_filter_leaves_long_task_available_when_response_disabled(self):
        dispatcher = _Dispatcher()
        settings = RelaySettings(enabled_events=["long_task"], long_task_min_s=1)
        key = ("session", "turn")
        with events._turn_lock:
            events._turn_starts[key] = events.time.monotonic() - 2
        with patch.object(events, "current_bot", return_value="ops-bot"), \
             patch.object(events, "relay_settings", return_value=settings), \
             patch.object(events.push_mod, "get_dispatcher", return_value=dispatcher):
            events.on_session_end(
                session_id="session",
                turn_id="turn",
                completed=True,
                failed=False,
                interrupted=False,
                platform="cli",
            )

        self.assertEqual([event.kind for event in dispatcher.events], ["long_task"])

    def test_response_enabled_suppresses_long_task_duplicate(self):
        dispatcher = _Dispatcher()
        settings = RelaySettings(enabled_events=list(ALL_EVENT_KINDS), long_task_min_s=1)
        key = ("session", "turn")
        with events._turn_lock:
            events._turn_starts[key] = events.time.monotonic() - 2
        with patch.object(events, "current_bot", return_value="ops-bot"), \
             patch.object(events, "relay_settings", return_value=settings), \
             patch.object(events.push_mod, "get_dispatcher", return_value=dispatcher):
            events.on_session_end(
                session_id="session",
                turn_id="turn",
                completed=True,
                failed=False,
                interrupted=False,
                platform="cli",
            )

        self.assertEqual(dispatcher.events, [])

    def test_cron_completion_never_enters_talaria_push_without_provenance(self):
        settings = RelaySettings(enabled_events=list(ALL_EVENT_KINDS))
        for completed, failed in ((True, False), (False, True)):
            with self.subTest(completed=completed, failed=failed):
                dispatcher = _Dispatcher()
                with patch.object(events, "current_bot", return_value="default"), \
                     patch.object(events, "relay_settings", return_value=settings), \
                     patch.object(events.push_mod, "get_dispatcher",
                                  return_value=dispatcher):
                    events.on_session_end(
                        session_id="cron_slack-owned_123",
                        turn_id="turn",
                        completed=completed,
                        failed=failed,
                        interrupted=False,
                        platform="cron",
                    )

                self.assertEqual(dispatcher.events, [])

    def test_sidecar_has_no_cron_polling_surface_without_creator_provenance(self):
        with patch("talaria_push_relay.sidecar.push_mod.get_dispatcher",
                   return_value=_Dispatcher()):
            sidecar = Sidecar(SidecarSettings(token="token"))

        self.assertFalse(hasattr(sidecar, "scan_cron"))
        self.assertFalse(hasattr(sidecar, "_cron_fp"))

    def test_routine_builder_never_exposes_raw_default_or_status_in_title(self):
        configured = routine_event(
            bot="default", routine="nightly", display_name="Skynet")
        fallback = routine_event(bot="default", routine="nightly")

        self.assertEqual(configured.title, "Skynet")
        self.assertEqual(configured.bot, "default")
        self.assertEqual(configured.extra[BOT_DISPLAY_NAME_KEY], "Skynet")
        self.assertEqual(fallback.title, "Hermes")
        self.assertNotIn("routine", fallback.title.lower())
        self.assertNotIn("finished", fallback.title.lower())

    def test_response_fanout_uses_profile_filter_and_payload_source(self):
        token_ops = "ab" * 32
        token_other = "cd" * 32
        store = _ProfileStore([
            {"device_token": token_ops, "environment": "dev", "gateway_id": "gw-ops",
             "profile_filter": ["ops-bot"]},
            {"device_token": token_other, "environment": "dev", "gateway_id": "gw-other",
             "profile_filter": ["other-bot"]},
        ])
        client = _Client([APNsResult(True, 200, "", "ops-apns-id")])
        dispatcher = PushDispatcher()
        dispatcher._client = client
        event = response_event(
            bot="ops-bot", session_id="session", turn_id="turn", task_id="task",
            response="Done.",
        )

        with patch("talaria_push_relay.push.get_store", return_value=store):
            dispatcher._fan_out(event)

        self.assertEqual(store.bots, ["ops-bot"])
        self.assertEqual([call[0] for call in client.calls], [token_ops])
        self.assertEqual(client.calls[0][1]["gateway_id"], "gw-ops")
        self.assertEqual(client.calls[0][1]["bot"], "ops-bot")
        self.assertEqual(client.calls[0][1]["session_id"], "session")

    def test_approval_hook_uses_durable_session_key_when_runtime_id_also_exists(self):
        dispatcher = _Dispatcher()
        with patch.object(events, "current_bot", return_value="worker"), \
             patch.object(events, "_approval_surfaces", return_value={"gateway"}), \
             patch.object(events.push_mod, "get_dispatcher", return_value=dispatcher):
            events.on_pre_approval_request(
                surface="gateway",
                session_key="durable-session-key",
                session_id="ephemeral-runtime-id",
                description="Approve command",
                command="echo safe",
                pattern_key="shell",
            )

        self.assertEqual(len(dispatcher.events), 1)
        event = dispatcher.events[0]
        self.assertEqual(event.kind, "approval")
        self.assertEqual(event.session_id, "durable-session-key")
        self.assertNotEqual(event.session_id, "ephemeral-runtime-id")

    def test_approval_hook_without_durable_key_is_non_actionable(self):
        dispatcher = _Dispatcher()
        with patch.object(events, "current_bot", return_value="worker"), \
             patch.object(events, "_approval_surfaces", return_value={"gateway"}), \
             patch.object(events.push_mod, "get_dispatcher", return_value=dispatcher):
            events.on_pre_approval_request(
                surface="gateway",
                session_key="   ",
                session_id="ephemeral-runtime-id",
                description="Approve command",
                command="echo unsafe",
                pattern_key="shell",
            )

        self.assertEqual(dispatcher.events, [])

    def test_synthetic_test_push_defaults_to_non_actionable_kind(self):
        self.assertEqual(DEFAULT_TEST_KIND, "mention")

    def test_even_approval_shaped_test_has_no_live_authority(self):
        payload = payload_for_device(
            synthetic_test_event("approval"), {"gateway_id": "gateway-a"})
        self.assertEqual(payload["kind"], "approval")
        self.assertEqual(payload["gateway_id"], "gateway-a")
        self.assertEqual(payload["session_id"], "")
        self.assertEqual(payload["approval_request_id"], "")

    def test_registration_persists_source_and_legacy_update_preserves_it(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "devices.json"
            store = DeviceStore(path)
            token = "ab" * 32
            first = store.upsert(token, gateway_id="gateway-a", profile_filter=["default"])
            second = store.upsert(token, profile_filter=["default"])

            self.assertEqual(first["gateway_id"], "gateway-a")
            self.assertEqual(second["gateway_id"], "gateway-a")

    def test_gateway_id_is_bounded(self):
        with tempfile.TemporaryDirectory() as root:
            store = DeviceStore(Path(root) / "devices.json")
            with self.assertRaises(DeviceValidationError):
                store.upsert("cd" * 32, gateway_id="x" * 129)

    def test_payload_is_source_stamped_per_device_and_mutable(self):
        event = PushEvent(kind="approval", bot="default", title="Approve", body="Run it")
        a = payload_for_device(event, {"gateway_id": "gateway-a"})
        b = payload_for_device(event, {"gateway_id": "gateway-b"})

        self.assertEqual(a["gateway_id"], "gateway-a")
        self.assertEqual(b["gateway_id"], "gateway-b")
        self.assertEqual(a["aps"]["mutable-content"], 1)
        self.assertNotEqual(a["gateway_id"], b["gateway_id"])

    def test_response_device_deeplink_carries_source_and_stored_session(self):
        event = response_event(
            bot="researcher",
            session_id="session-42",
            turn_id="turn-7",
            task_id="task-3",
            response="Done.",
        )

        payload = payload_for_device(event, {"gateway_id": "homelab"})

        self.assertEqual(
            payload["deeplink"],
            "talaria://bot/researcher?session_id=session-42&gateway_id=homelab",
        )

    def test_every_event_has_a_bounded_expiration(self):
        with patch("talaria_push_relay.push.time.time", return_value=1_000):
            approval = PushEvent(kind="approval", bot="default", title="Approve", body="Run")
            mention = PushEvent(kind="mention", bot="default", title="Ping", body="Hello")
        self.assertEqual(approval.expiration, 1_300)
        self.assertEqual(mention.expiration, 4_600)

    def test_expired_provider_token_remints_and_retries_current_push_without_sleep(self):
        store = _Store()
        client = _Client([
            APNsResult(False, 403, "ExpiredProviderToken"),
            APNsResult(True, 200, "", "apns-id"),
        ])
        dispatcher = PushDispatcher()
        dispatcher._client = client
        event = PushEvent(kind="approval", bot="default", title="Approve", body="Run")

        with patch("talaria_push_relay.push.get_store", return_value=store), \
             patch("talaria_push_relay.push.time.sleep") as sleep:
            dispatcher._fan_out(event)

        self.assertEqual(len(client.calls), 2)
        sleep.assert_not_called()
        self.assertEqual(client.calls[0][2]["expiration"], event.expiration)
        self.assertEqual(client.calls[1][2]["expiration"], event.expiration)
        self.assertEqual(store.results[-1], ("ab" * 32, True))

    def test_retry_prunes_token_that_becomes_unregistered(self):
        store = _Store()
        client = _Client([
            APNsResult(False, 500, "InternalServerError"),
            APNsResult(False, 410, "Unregistered"),
        ])
        dispatcher = PushDispatcher()
        dispatcher._client = client
        event = PushEvent(kind="routine", bot="default", title="Done", body="Done")

        with patch("talaria_push_relay.push.get_store", return_value=store), \
             patch("talaria_push_relay.push.time.sleep"):
            dispatcher._fan_out(event)

        self.assertEqual(store.removed, ["ab" * 32])

    def test_apns_client_clears_expired_cached_jwt_and_remints(self):
        class _Settings:
            default_env = "dev"
            topic = "bot.talaria.test"

        class _Response:
            def __init__(self, status, reason):
                self.status_code = status
                self._reason = reason
                self.text = reason
                self.headers = {}

            def json(self):
                return {"reason": self._reason}

        class _HTTP:
            def __init__(self):
                self.responses = [
                    _Response(403, "ExpiredProviderToken"),
                    _Response(200, ""),
                ]
                self.authorizations = []

            def post(self, _path, json, headers):
                self.authorizations.append(headers["authorization"])
                return self.responses.pop(0)

        class _MintingClient(APNsClient):
            def __init__(self):
                super().__init__(_Settings())
                self.mints = 0

            def _mint_provider_token(self, now):
                self.mints += 1
                return f"jwt-{self.mints}"

        client = _MintingClient()
        http = _HTTP()
        client._clients["https://api.sandbox.push.apple.com"] = http
        token = "ab" * 32

        first = client.send(token, {"aps": {}})
        second = client.send(token, {"aps": {}})

        self.assertEqual(first.reason, "ExpiredProviderToken")
        self.assertTrue(second.ok)
        self.assertEqual(client.mints, 2)
        self.assertEqual(http.authorizations, ["bearer jwt-1", "bearer jwt-2"])


if __name__ == "__main__":
    unittest.main()
