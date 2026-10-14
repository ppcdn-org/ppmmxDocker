#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Local end-to-end self test for the on-demand recording API (optional).

Stands up a minimal environment on this machine and runs the whole on-demand
recording path for real, including the object-storage upload:

    fake ppcenter (WS registration + appSecret delivery)
        -> a real ppmmx record node process
        -> ffmpeg publishes a test pattern over RTMP to {appId}/{tableId}-{view}
        -> record_api.py performs round-start / round-end
        -> the recorder faststart-remuxes and uploads the round to a local
           S3-compatible object store (standing in for OVH net-storage)
        -> verify the uploaded object is playable and print its playback URL

Difference from test_record_api.py:
  * test_record_api.py hits a real production node and covers the
    auth/parameter/status-code contract;
  * this script verifies the success path locally: a real recording file plus a
    real upload whose object URL plays.

Why a fake ppcenter: a current record node registers with the control plane at
startup and pulls appId->appSecret from it (split-rec uses that secret for
signature verification); without a control plane the node exits.

Requirements:
  * Python 3.8+ (standard library only)
  * a ppmmx executable (build with `go build -o mmx.exe .` in the ppmmx repo)
  * ffmpeg

Usage:
    python local_e2e.py --mmx /path/to/mmx.exe --ffmpeg /path/to/ffmpeg
    # or set MMX_BIN / FFMPEG_BIN
    python local_e2e.py

    # record a specific app/table/view for 15s and keep the files
    python local_e2e.py --app-id keyc0c021b8ef993bcc \
        --table-id B01 --view frontView --media-seconds 15 \
        --work-dir ./recordings/B01-frontView
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import http.server
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import record_api as ra  # noqa: E402

for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def _decode_aws_chunked(raw: bytes) -> bytes:
    """Strip AWS SigV4 'aws-chunked' framing: <hexsize>;chunk-signature=..\\r\\n<data>\\r\\n"""
    out = bytearray()
    i = 0
    n = len(raw)
    while i < n:
        j = raw.find(b"\r\n", i)
        if j < 0:
            break
        line = raw[i:j]
        size_hex = line.split(b";", 1)[0].strip()
        try:
            size = int(size_hex, 16)
        except ValueError:
            break
        if size == 0:
            break
        start = j + 2
        out += raw[start:start + size]
        i = start + size + 2
    return bytes(out)


# --------------------------------------------------------------------------- #
# Fake ppcenter: one socket server serving both the control WebSocket and HTTP
# --------------------------------------------------------------------------- #

class _BufferedSock:
    def __init__(self, conn):
        self.conn = conn
        self.buf = b""

    def read(self, n: int) -> bytes:
        while len(self.buf) < n:
            chunk = self.conn.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def read_line(self) -> bytes:
        while b"\r\n" not in self.buf:
            chunk = self.conn.recv(65536)
            if not chunk:
                raise EOFError
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\r\n")
        return line


def _read_http(bs: _BufferedSock):
    lines = []
    while True:
        line = bs.read_line()
        lines.append(line)
        if line == b"":
            break
    reqline = lines[0].decode("latin1").split(" ")
    headers = {}
    for raw in lines[1:-1]:
        text = raw.decode("latin1")
        if ":" in text:
            k, v = text.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return reqline, headers


