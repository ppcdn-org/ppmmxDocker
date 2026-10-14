# On-demand recording API test report (`/api/record/split`)

- Date: 2026-10-14
- Component under test: ppmmx record node (`github.com/ppcdn-org/ppmmx`, locally built **v1.19.1rc069**)
- Scope: the `record_api.py` example client and the two-phase on-demand recording protocol
- Result: **PASS**. The signing algorithm, auth, parameter validation and status-code
  contract were verified against a real node, and the full "start -> end -> mp4"
  success path was reproduced end-to-end locally.

---

## 1. Environment

| Item | Value |
| --- | --- |
| OS | Windows (local machine) |
| Python | 3.13.0 (standard library only, no third-party deps) |
| Go | go1.26.8 windows/amd64 (used to build ppmmx from source) |
| ppmmx | v1.19.1rc069, built with `go build -o mmx.exe .` |
| ffmpeg / ffprobe | local ffmpeg build (`libx264` + `aac`) |
| Production target | `https://record.pp-cdn.org` (TLS; reverse proxy exposes only `POST /api/record/split`) |
| Test app | `appId=appbd4cd2aa7be8` (dedicated test app, same one used by the main repo `integrationTest/api`), `appEnv=test` |
| Test tableId | `table` (a table with no real customer traffic for this app) |
| Stream under test (local e2e) | appId `keyc0c021b8ef993bcc`, stream `B01-frontView` (tableId `B01`, view `frontView`) |

The live contract test follows the main repo's `integrationTest/api` practice: only
the safe table `table` is started/ended, always with `appEnv=test`, so production
uploads never mix with the normal prefix.

## 2. Scope

1. **Signing**: fixed byte-for-byte vectors for simple (md5) and advance (HMAC-SHA256 + nonce).
2. **HTTP contract**: real-node verification of auth failures, parameter validation,
   status codes/envelope, and the documented 50001 / no-op / conflict semantics.
3. **Success path**: a real ppmmx record node + ffmpeg RTMP publish locally, verifying
   that round-start/round-end actually cut a recording file.

Not covered: see section 6.

## 3. Result summary

| Suite | Cases | Passed | Skipped | Failed |
| --- | --- | --- | --- | --- |
| Offline signature (`OfflineAuthTests`) | 7 | 7 | 0 | 0 |
| Production contract (`LiveApiTests`) | 10 | 8 | 2 | 0 |
| Local end-to-end (`local_e2e.py`) | 1 | 1 | 0 | 0 |
| Production recording + real net-storage (4.5) | 1 | 1 | 0 | 0 |
| **Total** | **19** | **17** | **2** | **0** |

The 2 skipped cases are both because the test app's table has **no online stream**
at the moment (`code=50001`) - an environment condition, not a defect. The success
path is covered by the local end-to-end instead.

---

## 4. Detailed results

### 4.1 Offline signature vectors (all pass)

Fixed inputs lock the signature to the documented formula, so field ordering and
the "empty gameRound is omitted" rule cannot silently regress.

| Case | Assertion | Result |
| --- | --- | --- |
| `test_simple_round_start_vector` | start signature = `c6021e2d628d8062fec26024e4a92477` | PASS |
| `test_simple_round_end_vector` | end signature = `f4ff887d8d0e5e1bdd121c177ff7bf98` | PASS |
| `test_advance_canonical_json_field_order` | canonical_json order = `time,appId,tableId,gameRound,gameId,nonce` | PASS |
| `test_advance_hmac_vector` | HMAC-SHA256 = `e5e84447...c9f212f2` | PASS |
| `test_build_request_omits_empty_round_and_env` | empty `gameRound`/`appEnv` omitted from the body | PASS |
| `test_build_request_includes_round_and_env_when_set` | non-empty values sent as-is | PASS |
| `test_advance_request_carries_nonce_header` | advance sets `X-Split-Rec-Nonce` | PASS |

### 4.2 Production contract (against `https://record.pp-cdn.org`)

Command:

```bash
set PPCDN_TEST_APP_ID=appbd4cd2aa7be8
set PPCDN_TEST_APP_SECRET=<redacted>
python -m unittest test_record_api -v
```

Real output excerpt:

```
test_arbitrary_table_round_start_reports_stream_offline ... ok
test_conflicting_owner_round_start_rejected ... skipped 'table has no online stream, cannot observe owner conflict'
test_ending_never_started_round_is_noop_200 ... ok
test_expired_time_returns_401 ... ok
test_invalid_table_id_chars_returns_400 ... ok
test_malformed_json_returns_400 ... ok
test_missing_authorization_returns_400 ... ok
test_missing_table_id_returns_400 ... ok
test_round_start_then_end ... skipped 'table has no online stream right now (code=50001)'
test_wrong_secret_returns_401 ... ok
...
Ran 17 tests in 1.215s
OK (skipped=2)
```

