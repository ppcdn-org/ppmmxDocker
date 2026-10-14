#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""On-demand recording API (/api/record/split) client example.

Standard library only. A business backend can follow this file directly to
implement the signature and the two-phase start/end calls.

Protocol summary (full spec: docs/api/user-record-api.md):
  * A "round" is one round-start call (gameRound empty) plus one round-end
    call (gameRound non-empty).
  * The Authorization header is computed with the calling app's own
    appSecret. Default simple mode:
        md5(appSecret + time + appId + tableId + [gameRound] + gameId)
    When gameRound is empty (round-start) that field is not appended at all.
  * Advance mode: HMAC-SHA256(secret, canonical_json) plus an
    X-Split-Rec-Nonce header for replay protection.
  * time is the signing instant as a unix-seconds string; in simple mode it
    must be within +/-30s of the server clock.

Usage:
    export RECORD_API_APP_ID=app_xxx
    export RECORD_API_APP_SECRET=xxxxxxxx

    # round start
    python record_api.py start --table-id table1 --game-id p2w001

    # round end
    python record_api.py end --table-id table1 --game-id p2w001 --game-round gc001

    # start -> wait N seconds -> end
    python record_api.py auto --table-id table1 --game-id p2w001 --wait 30

    # print the signature/body only (no request)
    python record_api.py sign --table-id table1 --game-id p2w001
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Optional, Tuple

# Windows consoles may default to GBK/CP950; force UTF-8 output.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

DEFAULT_BASE_URL = os.environ.get("RECORD_API_BASE_URL", "https://record.pp-cdn.org")
SPLIT_PATH = "/api/record/split"

# Server-side identifierPattern: ^[A-Za-z0-9_-]{1,128}$
_IDENTIFIER_MAX = 128


# --------------------------------------------------------------------------- #
# Signing
# --------------------------------------------------------------------------- #

def sign_simple(secret: str, time_str: str, app_id: str, table_id: str,
                game_round: str, game_id: str) -> str:
    """simple-mode signature: 32 lowercase hex md5.

    base = secret + time + appId + tableId + (gameRound if non-empty) + gameId
    When gameRound is an empty string it is not appended at all (as opposed to
    appending an empty string).
    """
    base = secret + time_str + app_id + table_id
    if game_round:
        base += game_round
    base += game_id
    return hashlib.md5(base.encode("utf-8")).hexdigest()


def canonical_json(time_str: str, app_id: str, table_id: str,
                   game_round: str, game_id: str, nonce: str) -> str:
    """advance-mode canonical JSON with a fixed field order."""
    return json.dumps(
        {
            "time": time_str,
            "appId": app_id,
            "tableId": table_id,
            "gameRound": game_round,
            "gameId": game_id,
            "nonce": nonce,
        },
        separators=(",", ":"),
        ensure_ascii=False,
    )


def sign_advance(secret: str, time_str: str, app_id: str, table_id: str,
                 game_round: str, game_id: str, nonce: str) -> str:
    """advance-mode signature: full Authorization header value."""
    payload = canonical_json(time_str, app_id, table_id, game_round, game_id, nonce).encode("utf-8")
    mac = hmac.new(secret.encode("utf-8"), payload, hashlib.sha256).hexdigest()
    return "HMAC-SHA256 " + mac


# --------------------------------------------------------------------------- #
# Request
# --------------------------------------------------------------------------- #

class RecordApiError(Exception):
    """Transport-level failure (unreachable host, timeout, ...)."""


def build_request(app_id: str, table_id: str, game_id: str, game_round: str = "",
                  app_env: str = "", secret: str = "", auth_mode: str = "simple",
                  time_str: Optional[str] = None, nonce: Optional[str] = None
                  ) -> Tuple[Dict[str, Any], Dict[str, str], str]:
    """Build one split request.

    Returns (body, headers, time_str). Callers can hand this to call_split or
    print it to compare against the docs by hand.
    """
    if time_str is None:
        time_str = str(int(time.time()))

    if auth_mode == "advance":
        if nonce is None:
            nonce = secrets.token_hex(16)
        auth = sign_advance(secret, time_str, app_id, table_id, game_round, game_id, nonce)
        headers = {
            "Content-Type": "application/json",
            "Authorization": auth,
            "X-Split-Rec-Nonce": nonce,
        }
    else:
        auth = sign_simple(secret, time_str, app_id, table_id, game_round, game_id)
        headers = {
            "Content-Type": "application/json",
            "Authorization": auth,
        }

    body: Dict[str, Any] = {
        "time": time_str,
        "appId": app_id,
        "tableId": table_id,
        "gameId": game_id,
    }
    if game_round:
        body["gameRound"] = game_round
    if app_env:
        body["appEnv"] = app_env

    return body, headers, time_str


