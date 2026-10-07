#!/usr/bin/env bash
# Cross-compiles ppmmx's Linux release binaries (amd64 + arm64) from a
# sibling checkout of github.com/ppcdn-org/ppmmx, for the Dockerfile to COPY
# in. See docs/roadmap/ppcdn-ppmmx-license-selfhost.zh-CN.md §3.6.
#
# Usage: ./build.sh [version]
#   version - optional, e.g. v1.19.1 (default: read from ppmmx's
#             internal/core/VERSION file, fallback v0.0.0)
#
# Env:
#   PPMMX_SRC - path to the ppmmx checkout (default: ../ppmmx, i.e. a sibling
#               of this ppmmxDocker checkout - matches how both repos are
#               laid out side by side in this project's workspace)
#
# Once ppmmx publishes GitHub Releases with prebuilt Linux binaries, the
# Dockerfile can switch to downloading those directly instead of requiring a
# local source checkout + this script - see README.md's "构建来源" note.
set -euo pipefail

cd "$(dirname "$0")"

PPMMX_SRC="${PPMMX_SRC:-../ppmmx}"
if [ ! -f "$PPMMX_SRC/go.mod" ]; then
  echo "ERROR: ppmmx source not found at '$PPMMX_SRC' (set PPMMX_SRC to override)" >&2
  exit 1
fi

VERSION="${1:-}"
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
