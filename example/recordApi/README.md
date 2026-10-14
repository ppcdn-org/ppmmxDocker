# On-demand recording API example (`/api/record/split`)

"On-demand recording" (a.k.a. round recording / split-rec) records one
business activity with a clear start and end (a game, an auction, a class).
The business backend calls `round-start` when the activity begins and
`round-end` when it ends; the record node cuts exactly that interval into one
playable mp4.

This directory contains ready-to-reuse examples and self tests:

| File | Description |
| --- | --- |
| `record_api.py` | Example client (standard library only): signing + two-phase calls |
| `test_record_api.py` | Live test: offline signature vectors + real HTTP contract against a node |
| `local_e2e.py` | Local end-to-end self test (optional): real ppmmx node + ffmpeg, verifies an actual mp4 is produced |
| `.env.example` | Environment variable template |
| `TEST_REPORT.md` | Test report with real run output |

Full protocol spec: `docs/api/user-record-api.md`.

## 1. Quick start

```bash
export RECORD_API_APP_ID=app_xxx
export RECORD_API_APP_SECRET=xxxxxxxx

# round start (gameRound empty)
python record_api.py start --table-id table1 --game-id p2w001

# round end (--game-round required)
python record_api.py end --table-id table1 --game-id p2w001 --game-round gc001

# start -> wait 30s -> end
python record_api.py auto --table-id table1 --game-id p2w001 --wait 30

# print the signature and body only (no request)
python record_api.py sign --table-id table1 --game-id p2w001
```

The default target is the hosted service `https://record.pp-cdn.org`
(override with `--base-url` / `RECORD_API_BASE_URL`). For a self-hosted
`ppmmxDocker` record node, point at your own node:

```bash
python record_api.py start --base-url http://<record-node>:8080 \
  --table-id table1 --game-id p2w001
```

> Production `record.pp-cdn.org` reverse-proxies only `POST /api/record/split`.
> A self-hosted node is reached on its admin port (`adminAddress` in
> `conf/record.yml`, default `:8080`).

## 2. Parameters

| Option | Required | Description |
| --- | --- | --- |
| `--app-id` | yes | appId created in the console; the appSecret used for signing must belong to this appId |
| `--app-secret` | yes | that appId's own appSecret (not a deployment-wide shared secret) |
| `--table-id` | yes | table/camera id, `^[A-Za-z0-9_-]{1,128}$`; together with appId forms the `{appId}/{tableId}-{view}` stream prefix |
| `--game-id` | yes | round/business id; together with `--app-env` decides the round owner |
| `--game-round` | for end | round id; empty = round start, non-empty = round end |
| `--app-env` | no | object-name prefix (e.g. `test`); also part of owner identity |
| `--auth-mode` | no | `simple` (default) or `advance` |
| `--base-url` | no | target URL, default `https://record.pp-cdn.org` |

## 3. Signing

The `Authorization` header is computed with the calling app's own appSecret.

**simple mode (default)**, 32 lowercase hex md5:

```python
base = appSecret + time + appId + tableId
if gameRound:            # empty gameRound (round start) is not appended at all
    base += gameRound
base += gameId
token = md5(base).hexdigest()
```

`time` is the **signing instant** as a unix-seconds string and must be within
+/-30 seconds of the server clock (the server uses it for replay protection).

**advance mode** (must be enabled for your integration on the deployment side):

```
Authorization: HMAC-SHA256 <hex(hmac_sha256(appSecret, canonical_json))>
X-Split-Rec-Nonce: <random string, 16-128 chars>
```

`canonical_json` uses the fixed field order `time,appId,tableId,gameRound,gameId,nonce`.
The `time` window is +/-5 minutes; real replay protection is the nonce, which
must never be reused.

## 4. Responses and status codes

Unified envelope `{"code":200,"msg":"OK","data":null}`:

| HTTP | code | Meaning |
| --- | --- | --- |
| 200 | 200 | Success (including ending a round that was never started - a silent no-op) |
| 400 | 400 | Malformed JSON / missing required field / invalid characters |
| 401 | 401 | Bad signature; `time` outside the window; advance-mode nonce reuse |
| 429 | 429 | Rate limited (>500 req/s per IP) |
| 500 | 500 | Business failure, e.g. the `(appId, tableId)` is already held by another gameId, or nothing new to finalize on end |
| 500 | **50001** | This appId/tableId has **no view online right now** (branch on `code`, not on the HTTP status alone) |

## 5. Troubleshooting

- **`code=50001` (`stream ... is not online`)**: the app is valid but nothing is
  publishing right now. The stream must be named `{appId}/{tableId}-{view}` and
  be online; retry once it is publishing.
- **Ending too soon fails**: ending right after starting, with no new data in
  the current segment (about a 1s segment), fails with "nothing to finalize".
  Real rounds are far longer; only scripts hit this.
- **Owner conflict**: one `(appId, tableId)` can be held by only one owner
  (`appEnv`+`gameId`) at a time; another owner's round-start is **rejected with
  HTTP 500 (not 409)**.
- **appSecret propagation delay**: a node syncs the eligible app list every 30
  seconds; a new app or rotated secret takes up to 30s to take effect.
- **Upload is asynchronous and best-effort**: a 200 from round-end does not mean
  the object-storage upload finished, or will succeed.

## 6. Self tests

### 6.1 Contract test (against a real node)

```bash
# offline signature cases always run; live cases need credentials
set PPCDN_TEST_APP_ID=app_xxx
set PPCDN_TEST_APP_SECRET=xxxxxxxx
python -m unittest test_record_api -v
```

### 6.2 Local end-to-end (a real recording file + net-storage upload + playback URL)

Requires a ppmmx executable (build with `go build -o mmx.exe .` in the ppmmx
repo) and ffmpeg:

```bash
set MMX_BIN=D:\path\to\mmx.exe
set FFMPEG_BIN=D:\path\to\ffmpeg.exe
python local_e2e.py
```

The script:

1. starts a fake ppcenter (WS registration + appSecret delivery);
2. starts a real mmx record node wired to a **local S3-compatible object store**
   (a stand-in for OVH net-storage, via the `MINIO_*` settings);
3. has ffmpeg publish `{appId}/{tableId}-{view}` over RTMP;
4. calls round-start, waits `--media-seconds`, calls round-end;
5. waits for the recorder to faststart-remux and upload the round, then prints
   the object's **playback URL** and fetches it back over HTTP to prove it plays.

The upload mirrors the production uploader exactly: the on-disk fragmented MP4
is remuxed to a conventional single-`moov` faststart MP4 (plays in a plain
`<video>` tag) and PUT to `<bucket>/<key>`.

Useful options:

- `--app-id`, `--table-id`, `--view`, `--game-id`, `--game-round` — the stream to record.
- `--media-seconds` (default 15) — how long the round stays open.
- `--work-dir <dir>` — run here and keep the produced files (recommended).
- `--no-upload` — skip the object store and only verify the on-disk file.
- `--keep` — keep the temporary work dir when `--work-dir` is not given.

> On production, the same upload lands at
> `https://s3.sgp.io.cloud.ovh.net/ppcdn-net-storage/<objectKey>` (the
> `playbackBaseUrl` from ppcenter's prod config); with `appEnv=test` the object
> key gets a `test/` prefix. Which URL is served (and whether it is signed)
> depends on the deployment's `S3_HTTPS_DOMAIN`/`playbackBaseUrl`.