def _read_ws_frame(bs: _BufferedSock):
    b0 = bs.read(1)[0]
    opcode = b0 & 0x0F
    b1 = bs.read(1)[0]
    masked = b1 & 0x80
    length = b1 & 0x7F
    if length == 126:
        length = struct.unpack(">H", bs.read(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", bs.read(8))[0]
    mask = bs.read(4) if masked else b""
    payload = bs.read(length) if length else b""
    if masked:
        payload = bytes(c ^ mask[i % 4] for i, c in enumerate(payload))
    return opcode, payload


def _send_ws_frame(conn, opcode: int, payload: bytes) -> None:
    hdr = bytes([0x80 | opcode])
    if len(payload) < 126:
        hdr += bytes([len(payload)])
    elif len(payload) <= 0xFFFF:
        hdr += bytes([126]) + struct.pack(">H", len(payload))
    else:
        hdr += bytes([127]) + struct.pack(">Q", len(payload))
    conn.sendall(hdr + payload)


def _register_ack() -> bytes:
    # Minimal protobuf: field1 = "COMMAND_TYPE_REGISTER_ACK", field2 = accepted(true)
    msg_type = b"COMMAND_TYPE_REGISTER_ACK"
    return bytes([0x0A, len(msg_type)]) + msg_type + bytes([0x10, 0x01])


class StubPpcenter:
    """Enough of a control plane: completes the WS registration handshake and
    serves app credentials over HTTP."""

    def __init__(self, app_id: str, app_secret: str):
        self.app_id = app_id
        self.app_secret = app_secret
        self.port = _free_port()
        self._ln = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._ln.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._ln.bind(("127.0.0.1", self.port))
        self._ln.listen(16)
        self.registered = threading.Event()
        self._running = True

    @property
    def control_url(self) -> str:
        return "ws://127.0.0.1:%d/ws/mmx" % self.port

    def start(self) -> None:
        threading.Thread(target=self._accept_loop, daemon=True).start()

    def stop(self) -> None:
        self._running = False
        try:
            self._ln.close()
        except OSError:
            pass

    def _accept_loop(self) -> None:
        while self._running:
            try:
                conn, _ = self._ln.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn) -> None:
        try:
            bs = _BufferedSock(conn)
            reqline, headers = _read_http(bs)
            path = reqline[1] if len(reqline) > 1 else "/"
            if path.startswith("/ws"):
                self._ws(conn, bs, headers)
            else:
                self._http(conn, path)
        except (EOFError, OSError):
            pass
        finally:
            try:
                conn.close()
            except OSError:
                pass

    def _ws(self, conn, bs, headers) -> None:
        key = headers.get("sec-websocket-key", "")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        conn.sendall((
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Accept: %s\r\n\r\n" % accept
        ).encode())
        acked = False
        while True:
            opcode, payload = _read_ws_frame(bs)
            if opcode == 0x8:
                return
            if opcode == 0x9:
                _send_ws_frame(conn, 0xA, payload)
                continue
            if not acked and b"COMMAND_TYPE_REGISTER" in payload:
                _send_ws_frame(conn, 0x2, _register_ack())
                acked = True
                self.registered.set()

    def _http(self, conn, path: str) -> None:
        if "app-credentials" in path:
            body = json.dumps({"apps": [{
                "appId": self.app_id, "appSecret": self.app_secret, "keyId": "default",
            }]}).encode()
        else:
            body = b"{}"
        conn.sendall((
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
            "Content-Length: %d\r\nConnection: close\r\n\r\n" % len(body)
        ).encode() + body)


# --------------------------------------------------------------------------- #
# Local S3-compatible object store (stands in for OVH net-storage)
# --------------------------------------------------------------------------- #

class LocalObjectStore:
    def __init__(self):
        self.port = _free_port()
        self.root = tempfile.mkdtemp(prefix="objstore_")
        self.uploaded = []  # list of (bucket, key, size)
        handler = self._make_handler()
        self._httpd = http.server.ThreadingHTTPServer(("127.0.0.1", self.port), handler)
        self._thread = threading.Thread(target=self._httpd.serve_forever, daemon=True)

    def _make_handler(self):
        store = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):  # silence
                pass

            def _split(self):
                path = urllib.parse.unquote(self.path.split("?", 1)[0]).strip("/")
                if not path:
                    return None, None
                if "/" not in path:
                    return path, None  # bucket-level (existence / location) probe
                bucket, key = path.split("/", 1)
                key = key.strip("/")
                if not bucket or not key:
                    return bucket or None, None
                return bucket, key

            def _dest(self, bucket, key):
                return os.path.join(store.root, bucket, key)

            def do_PUT(self):
                bucket, key = self._split()
                if bucket is None or key is None:
                    self.send_response(400)
                    self.end_headers()
                    return
                length = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(length) if length else b""
                # MinIO/aws-sdk use AWS SigV4 "aws-chunked" streaming when the
                # signature covers the payload; strip the per-chunk framing to
                # recover the real object bytes.
                if "aws-chunked" in (self.headers.get("Content-Encoding", "")) or \
                        self.headers.get("x-amz-content-sha256", "").startswith("STREAMING"):
                    raw = _decode_aws_chunked(raw)
                dest = self._dest(bucket, key)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as f:
                    f.write(raw)
                store.uploaded.append((bucket, key, len(raw)))
                self.send_response(200)
                self.send_header("ETag", '"%s"' % hashlib.md5(raw).hexdigest())
                self.send_header("Content-Length", "0")
                self.end_headers()

            def _serve_head(self, body: bool):
                bucket, key = self._split()
                if bucket is None:
                    self.send_response(400)
                    self.end_headers()
                    return
                if key is None:
                    # Bucket exists / location probe. MinIO's client always asks
                    # for the bucket location first and needs a valid XML body.
                    if body:
                        xml = (b'<?xml version="1.0" encoding="UTF-8"?>'
                               b'<LocationConstraint xmlns="http://s3.amazonaws.com/doc/2006-03-01/"></LocationConstraint>')
                        self.send_response(200)
                        self.send_header("Content-Type", "application/xml")
                        self.send_header("Content-Length", str(len(xml)))
                        self.end_headers()
                        self.wfile.write(xml)
                    else:
                        self.send_response(200)
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                    return
                dest = self._dest(bucket, key)
                if not os.path.isfile(dest):
                    self.send_response(404)
                    self.end_headers()
                    return
                size = os.path.getsize(dest)
                self.send_response(200)
                self.send_header("Content-Type", "video/mp4")
                self.send_header("Content-Length", str(size))
                self.end_headers()
                if body:
                    with open(dest, "rb") as f:
                        self.wfile.write(f.read())

            def do_GET(self):
                self._serve_head(True)

            def do_HEAD(self):
                self._serve_head(False)

        return Handler

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        try:
            self._httpd.shutdown()
        except Exception:
            pass

    def playback_url(self, bucket: str, key: str) -> str:
        return "http://127.0.0.1:%d/%s/%s" % (self.port, bucket, key)


