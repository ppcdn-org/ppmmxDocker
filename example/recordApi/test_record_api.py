#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Live tests for the on-demand recording API (/api/record/split).

Two groups:
  * OfflineAuthTests: pure local signature checks, always run, no network or
    credentials needed.
  * LiveApiTests: real HTTP calls against a record node, verifying the
    documented auth, parameter validation, status codes and two-phase
    protocol. Skipped automatically when no appId/appSecret is configured.

Credentials come from environment variables (same names the main repo's
integrationTest/api uses):
    PPCDN_TEST_APP_ID / PPCDN_TEST_APP_SECRET
or
    RECORD_API_APP_ID  / RECORD_API_APP_SECRET
Optional:
    PPCDN_RECORD_BASE_URL / RECORD_API_BASE_URL   YOUR standalone/record node URL (required for live cases)
    RECORD_API_TEST_TABLE                         tableId used for round-start, default "table"

Run:
    python -m unittest test_record_api -v
"""

from __future__ import annotations

import json
import os
import sys
import time
import unittest
import urllib.error
import urllib.request

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import record_api as ra  # noqa: E402

TEST_APP_ID = os.environ.get("PPCDN_TEST_APP_ID") or os.environ.get("RECORD_API_APP_ID", "")
TEST_APP_SECRET = os.environ.get("PPCDN_TEST_APP_SECRET") or os.environ.get("RECORD_API_APP_SECRET", "")
BASE_URL = (os.environ.get("PPCDN_RECORD_BASE_URL")
            or os.environ.get("RECORD_API_BASE_URL")
            or ra.DEFAULT_BASE_URL)
SAFE_TABLE = os.environ.get("RECORD_API_TEST_TABLE", "table")
APP_ENV = "test"

HAVE_CREDS = bool(TEST_APP_ID and TEST_APP_SECRET and BASE_URL)


def setUpModule() -> None:
    print("=" * 72)
    print("On-demand recording API live tests")
    print("  target   : %s" % (BASE_URL or "(RECORD_API_BASE_URL not set - live cases will skip)"))
    print("  appId    : %s" % (TEST_APP_ID or "(not configured - live cases will skip)"))
    print("  test table: %s" % SAFE_TABLE)
    print("=" * 72)


def _raw_post(url: str, raw_body: bytes, headers) -> tuple:
    """Send a raw body (used to deliberately build malformed JSON)."""
    req = urllib.request.Request(url, data=raw_body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def _post_split(secret: str, *, time_str: str, table_id: str, game_id: str,
                game_round: str = "", app_env: str = "", auth_mode: str = "simple",
                app_id: str = None, nonce: str = None):
    """Build and send one request through the example module."""
    body, headers, _ = ra.build_request(
        app_id=app_id if app_id is not None else TEST_APP_ID,
        table_id=table_id, game_id=game_id, game_round=game_round,
        app_env=app_env, secret=secret, auth_mode=auth_mode,
        time_str=time_str, nonce=nonce,
    )
    return ra.call_split(BASE_URL, body, headers)


def _now() -> str:
    return str(int(time.time()))


# --------------------------------------------------------------------------- #
# Offline: signature correctness
# --------------------------------------------------------------------------- #

class OfflineAuthTests(unittest.TestCase):
    """The signing algorithm matches the docs byte for byte (locked by vectors)."""

    SECRET = "s3cr3t"
    TIME = "1757280000"
    APP = "app_abc"
    TABLE = "table1"
    GAME = "p2w001"

    def test_simple_round_start_vector(self):
        # base = secret+time+appId+tableId+gameId (empty gameRound is omitted)
        expected = "c6021e2d628d8062fec26024e4a92477"
        self.assertEqual(
            ra.sign_simple(self.SECRET, self.TIME, self.APP, self.TABLE, "", self.GAME),
            expected)

    def test_simple_round_end_vector(self):
        # base = secret+time+appId+tableId+gameRound+gameId
        expected = "f4ff887d8d0e5e1bdd121c177ff7bf98"
        self.assertEqual(
            ra.sign_simple(self.SECRET, self.TIME, self.APP, self.TABLE, "gc001", self.GAME),
            expected)

    def test_advance_canonical_json_field_order(self):
        nonce = "0123456789abcdef0123456789abcdef"
        expected = ('{"time":"1757280000","appId":"app_abc","tableId":"table1",'
                    '"gameRound":"","gameId":"p2w001","nonce":"%s"}' % nonce)
        self.assertEqual(
            ra.canonical_json(self.TIME, self.APP, self.TABLE, "", self.GAME, nonce),
            expected)

    def test_advance_hmac_vector(self):
        nonce = "0123456789abcdef0123456789abcdef"
        expected = "HMAC-SHA256 e5e8444722319d21a37ad468ab92cab359451ae6cee8695969c387e1c9f212f2"
        self.assertEqual(
            ra.sign_advance(self.SECRET, self.TIME, self.APP, self.TABLE, "", self.GAME, nonce),
            expected)

    def test_build_request_omits_empty_round_and_env(self):
        body, headers, _ = ra.build_request(
            app_id=self.APP, table_id=self.TABLE, game_id=self.GAME,
            secret=self.SECRET, time_str=self.TIME)
        self.assertNotIn("gameRound", body)
        self.assertNotIn("appEnv", body)
        self.assertIn("Authorization", headers)

    def test_build_request_includes_round_and_env_when_set(self):
        body, headers, _ = ra.build_request(
            app_id=self.APP, table_id=self.TABLE, game_id=self.GAME, game_round="gc001",
            app_env="test", secret=self.SECRET, time_str=self.TIME)
        self.assertEqual(body["gameRound"], "gc001")
        self.assertEqual(body["appEnv"], "test")

    def test_advance_request_carries_nonce_header(self):
        _, headers, _ = ra.build_request(
            app_id=self.APP, table_id=self.TABLE, game_id=self.GAME,
            secret=self.SECRET, auth_mode="advance", time_str=self.TIME)
        self.assertIn("X-Split-Rec-Nonce", headers)
        self.assertTrue(headers["Authorization"].startswith("HMAC-SHA256 "))


class OfflineBaseUrlTests(unittest.TestCase):
    """The API host must be the caller's own node, never PPCDN's hosted recorder."""

    def test_empty_base_url_rejected(self):
        self.assertIsNotNone(ra.check_base_url(""))

    def test_hosted_recorder_rejected(self):
        for url in ("https://record.pp-cdn.org", "https://RECORD.pp-cdn.org/", "http://record.pp-cdn.org:443"):
            self.assertIn("hosted", ra.check_base_url(url), url)
        with self.assertRaises(ra.RecordApiError):
            ra.call_split("https://record.pp-cdn.org", {}, {})

    def test_own_node_accepted(self):
        for url in ("http://203.0.113.10:8888", "https://mmx-abc12345.rent.pp-cdn.org"):
            self.assertIsNone(ra.check_base_url(url), url)


# --------------------------------------------------------------------------- #
# Live: real HTTP contract
# --------------------------------------------------------------------------- #

@unittest.skipUnless(HAVE_CREDS, "needs PPCDN_TEST_APP_ID / PPCDN_TEST_APP_SECRET and RECORD_API_BASE_URL (your own node)")
class LiveApiTests(unittest.TestCase):

    def test_missing_authorization_returns_400(self):
        url = BASE_URL.rstrip("/") + "/api/record/split"
        body = {"time": _now(), "appId": TEST_APP_ID, "tableId": SAFE_TABLE,
                "gameId": "itest-noauth-" + _now()}
        status, raw = _raw_post(url, json.dumps(body).encode(), {"Content-Type": "application/json"})
        self.assertEqual(status, 400, raw)

    def test_malformed_json_returns_400(self):
        url = BASE_URL.rstrip("/") + "/api/record/split"
        status, raw = _raw_post(url, b"{not-json",
                                {"Content-Type": "application/json",
                                 "Authorization": "deadbeefdeadbeefdeadbeefdeadbeef"})
        self.assertEqual(status, 400, raw)

    def test_missing_table_id_returns_400(self):
        status, env, raw = _post_split(TEST_APP_SECRET, time_str=_now(),
                                       table_id="", game_id="itest-notable-" + _now())
        self.assertEqual(status, 400, raw)

    def test_invalid_table_id_chars_returns_400(self):
        status, env, raw = _post_split(TEST_APP_SECRET, time_str=_now(),
                                       table_id="table/../etc", game_id="itest-bad-" + _now())
        self.assertEqual(status, 400, raw)

    def test_wrong_secret_returns_401(self):
        status, env, raw = _post_split(TEST_APP_SECRET + "-wrong", time_str=_now(),
                                       table_id=SAFE_TABLE, game_id="itest-wrong-" + _now())
        self.assertEqual(status, 401, raw)
        self.assertEqual(env.get("code"), 401)

    def test_expired_time_returns_401(self):
        old = str(int(time.time()) - 3600)
        status, env, raw = _post_split(TEST_APP_SECRET, time_str=old,
                                       table_id=SAFE_TABLE, game_id="itest-old-" + _now())
        self.assertEqual(status, 401, raw)

    def test_ending_never_started_round_is_noop_200(self):
        status, env, raw = _post_split(TEST_APP_SECRET, time_str=_now(), table_id=SAFE_TABLE,
                                       game_id="itest-never-" + _now(),
                                       game_round="gc-" + _now(), app_env=APP_ENV)
        self.assertEqual(status, 200, raw)
        self.assertEqual(env.get("code"), 200)

    def test_arbitrary_table_round_start_reports_stream_offline(self):
        status, env, raw = _post_split(TEST_APP_SECRET, time_str=_now(),
                                       table_id="itest-arbitrary-" + _now(),
                                       game_id="itest-arb-" + _now(), app_env=APP_ENV)
        # Docs section 5: unresolvable/offline stream -> HTTP 500 + code 50001.
        # Branch on code, not on the msg text.
        self.assertEqual(status, 500, raw)
        self.assertEqual(env.get("code"), 50001, raw)
        self.assertIn("is not online", env.get("msg", ""))

    def test_round_start_then_end(self):
        game_id = "itest-roundtrip-" + _now()
        start_status, start_env, start_raw = _post_split(
            TEST_APP_SECRET, time_str=_now(), table_id=SAFE_TABLE,
            game_id=game_id, app_env=APP_ENV)
        if start_status == 500 and start_env.get("code") == 50001:
            self.skipTest("table %r has no online stream right now (code=50001); "
                          "re-run once it is publishing, body=%s" % (SAFE_TABLE, start_raw))
        self.assertEqual(start_status, 200, start_raw)
        self.assertEqual(start_env.get("code"), 200)

        time.sleep(5)  # avoid the documented "nothing to finalize" race

        end_status, end_env, end_raw = _post_split(
            TEST_APP_SECRET, time_str=_now(), table_id=SAFE_TABLE, game_id=game_id,
            game_round="gc-" + _now(), app_env=APP_ENV)
        if end_status == 500:
            self.skipTest("round-end hit the documented \"nothing to finalize\" race, body=%s" % end_raw)
        self.assertEqual(end_status, 200, end_raw)
        self.assertEqual(end_env.get("code"), 200)

    def test_conflicting_owner_round_start_rejected(self):
        game_a = "itest-owner-a-" + _now()
        game_b = "itest-owner-b-" + _now()
        started = False
        try:
            s_a, e_a, raw_a = _post_split(TEST_APP_SECRET, time_str=_now(),
                                          table_id=SAFE_TABLE, game_id=game_a, app_env=APP_ENV)
            if s_a == 500 and e_a.get("code") == 50001:
                self.skipTest("table %r has no online stream, cannot observe owner conflict, body=%s"
                              % (SAFE_TABLE, raw_a))
            self.assertEqual(s_a, 200, raw_a)
            started = True

            s_b, e_b, raw_b = _post_split(TEST_APP_SECRET, time_str=_now(),
                                          table_id=SAFE_TABLE, game_id=game_b, app_env=APP_ENV)
            # Docs section 5: a conflict is HTTP 500 (not 409).
            self.assertEqual(s_b, 500, raw_b)
            self.assertEqual(e_b.get("code"), 500)
        finally:
            if started:
                _post_split(TEST_APP_SECRET, time_str=_now(), table_id=SAFE_TABLE,
                            game_id=game_a, game_round="gc-cleanup-" + _now(), app_env=APP_ENV)


if __name__ == "__main__":
    unittest.main(verbosity=2)
