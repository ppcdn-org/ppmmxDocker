#!/usr/bin/env bash
# One-click deploy script for a self-hosted ppmmx node - run this yourself on
# the Linux box you want the node to live on. Works on Ubuntu, Debian, and
# CentOS/RHEL-family distros (anything get.docker.com supports).
#
# Usage:
#   ./deploy.sh --license-code lic_xxx [options]
#
# Required:
#   --license-code <code>   From the console's "ppmmx 节点" tab, shown once
#                            you create a node (always re-viewable there too).
#                            This is the ONLY credential you need: nodeSecret
#                            and the node's type (standalone/origin/edge/
#                            record) were already decided when you created
#                            the node in console, so this script resolves
#                            them from ppcenter automatically - see "[1/6]"
#                            below.
#
# Optional:
#   --role <role>           standalone | origin | edge | record - normally
#                            auto-resolved from --license-code (see [1/6]);
#                            pass this to skip that lookup and force a role.
#   --control-url <url>     ppcenter WS control-plane address.
#                            Default: wss://api.pp-cdn.org/ws/mmx
#   --region <text>         Free-text label shown in ppcenter. Default: self-hosted
#   --capacity <n>          Max concurrent publish+play channels. Default: 100
#   --webrtc-host <ip>      This host's public IP/domain, so viewers and
#                            publishers can reach it. Default: auto-detected.
#   --webrtc-port <port>    Host port for WebRTC/WHIP/WHEP. Default: 8888
#   --udp-port <port>       Host port for WebRTC ICE (UDP). Default: 8188
#   --admin-port <port>     Host port for the admin UI. Default: 8080
#   --api-port <port>       Host port for the internal control API. Default: 9996
#   --srt-port <port>       Host port for SRT ingest (UDP). Default: 7890
#   -h, --help              Show this help and exit.
#
# You can run this script either from inside an existing ppmmxDocker clone,
# or completely standalone (e.g. `curl -fsSL .../deploy.sh | bash -s -- \
# --license-code ...`) - if docker-compose.yml isn't found in the current
# directory, it clones the repo into ./ppmmxDocker first.
#
# What this does: resolves your node's role from ppcenter, installs Docker if
# missing (via get.docker.com), writes .env with your credentials, and runs
# `docker compose up -d --build`. It does NOT touch your firewall/cloud
# security group - see the reminder this script prints at the end for which
# ports need to be reachable.
set -euo pipefail

REPO_URL="https://github.com/ppcdn-org/ppmmxDocker.git"

MMX_ROLE=""
MMX_CONTROL_URL="wss://api.pp-cdn.org/ws/mmx"
MMX_NODE_REGION="self-hosted"
MMX_NODE_CAPACITY="100"
MMX_WEBRTC_HOST=""
MMX_WEBRTC_PORT="8888"
MMX_WEBRTC_UDP_PORT="8188"
MMX_ADMIN_PORT="8080"
MMX_API_PORT="9996"
MMX_SRT_PORT="7890"
LICENSE_CODE=""

usage() { sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --license-code) LICENSE_CODE="${2:-}"; shift 2 ;;
    --role) MMX_ROLE="${2:-}"; shift 2 ;;
    --control-url) MMX_CONTROL_URL="${2:-}"; shift 2 ;;
    --region) MMX_NODE_REGION="${2:-}"; shift 2 ;;
    --capacity) MMX_NODE_CAPACITY="${2:-}"; shift 2 ;;
    --webrtc-host) MMX_WEBRTC_HOST="${2:-}"; shift 2 ;;
    --webrtc-port) MMX_WEBRTC_PORT="${2:-}"; shift 2 ;;
    --udp-port) MMX_WEBRTC_UDP_PORT="${2:-}"; shift 2 ;;
    --admin-port) MMX_ADMIN_PORT="${2:-}"; shift 2 ;;
    --api-port) MMX_API_PORT="${2:-}"; shift 2 ;;
    --srt-port) MMX_SRT_PORT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$LICENSE_CODE" ]; then
  echo "ERROR: --license-code is required" >&2
  usage
  exit 1
fi
case "$LICENSE_CODE" in
  lic_*) ;;
  *) echo "WARNING: --license-code doesn't look like 'lic_...' - double check you copied the right value from console" >&2 ;;
esac
if [ -n "$MMX_ROLE" ]; then
  case "$MMX_ROLE" in
    standalone|origin|edge|record) ;;
    *) echo "ERROR: --role must be one of standalone/origin/edge/record, got '$MMX_ROLE'" >&2; exit 1 ;;
  esac
fi

# Derives the REST API base (https://host) from the WS control URL
# (wss://host/ws/mmx) so the bootstrap lookup below always targets the same
# ppcenter --control-url points at, without a separate flag to keep in sync.
api_base_from_control_url() {
  u="${1%/ws/mmx}"
  case "$u" in
    wss://*) printf 'https://%s' "${u#wss://}" ;;
    ws://*)  printf 'http://%s' "${u#ws://}" ;;
    *)       printf '%s' "$u" ;;
  esac
}