# --------------------------------------------------------------------------- #
# Main flow
# --------------------------------------------------------------------------- #

def _wait_ready(admin_port: int, proc: subprocess.Popen, timeout: float = 30.0) -> bool:
    url = "http://127.0.0.1:%d/v3/recordings/list" % admin_port
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            return False
        try:
            urllib.request.urlopen(url, timeout=1)
            return True
        except Exception:
            time.sleep(0.2)
    return False


def _find_mp4(root: str):
    found = []
    for base, _, files in os.walk(root):
        for name in files:
            if name.endswith(".mp4"):
                p = os.path.join(base, name)
                found.append((p, os.path.getsize(p)))
    return found


def run(args: argparse.Namespace) -> int:
    explicit_dir = bool(args.work_dir)
    work = os.path.abspath(args.work_dir) if explicit_dir else tempfile.mkdtemp(prefix="recorde2e_")
    os.makedirs(work, exist_ok=True)
    print("work dir : %s" % work)
    keep = args.keep or explicit_dir
    stub = StubPpcenter(args.app_id, args.app_secret)
    store = None if args.no_upload else LocalObjectStore()
    proc = None
    ff = None
    try:
        stub.start()
        print("fake control plane : %s" % stub.control_url)
        if store is not None:
            store.start()
            print("local object store  : http://127.0.0.1:%d  (stand-in for net-storage)" % store.port)

        admin, api = _free_port(), _free_port()
        rtmp, webrtc, ice = _free_port(), _free_port(), _free_port()
        cfg = """
logLevel: info
logDestinations: [stdout]
mmxControl: true
mmxControlURL: {control}
mmxNodeRole: NODE_ROLE_RECORDER
mmxNodeRegion: e2e
mmxNodeCapacity: 10
mmxHeartbeatInterval: 10s
mmxWebRTCBaseURL: http://127.0.0.1:{webrtc}
api: true
apiAddress: :{api}
adminAddress: :{admin}
adminName: record-e2e
rtsp: false
rtmp: true
rtmpAddress: :{rtmp}
hls: false
webrtc: true
webrtcAddress: :{webrtc}
webrtcLocalUDPAddress: :{ice}
webrtcIPsFromInterfaces: true
webrtcAllowOrigins: ["*"]
srt: false
moq: false
splitRecAuthMode: simple
paths:
  all:
    source: publisher
    sourceOnDemand: false
    record: no
    recordPath: data/recordings/%Y%m%d/%path.%Y%m%d%H%M%S-%f
    recordFormat: fmp4
    recordPartDuration: 1s
    recordSegmentDuration: 0.5h
    recordDeleteAfter: 24h
""".format(control=stub.control_url, webrtc=webrtc, api=api, admin=admin, rtmp=rtmp, ice=ice)
        cfg_path = os.path.join(work, "record.e2e.yml")
        with open(cfg_path, "w", encoding="utf-8") as f:
            f.write(cfg)

        env_lines = ["MMX_NODE_SECRET=e2e-node-secret", "APP_ENV=test"]
        if store is not None:
            # MinIO is used as the S3 fallback; the bucket is the lowercased
            # appEnv ("test") and the object key is the file's base name.
            env_lines += [
                "MINIO_EP=127.0.0.1:%d" % store.port,
                "MINIO_AK=minioadmin",
                "MINIO_SK=minioadmin",
                "MINIO_USESSL=false",
                "MINIO_URL=http://127.0.0.1:%d" % store.port,
            ]
        with open(os.path.join(work, ".env"), "w", encoding="utf-8") as f:
            f.write("\n".join(env_lines) + "\n")

        log = open(os.path.join(work, "mmx.log"), "w", encoding="utf-8", errors="replace")
        proc = subprocess.Popen([args.mmx, cfg_path], cwd=work,
                                stdout=log, stderr=subprocess.STDOUT)
        if not _wait_ready(admin, proc):
            print("FAIL: mmx never became ready (or exited early)")
            print(open(os.path.join(work, "mmx.log"), encoding="utf-8", errors="replace").read())
            return 1
        print("node ready : admin=http://127.0.0.1:%d  (WS registered=%s)" % (admin, stub.registered.is_set()))
        if not stub.registered.is_set():
            print("FAIL: node never registered with the control plane")
            return 1

        stream = "%s/%s-%s" % (args.app_id, args.table_id, args.view)
        rtmp_url = "rtmp://127.0.0.1:%d/%s" % (rtmp, stream)
        print("ffmpeg publish : %s" % rtmp_url)
        ff_log = open(os.path.join(work, "ffmpeg.log"), "w", encoding="utf-8", errors="replace")
        ff = subprocess.Popen([
            args.ffmpeg, "-hide_banner", "-loglevel", "warning", "-re",
            "-f", "lavfi", "-i", "testsrc=size=640x360:rate=25",
            "-f", "lavfi", "-i", "sine=frequency=1000",
            "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-g", "25",
            "-c:a", "aac", "-t", "120",
            "-f", "flv", rtmp_url,
        ], stdout=ff_log, stderr=subprocess.STDOUT)
        time.sleep(4)  # let the stream actually come online

        client = ra.RecordApiClient("http://127.0.0.1:%d" % admin, args.app_id,
                                    args.app_secret, app_env=args.app_env)

        print("\n--- round-start ---")
        status, env, raw = client.round_start(args.table_id, args.game_id)
        print("HTTP %s  %s" % (status, raw))
        if not ra.is_ok(status, env):
            print("FAIL: round-start did not succeed")
            return 1

        print("waiting %ss to accumulate media in this round ..." % args.media_seconds)
        time.sleep(args.media_seconds)

        print("\n--- round-end ---")
        status, env, raw = client.round_end(args.table_id, args.game_id, args.game_round)
        print("HTTP %s  %s" % (status, raw))
        if not ra.is_ok(status, env):
            print("FAIL: round-end did not succeed")
            return 1

        expected = "%s-%s-%s.mp4" % (args.table_id, args.view, args.game_round)
        print("\nexpected file : %s" % expected)

        if store is None:
            time.sleep(2)
            found = _find_mp4(work)
            for p, s in found:
                print("  produced    : %s (%d bytes)" % (p, s))
            return 0 if any(os.path.basename(p) == expected for p, _ in found) else 1

        # Wait for the recorder's uploader to faststart-remux and PUT the object.
        bucket = args.app_env.lower()
        deadline = time.time() + 30
        obj = None
        while time.time() < deadline:
            for b, k, size in list(store.uploaded):
                if k == expected:
                    obj = (b, k, size)
                    break
            if obj:
                break
            time.sleep(0.5)
        if not obj:
            print("FAIL: object %r never appeared in the object store" % expected)
            return 1

        url = store.playback_url(obj[0], obj[1])
        print("uploaded object : %s/%s (%d bytes)" % (obj[0], obj[1], obj[2]))
        print("\nPLAYBACK URL    : %s" % url)

        # Fetch it back over HTTP to prove the URL serves the playable file.
        got = os.path.join(work, "uploaded_" + expected)
        with urllib.request.urlopen(url, timeout=15) as resp:
            data = resp.read()
        with open(got, "wb") as f:
            f.write(data)
        print("fetched via URL : HTTP 200, %d bytes -> %s" % (len(data), got))

        found = _find_mp4(work)
        for p, s in found:
            print("  local file  : %s (%d bytes)" % (p, s))

        print("\nPASS: on-demand recording + net-storage upload end-to-end succeeded")
        return 0
    finally:
        if ff is not None:
            ff.terminate()
        if proc is not None:
            proc.terminate()
        stub.stop()
        if store is not None:
            store.stop()
        if keep:
            print("kept work dir: %s" % work)
        else:
            shutil.rmtree(work, ignore_errors=True)


