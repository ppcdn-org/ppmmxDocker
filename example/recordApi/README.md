# On-demand recording API example (`/api/record/split`)

"On-demand recording" (a.k.a. round recording / split-rec) records one
business activity with a clear start and end (a game, an auction, a class).
The business backend calls `round-start` when the activity begins and
`round-end` when it ends; the node cuts exactly that interval into one
playable mp4, **keeps it on the node**, and returns its **playback URL** in the
`round-end` response.

> **The API host must be your own standalone/record node.** The recording is
> made on the node that receives the stream, so call
> `POST {your-node}/api/record/split` where `{your-node}` is that node's
> `MMX_WEBRTC_BASE_URL` (e.g. `https://mmx-xxxx.rent.pp-cdn.org` or
> `http://<node-public-ip>:8888`). **Do not use `record.pp-cdn.org`** - that is
> PPCDN's hosted recorder; it cannot see streams on your machine, and the
> client in this directory refuses it.

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
export RECORD_API_BASE_URL=https://mmx-xxxx.rent.pp-cdn.org   # YOUR node, not record.pp-cdn.org
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

There is no default target: pass `--base-url` or set `RECORD_API_BASE_URL` to
your own node, otherwise the client exits with an error.

```bash
python record_api.py auto --base-url http://<your-node-ip>:8888 \
  --table-id table1 --game-id p2w001 --wait 30
# ...
#          -> success
#          -> playback [frontView]: http://<your-node-ip>:8888/api/record/play/app_xxx/splitrec_....mp4?exp=...&sig=...
```

> The node serves the API (and the playback URLs) on its WebRTC HTTP port
> `8888`, or on the https hostname `deploy.sh` set up for it - the same address
> as `MMX_WEBRTC_BASE_URL` in its `.env`. That port must be reachable from your
> backend and from whoever plays the recording. The admin port `:8080` also
> proxies `POST /api/record/split`, but is meant for operators only.

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
| `--base-url` | yes | **your own** standalone/record node URL (its `MMX_WEBRTC_BASE_URL`); `record.pp-cdn.org` is rejected |

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
| 200 | 200 | Success (including ending a round that was never started - a silent no-op). A successful **round-end** carries `data.playbackUrls` (see 4.1) |
| 400 | 400 | Malformed JSON / missing required field / invalid characters |
| 401 | 401 | Bad signature; `time` outside the window; advance-mode nonce reuse |
| 429 | 429 | Rate limited (>500 req/s per IP) |
| 500 | 500 | Business failure, e.g. the `(appId, tableId)` is already held by another gameId, or nothing new to finalize on end |
| 500 | **50001** | This appId/tableId has **no view online right now** (branch on `code`, not on the HTTP status alone) |

### 4.1 Playback URLs in the round-end response

On a self-hosted node (`recordLocalPlayback: true`, the default in
`conf/standalone.yml` / `conf/record.yml`) the finished file stays on the node
and round-end returns where to play it:

```json
{"code":200,"msg":"OK","data":{"playbackUrls":[
  {"view":"frontView",
   "url":"https://mmx-xxxx.rent.pp-cdn.org/api/record/play/app_xxx/splitrec_9f2c....mp4",
   "fileName":"table1-frontView-gc001.mp4","sizeBytes":18874368,"durationSeconds":45}
]}}
```

- One entry per online view of the table; a view whose file is unavailable is
  left out (possibly an empty array). round-start still returns `data: null`.
- `url` is served by the node itself: **no authentication, no expiry**. It
  works in `<video src>` and supports Range requests, for as long as the file
  is on the node (`data/recordings/`, docker volume `mmx-data`). The record id
  in it is random and unguessable, but don't hand the link to people who
  shouldn't see the recording.
- **Kept for 10 days, then deleted automatically** by mmx's built-in recording
  cleaner (`recordDeleteAfter: 240h` in the node config, measured from the
  file's last modification time); afterwards the same URL returns 404. Raise
  `recordDeleteAfter` to keep files longer, and size the disk for
  "recorded GB per day x retention days".
- If `S3_*` is set in `.env`, the file is additionally uploaded (see
  "Upload is asynchronous" below).

## 5. Troubleshooting

- **`code=50001` (`stream ... is not online`)**: nothing is publishing to
  *this node* right now. The stream must be named `{appId}/{tableId}-{view}`,
  be online **on the node you are calling**, and the call must go to your own
  node (not `record.pp-cdn.org`); retry once it is publishing.
- **`playbackUrls` missing or the link does not open**: check that
  `recordLocalPlayback: true` is in the node's config, that
  `MMX_WEBRTC_BASE_URL` is an address your player can reach (port `8888` open),
  and that the file has not been cleaned up (older than `recordDeleteAfter`).
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

> That script exercises the object-storage upload path. On a hosted record node,
> the same upload lands at
> `https://s3.sgp.io.cloud.ovh.net/ppcdn-net-storage/<objectKey>` (the
> `playbackBaseUrl` from ppcenter's prod config); with `appEnv=test` the object
> key gets a `test/` prefix. Which URL is served (and whether it is signed)
> depends on the deployment's `S3_HTTPS_DOMAIN`/`playbackBaseUrl`.