if [ -z "$MMX_ROLE" ]; then
  echo "[1/6] Resolving node role from --license-code ..."
  API_BASE="$(api_base_from_control_url "$MMX_CONTROL_URL")"
  RESP="$(curl -sS --max-time 10 -G --data-urlencode "licenseCode=${LICENSE_CODE}" \
    -w '\n%{http_code}' "${API_BASE}/v1/ppmmx/bootstrap" 2>/dev/null || true)"
  HTTP_CODE="$(printf '%s' "$RESP" | tail -n1)"
  BODY="$(printf '%s' "$RESP" | sed '$d')"
  if [ "$HTTP_CODE" != "200" ]; then
    echo "ERROR: could not resolve this license code against ${API_BASE} (HTTP ${HTTP_CODE:-no response}): $BODY" >&2
    echo "       double check --license-code, or pass --role explicitly to skip this lookup" >&2
    exit 1
  fi
  NODE_TYPE="$(printf '%s' "$BODY" | grep -o '"nodeType"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  case "$NODE_TYPE" in
    NODE_ROLE_STANDALONE) MMX_ROLE="standalone" ;;
    NODE_ROLE_ORIGIN) MMX_ROLE="origin" ;;
    NODE_ROLE_EDGE) MMX_ROLE="edge" ;;
    NODE_ROLE_RECORDER) MMX_ROLE="record" ;;
    *) echo "ERROR: ppcenter returned an unexpected nodeType '$NODE_TYPE' for this license code" >&2; exit 1 ;;
  esac
  echo "      -> role=$MMX_ROLE"
else
  echo "[1/6] Using provided --role: $MMX_ROLE (skipping license-code lookup)"
fi

SUDO=""
if [ "$(id -u)" != "0" ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "ERROR: this script needs root or sudo to install/run Docker" >&2
    exit 1
  fi
fi

echo "[2/6] Checking Docker ..."
if ! command -v docker >/dev/null 2>&1; then
  echo "      not found, installing via get.docker.com ..."
  curl -fsSL https://get.docker.com -o /tmp/ppmmx-get-docker.sh
  $SUDO sh /tmp/ppmmx-get-docker.sh
  rm -f /tmp/ppmmx-get-docker.sh
  $SUDO systemctl enable --now docker
else
  echo "      found: $(docker --version)"
fi
if ! $SUDO docker compose version >/dev/null 2>&1; then
  echo "ERROR: 'docker compose' is unavailable even after install - is this an unusually old Docker?" >&2
  exit 1
fi

echo "[3/6] Locating ppmmxDocker ..."
if [ ! -f docker-compose.yml ]; then
  echo "      docker-compose.yml not found in $(pwd), cloning the repo ..."
  if ! command -v git >/dev/null 2>&1; then
    echo "      git not found, installing ..."
    if command -v apt-get >/dev/null 2>&1; then
      $SUDO apt-get update -qq && $SUDO apt-get install -y -qq git
    elif command -v dnf >/dev/null 2>&1; then
      $SUDO dnf install -y -q git
    elif command -v yum >/dev/null 2>&1; then
      $SUDO yum install -y -q git
    else
      echo "ERROR: no known package manager (apt-get/dnf/yum) to install git" >&2
      exit 1
    fi
  fi
  git clone --depth 1 "$REPO_URL" ppmmxDocker
  cd ppmmxDocker
else
  echo "      already in a ppmmxDocker checkout: $(pwd)"
fi

if [ -z "$MMX_WEBRTC_HOST" ]; then
  echo "[4/6] Detecting this host's public IP ..."
  MMX_WEBRTC_HOST="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  if [ -z "$MMX_WEBRTC_HOST" ]; then
    MMX_WEBRTC_HOST="$(curl -fsSL --max-time 5 https://icanhazip.com 2>/dev/null || true)"
  fi
  MMX_WEBRTC_HOST="$(printf '%s' "$MMX_WEBRTC_HOST" | tr -d '[:space:]')"
  if [ -z "$MMX_WEBRTC_HOST" ]; then
    echo "ERROR: could not auto-detect a public IP (no outbound internet?); pass --webrtc-host <ip-or-domain> explicitly" >&2
    exit 1
  fi
  echo "      -> $MMX_WEBRTC_HOST"
else
  echo "[4/6] Using provided --webrtc-host: $MMX_WEBRTC_HOST"
fi

echo "[5/6] Writing .env ..."
cat > .env <<EOF
MMX_ROLE=$MMX_ROLE
MMX_LICENSE_CODE=$LICENSE_CODE
MMX_CONTROL_URL=$MMX_CONTROL_URL
MMX_NODE_REGION=$MMX_NODE_REGION
MMX_NODE_CAPACITY=$MMX_NODE_CAPACITY
MMX_WEBRTC_BASE_URL=http://$MMX_WEBRTC_HOST:$MMX_WEBRTC_PORT
MMX_PUBLISH_URL=
MMX_WEBRTC_PORT=$MMX_WEBRTC_PORT
MMX_WEBRTC_UDP_PORT=$MMX_WEBRTC_UDP_PORT
MMX_ADMIN_PORT=$MMX_ADMIN_PORT
MMX_API_PORT=$MMX_API_PORT
MMX_SRT_PORT=$MMX_SRT_PORT
EOF
chmod 600 .env

echo "[6/6] Starting (docker compose up -d --build) ..."
$SUDO docker compose up -d --build

sleep 3
echo ""
echo "== container status =="
$SUDO docker compose ps

cat <<EOF

部署完成 / Done.

  查看日志 / follow logs:   cd $(pwd) && docker compose logs -f
  停止节点 / stop:          cd $(pwd) && docker compose down
  重新部署 / redeploy:      重新运行本脚本，或 docker compose up -d --build

确保云厂商安全组/防火墙放行（本脚本不会帮你改这些）：
  ${MMX_WEBRTC_PORT}/tcp   WHIP/WHEP (推流信令 + 播放)
  ${MMX_WEBRTC_UDP_PORT}/udp   WebRTC ICE 媒体（主要流量）
$( [ "$MMX_ROLE" = "standalone" ] || [ "$MMX_ROLE" = "origin" ] && echo "  ${MMX_SRT_PORT}/udp   SRT 推流（如果用 SRT 推流）" )
不建议公网暴露 ${MMX_ADMIN_PORT}/tcp（admin 管理界面）。

几分钟内回到控制台的 ppmmx 节点列表确认状态变为「运行中」。
EOF