def main() -> int:
    p = argparse.ArgumentParser(description="Local end-to-end self test for the on-demand recording API")
    p.add_argument("--mmx", default=os.environ.get("MMX_BIN", ""),
                   help="path to the ppmmx executable (env MMX_BIN)")
    p.add_argument("--ffmpeg", default=os.environ.get("FFMPEG_BIN", "ffmpeg"),
                   help="path to ffmpeg (env FFMPEG_BIN, defaults to ffmpeg on PATH)")
    p.add_argument("--app-id", default="app_e2e")
    p.add_argument("--app-secret", default="e2esecret0123456789")
    p.add_argument("--table-id", default="table")
    p.add_argument("--view", default="view", help="view name; stream is {tableId}-{view}")
    p.add_argument("--game-id", default="e2egame1")
    p.add_argument("--game-round", default="gc001")
    p.add_argument("--app-env", default="test")
    p.add_argument("--media-seconds", type=float, default=15.0, help="seconds between start and end")
    p.add_argument("--work-dir", default="", help="run in this directory instead of a temp dir (files are kept)")
    p.add_argument("--keep", action="store_true", help="keep the temporary work directory")
    p.add_argument("--no-upload", action="store_true", help="skip the local object store/upload")
    args = p.parse_args()

    if not args.mmx or not os.path.exists(args.mmx):
        print("error: --mmx must point to a ppmmx executable (or set MMX_BIN)", file=sys.stderr)
        return 2
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