def call_split(base_url: str, body: Dict[str, Any], headers: Dict[str, str],
               timeout: float = 15.0) -> Tuple[int, Dict[str, Any], str]:
    """POST /api/record/split, returning (http_status, parsed_envelope, raw_text).

    Business errors (4xx/5xx) are returned normally, not raised; only a
    transport failure raises RecordApiError.
    """
    url = base_url.rstrip("/") + SPLIT_PATH
    data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            status = resp.status
    except urllib.error.HTTPError as e:  # 4xx/5xx also arrive as HTTPError
        raw = e.read().decode("utf-8", "replace")
        status = e.code
    except urllib.error.URLError as e:
        raise RecordApiError("request %s failed: %s" % (url, e.reason)) from e
    except OSError as e:
        raise RecordApiError("request %s failed: %s" % (url, e)) from e

    try:
        parsed = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        parsed = {"_raw": raw}
    return status, parsed, raw


# --------------------------------------------------------------------------- #
# Convenience wrapper
# --------------------------------------------------------------------------- #

class RecordApiClient:
    """Thin client around the on-demand recording API."""

    def __init__(self, base_url: str, app_id: str, app_secret: str,
                 auth_mode: str = "simple", app_env: str = "", timeout: float = 15.0):
        self.base_url = base_url
        self.app_id = app_id
        self.app_secret = app_secret
        self.auth_mode = auth_mode
        self.app_env = app_env
        self.timeout = timeout

    def _call(self, table_id: str, game_id: str, game_round: str = "") -> Tuple[int, Dict[str, Any], str]:
        body, headers, _ = build_request(
            app_id=self.app_id, table_id=table_id, game_id=game_id,
            game_round=game_round, app_env=self.app_env,
            secret=self.app_secret, auth_mode=self.auth_mode,
        )
        return call_split(self.base_url, body, headers, self.timeout)

    def round_start(self, table_id: str, game_id: str) -> Tuple[int, Dict[str, Any], str]:
        """Round start (gameRound empty)."""
        return self._call(table_id, game_id, game_round="")

    def round_end(self, table_id: str, game_id: str, game_round: str) -> Tuple[int, Dict[str, Any], str]:
        """Round end (gameRound required)."""
        return self._call(table_id, game_id, game_round=game_round)


def is_ok(status: int, envelope: Dict[str, Any]) -> bool:
    return status == 200 and envelope.get("code") == 200


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def _add_common(p: argparse.ArgumentParser) -> None:
    p.add_argument("--base-url", default=DEFAULT_BASE_URL,
                   help="record node URL, default %s (env RECORD_API_BASE_URL)" % DEFAULT_BASE_URL)
    p.add_argument("--app-id", default=os.environ.get("RECORD_API_APP_ID", ""),
                   help="appId created in the console (env RECORD_API_APP_ID)")
    p.add_argument("--app-secret", default=os.environ.get("RECORD_API_APP_SECRET", ""),
                   help="that appId's own appSecret (env RECORD_API_APP_SECRET)")
    p.add_argument("--table-id", required=True, help="table/camera id, ^[A-Za-z0-9_-]{1,128}$")
    p.add_argument("--game-id", required=True, help="round/business id")
    p.add_argument("--game-round", default="", help="round id; omit for round-start")
    p.add_argument("--app-env", default="", help="optional object-name prefix (e.g. test); also part of owner identity")
    p.add_argument("--auth-mode", choices=["simple", "advance"], default="simple",
                   help="signing mode, default simple")
    p.add_argument("--timeout", type=float, default=15.0, help="HTTP timeout in seconds")


def _validate_common(args: argparse.Namespace) -> Optional[str]:
    if not args.app_id:
        return "missing --app-id (or env RECORD_API_APP_ID)"
    if not args.app_secret:
        return "missing --app-secret (or env RECORD_API_APP_SECRET)"
    for name, val in (("table-id", args.table_id), ("game-id", args.game_id),
                      ("game-round", args.game_round), ("app-env", args.app_env)):
        if val and not _valid_identifier(val):
            return "%s=%r has invalid characters (allowed: A-Za-z0-9_-, length 1..%d)" % (
                name, val, _IDENTIFIER_MAX)
    return None