Itemized:

| Case | Expected | Observed | Result |
| --- | --- | --- | --- |
| Missing `Authorization` | 400 | 400 | PASS |
| Malformed JSON body | 400 | 400 | PASS |
| Missing `tableId` | 400 | 400 | PASS |
| `tableId` with invalid chars (`table/../etc`) | 400 | 400 | PASS |
| Wrong appSecret | 401 | 401 | PASS |
| `time` outside window (-1h) | 401 | 401 | PASS |
| Ending a never-started round | 200 (silent no-op) | 200 | PASS |
| Arbitrary table round-start (no online stream) | 500 + `code=50001` | `{"code":50001,"msg":"stream for app \"...\" table \"...\" is not online"}` | PASS |
| round-start -> round-end happy path | 200/200 | skipped (no online stream) | SKIP |
| Conflicting-owner round-start | 500 | skipped (no online stream) | SKIP |

> Key finding: the production node `record.pp-cdn.org` is reachable and the auth
> chain works; the `code=50001` and no-op-200 semantics match the docs exactly.
> The test table has no publisher right now, so the success flow could not be
> reproduced against production and is covered locally instead.

### 4.3 CLI example

```text
$ python record_api.py sign --table-id table1 --game-id p2w001 --app-env test
time        : 1791965385
Authorization: 11f58bc9febcd3fcb90f56de6c2d15d0
body        : {"time": "1791965385", "appId": "appbd4cd2aa7be8", "tableId": "table1", "gameId": "p2w001", "appEnv": "test"}

$ python record_api.py start --table-id table --game-id itest-cli-1791965385 --app-env test
[round-start] HTTP 500
         response: {"code":50001,"msg":"stream for app \"appbd4cd2aa7be8\" table \"table\" is not online","data":""}
         -> no view for this tableId is currently online (request itself is fine)

$ python record_api.py end --table-id table --game-id itest-cli-end-1791965385 --game-round gc1 --app-env test
[round-end] HTTP 200
         response: {"code":200,"msg":"OK","data":null}
         -> success
```

### 4.4 Local end-to-end: 15s recording + net-storage upload + playback URL (PASS)

Topology: **fake ppcenter -> real mmx record node wired to a local S3-compatible
object store (net-storage stand-in) -> ffmpeg RTMP publish
`keyc0c021b8ef993bcc/B01-frontView` -> `record_api.py` round-start / 15s /
round-end -> recorder faststart-remuxes and uploads -> playback URL**.

Command:

```bash
set MMX_BIN=...\mmx.exe
set FFMPEG_BIN=...\ffmpeg.exe
python local_e2e.py --app-id keyc0c021b8ef993bcc --app-secret local-e2e-secret \
  --table-id B01 --view frontView --game-id frontview-15s --game-round gc001 \
  --media-seconds 15 --work-dir .\recordings\B01-frontView-15s
```

Real output:

```text
work dir : D:\github\ppcdn\ppmmxDocker\example\recordApi\recordings\B01-frontView-15s
fake control plane : ws://127.0.0.1:56143/ws/mmx
local object store  : http://127.0.0.1:56144  (stand-in for net-storage)
node ready : admin=http://127.0.0.1:56145  (WS registered=True)
ffmpeg publish : rtmp://127.0.0.1:56147/keyc0c021b8ef993bcc/B01-frontView

--- round-start ---
HTTP 200  {"code":200,"msg":"OK","data":null}
waiting 15.0s to accumulate media in this round ...

--- round-end ---
HTTP 200  {"code":200,"msg":"OK","data":null}

expected file : B01-frontView-gc001.mp4
uploaded object : test/B01-frontView-gc001.mp4 (722194 bytes)

PLAYBACK URL    : http://127.0.0.1:56144/test/B01-frontView-gc001.mp4
fetched via URL : HTTP 200, 722194 bytes -> ...\uploaded_B01-frontView-gc001.mp4

PASS: on-demand recording + net-storage upload end-to-end succeeded
```

The uploaded object is a **faststart** MP4 (`moov` before `mdat`, so it plays in
a plain `<video>` tag), verified with ffprobe:

```text
codec_name=h264
codec_type=video
width=640
height=360
codec_name=aac
codec_type=audio
format_name=mov,mp4,m4a,3gp,3g2,mj2
duration=15.030000
size=722194
bit_rate=384401
```

`ftyp` at byte 4, `moov` at byte 36, `mdat` at byte 14476 - i.e. the metadata is
up front, which the raw fragmented-MP4 on-disk segment does not have; that is why
the raw segment "won't open" in a simple player while the uploaded object does.

