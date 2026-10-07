#!/usr/bin/env bash
# Cross-compiles ppmmx's Linux release binaries (amd64 + arm64) from a
# sibling checkout of github.com/ppcdn-org/ppmmx, for the Dockerfile to COPY
# in. See docs/roadmap/ppcdn-ppmmx-license-selfhost.zh-CN.md §3.6.
#
# Usage: ./build.sh [version] [--release]
#   version   - optional, e.g. v1.19.1 (default: read from ppmmx's
#               internal/core/VERSION file, fallback v0.0.0)
#   --release - after building, copy dist/mmx-linux-amd64 to
#               bin/mmx-linux-amd64 and print the git commands to publish it.
#               bin/ (unlike dist/) is committed to this repo: ppmmx's own
#               source repo is private, so an end customer's machine has no
#               way to clone+compile it themselves - this repo's own clone
#               has to carry a ready-to-run binary. Run this flag whenever
#               ppmmx gets a change that should ship to self-hosted
#               customers (deploy.sh/deploy.ps1 and the Dockerfile both read
#               bin/, not dist/).
#
# Env:
#   PPMMX_SRC - path to the ppmmx checkout (default: ../ppmmx, i.e. a sibling
#               of this ppmmxDocker checkout - matches how both repos are
#               laid out side by side in this project's workspace)
#
# Once ppmmx publishes GitHub Releases with prebuilt Linux binaries, both
# this script and the Dockerfile can switch to downloading those directly
# instead of requiring a local source checkout - see README.md's "构建来源"
# note.
set -euo pipefail

cd "$(dirname "$0")"

RELEASE=0
VERSION=""
for arg in "$@"; do
  case "$arg" in
    --release) RELEASE=1 ;;
    *) VERSION="$arg" ;;
  esac
done

PPMMX_SRC="${PPMMX_SRC:-../ppmmx}"
if [ ! -f "$PPMMX_SRC/go.mod" ]; then
  echo "ERROR: ppmmx source not found at '$PPMMX_SRC' (set PPMMX_SRC to override)" >&2
  exit 1
fi

if [ -z "$VERSION" ]; then
  VERSION="$(cat "$PPMMX_SRC/internal/core/VERSION" 2>/dev/null || true)"
  VERSION="${VERSION:-v0.0.0}"
fi

echo "[1/3] Version: $VERSION"
mkdir -p dist

# linux/arm64 is intentionally not built here: ppmmx's
# internal/staticsources/rpicamera/camera_linux_arm64.go go:embeds a
# mtxrpicam_64/ directory that this checkout doesn't have (unmaintained
# upstream MediaMTX Raspberry Pi camera plumbing - unrelated to ppmmx's own
# cloud-node use case, see internal/staticsources/rpicamera/
# mtxrpicamdownloader/), so GOARCH=arm64 fails to compile as of this script.
# amd64 covers the overwhelming majority of cloud VPS targets; fixing arm64
# is tracked separately and out of scope for the license-selfhost feature.
ARCHES="amd64"

echo "[2/3] Building linux/$ARCHES ..."
(
  cd "$PPMMX_SRC"
  for arch in $ARCHES; do
    echo "      -> linux/$arch"
    CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
      go build -trimpath -ldflags="-s -w" -o "$OLDPWD/dist/mmx-linux-$arch" .
  done
)

echo "[3/3] Done:"
for arch in $ARCHES; do
  size=$(stat -c%s "dist/mmx-linux-$arch" 2>/dev/null || stat -f%z "dist/mmx-linux-$arch")
  echo "      dist/mmx-linux-$arch (version=$VERSION, size=${size} bytes)"
done

if [ "$RELEASE" = "1" ]; then
  echo "[release] copying dist/mmx-linux-amd64 -> bin/mmx-linux-amd64"
  mkdir -p bin
  cp dist/mmx-linux-amd64 bin/mmx-linux-amd64
  chmod 755 bin/mmx-linux-amd64
  echo "[release] done. Commit it so customer clones carry this version:"
  echo "    git add bin/mmx-linux-amd64"
  echo "    git commit -m \"release: ppmmx $VERSION\""
  echo "    git push"
fi