def _valid_identifier(s: str) -> bool:
    if not (1 <= len(s) <= _IDENTIFIER_MAX):
        return False
    return all(c.isascii() and (c.isalnum() or c in "_-") for c in s)


def _print_result(action: str, status: int, envelope: Dict[str, Any], raw: str) -> None:
    print("[%s] HTTP %s" % (action, status))
    print("         response: %s" % (raw if raw else "(empty)"))
    code = envelope.get("code")
    if code == 200:
        print("         -> success")
    elif code == 50001:
        print("         -> no view for this tableId is currently online (request itself is fine)")
    else:
        print("         -> failed: %s" % envelope.get("msg", "unknown"))


def cmd_start(args: argparse.Namespace) -> int:
    body, headers, _ = build_request(
        app_id=args.app_id, table_id=args.table_id, game_id=args.game_id,
        app_env=args.app_env, secret=args.app_secret, auth_mode=args.auth_mode,
    )
    status, env, raw = call_split(args.base_url, body, headers, args.timeout)
    _print_result("round-start", status, env, raw)
    return 0 if is_ok(status, env) else 1


def cmd_end(args: argparse.Namespace) -> int:
    if not args.game_round:
        print("error: round-end requires --game-round", file=sys.stderr)
        return 2
    body, headers, _ = build_request(
        app_id=args.app_id, table_id=args.table_id, game_id=args.game_id,
        game_round=args.game_round, app_env=args.app_env,
        secret=args.app_secret, auth_mode=args.auth_mode,
    )
    status, env, raw = call_split(args.base_url, body, headers, args.timeout)
    _print_result("round-end", status, env, raw)
    return 0 if is_ok(status, env) else 1


def cmd_auto(args: argparse.Namespace) -> int:
    if not args.game_round:
        args.game_round = "gc%s" % int(time.time())
    client = RecordApiClient(args.base_url, args.app_id, args.app_secret,
                             args.auth_mode, args.app_env, args.timeout)

    status, env, raw = client.round_start(args.table_id, args.game_id)
    _print_result("round-start", status, env, raw)
    if not is_ok(status, env):
        return 1

    print("         ... round in progress, waiting %ss ..." % args.wait)
    time.sleep(args.wait)

    status, env, raw = client.round_end(args.table_id, args.game_id, args.game_round)
    _print_result("round-end (gameRound=%s)" % args.game_round, status, env, raw)
    return 0 if is_ok(status, env) else 1


def cmd_sign(args: argparse.Namespace) -> int:
    body, headers, t = build_request(
        app_id=args.app_id, table_id=args.table_id, game_id=args.game_id,
        game_round=args.game_round, app_env=args.app_env,
        secret=args.app_secret, auth_mode=args.auth_mode,
    )
    print("time        : %s" % t)
    print("Authorization: %s" % headers["Authorization"])
    if "X-Split-Rec-Nonce" in headers:
        print("X-Split-Rec-Nonce: %s" % headers["X-Split-Rec-Nonce"])
    print("body        : %s" % json.dumps(body, ensure_ascii=False))
    return 0


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(
        description="On-demand recording API (/api/record/split) client example",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_start = sub.add_parser("start", help="round start (gameRound empty)")
    _add_common(p_start)
    p_start.set_defaults(func=cmd_start)

    p_end = sub.add_parser("end", help="round end (requires --game-round)")
    _add_common(p_end)
    p_end.set_defaults(func=cmd_end)

    p_auto = sub.add_parser("auto", help="start -> wait --wait seconds -> end")
    _add_common(p_auto)
    p_auto.add_argument("--wait", type=int, default=10, help="seconds to wait between start and end, default 10")
    p_auto.set_defaults(func=cmd_auto)

    p_sign = sub.add_parser("sign", help="print signature and body only, no request")
    _add_common(p_sign)
    p_sign.set_defaults(func=cmd_sign)

    args = parser.parse_args(argv)

    err = _validate_common(args)
    if err:
        print("error: %s" % err, file=sys.stderr)
        return 2

    try:
        return args.func(args)
    except RecordApiError as e:
        print("transport error: %s" % e, file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