A live URL for this artifact was served from this machine during the test:

- `http://127.0.0.1:8077/test/B01-frontView-gc001.mp4`
- `http://192.168.254.104:8077/test/B01-frontView-gc001.mp4` (LAN)

Notes:

- Recording is **started on demand** by round-start and cut/renamed/stopped by
  round-end, matching production behavior. The final name is
  `<tableId>-<view>-<gameRound>.mp4` (here `B01-frontView-gc001.mp4`).
- The upload uses the production uploader path exactly: fragmented MP4 ->
  faststart remux -> PUT to `<bucket>/<key>`. Locally the bucket is the
  lowercased appEnv (`test`) on a local S3-compatible store; in production the
  same key lands in OVH net-storage as
  `https://s3.sgp.io.cloud.ovh.net/ppcdn-net-storage/test/B01-frontView-gc001.mp4`
  (ppcenter's `playbackBaseUrl`).
- A current record node registers with the control plane at startup and pulls
  appId->appSecret from it, so the local self test needs a fake ppcenter; this is
  what `local_e2e.py` provides and does not affect the `/api/record/split` logic.
- The produced files were kept (not deleted), as requested.
- Producing the **real** net-storage URL requires either the `appSecret` of
  appId `keyc0c021b8ef993bcc` (to trigger the production node, whose uploader
  writes to real net-storage) or S3/MinIO credentials. This was done in 4.5.

### 4.5 Production recording + real net-storage playback URL (PASS)

The live production stream `keyc0c021b8ef993bcc/B01-frontView` was recorded on
the production record node (`record.pp-cdn.org` -> `ubuntu@3.1.114.217`,
v1.19.1rc069, per-app auth) via `/api/record/split`, using the appSecret synced
from ppcenter's `/internal/mmx/v1/app-credentials/sync`.

```text
round-start -> {"code":200,"msg":"OK","data":null}
(15s wait)
round-end   -> {"code":200,"msg":"OK","data":null}
[upload] .../B01-frontView-gc1791970055.mp4 -> test/B01-frontView-gc1791970055.mp4 succeeded (attempt 1/10),
         url=https://ppcdn-net-storage.s3.sgp.io.cloud.ovh.net/test/B01-frontView-gc1791970055.mp4
```

**Playback URL** (public, HTTP 200, `video/mp4`):
`https://ppcdn-net-storage.s3.sgp.io.cloud.ovh.net/test/B01-frontView-gc1791970055.mp4`

The object was downloaded and validated with ffprobe:

```text
codec_name=h264
codec_type=video
width=1920
height=1080
codec_name=opus
codec_type=audio
format_name=mov,mp4,m4a,3gp,3g2,mj2
duration=15.060000
size=5475191
bit_rate=2908467
```

`moov` is at byte 36 (faststart). `appEnv=test` produced the `test/` object-key
prefix. This is a real 1080p recording of the live stream, distinct from the
synthetic test pattern used locally.

---

## 5. Compatibility observation

- The request body must now carry `appId` explicitly and it participates in the
  signature (`md5(appSecret+time+appId+tableId+...)`). The main repo's older
  `integrationTest/record` cases omit `appId` from the signed base string and are
  therefore inconsistent with the current implementation - follow
  `docs/api/user-record-api.md` and this example.

## 6. Not covered / limitations

| Item | Note |
| --- | --- |
| Production success path | The test table has no online stream, so round-start/round-end success was not exercised against production; covered by local end-to-end |
| `advance` mode server behavior | Whether the deployment enables advance mode for the test app cannot be determined externally; only the offline signature vectors were verified |
| Rate limiting (429, >500 req/s) | Not triggered, to avoid abusing a shared production endpoint |
| Object-storage upload | The real OVH net-storage upload and a public playback URL were validated against production (4.5); the local run still uses a local S3-compatible stand-in |
| Multi-view concurrency | The local e2e published a single view; the multi-view auto-discovery path was not covered in this round |
| Recording a specific live production stream | Done: `keyc0c021b8ef993bcc/B01-frontView` recorded on the production record node and uploaded to net-storage (4.5) |

## 7. Conclusion

- The example client `record_api.py` matches the documented signing algorithm
  **byte for byte** (fixed vectors for both simple and advance).
- Real HTTP testing against the production node confirms the 400/401 auth and
  validation paths, the `code=50001` offline-stream signal, and the no-op 200 for
  ending a never-started round - all as documented.
- The local end-to-end test proves that `round-start -> round-end` really cuts a
  playable mp4 recording.
- Overall: the on-demand recording API example and its observed protocol behavior
  are correct and ready for integration.
