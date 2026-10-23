#!/usr/bin/env bash
# Cross-compiles ppmmx's Linux release binaries from a sibling checkout of
# github.com/ppcdn-org/ppmmx and, with --release, publishes the newest one as
# the GitHub Release the Dockerfile downloads. See
# docs/roadmap/ppcdn-ppmmx-license-selfhost.zh-CN.md §3.6.
#
# Usage: ./build.sh [version] [--release]
#   version   - optional, e.g. v1.19.1 (default: read from ppmmx's
#               internal/core/VERSION file, fallback v0.0.0)
#   --release - after building, publish dist/mmx-linux-amd64 (+ its .sha256) as
#               the GitHub Release "<version>" of this repo, marked latest, and
#               delete every older release and its tag: only the newest version
#               is provided. Binaries are never committed to git - ppmmx's own
#               source repo is private, so end customers can't compile it, and
#               the public Release is how the Dockerfile gets a ready-to-run
#               binary (it downloads releases/latest/download/mmx-linux-amd64).
#               Needs the GitHub CLI (`gh`) logged in with write access.
#
# Env:
#   PPMMX_SRC     - path to the ppmmx checkout (default: ../ppmmx, i.e. a
#                   sibling of this ppmmxDocker checkout - matches how both
#                   repos are laid out side by side in this project's workspace)
#   RELEASE_REPO  - GitHub repo that hosts the Release (default:
#                   ppcdn-org/ppmmxDocker)
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
  REPO="${RELEASE_REPO:-ppcdn-org/ppmmxDocker}"
  command -v gh >/dev/null 2>&1 || { echo "ERROR: --release needs the GitHub CLI (gh)" >&2; exit 1; }

  ( cd dist && sha256sum mmx-linux-amd64 > mmx-linux-amd64.sha256 )
  echo "[release] sha256: $(cut -d' ' -f1 dist/mmx-linux-amd64.sha256)"

  ASSETS=(dist/mmx-linux-amd64 dist/mmx-linux-amd64.sha256)
  if gh release view "$VERSION" -R "$REPO" >/dev/null 2>&1; then
    echo "[release] $VERSION already exists in $REPO, replacing its assets"
    gh release upload "$VERSION" "${ASSETS[@]}" -R "$REPO" --clobber
    gh release edit "$VERSION" -R "$REPO" --latest
  else
    echo "[release] creating $REPO release $VERSION"
    gh release create "$VERSION" "${ASSETS[@]}" -R "$REPO" \
      --title "ppmmx $VERSION" --latest \
      --notes "ppmmx $VERSION linux/amd64 build. The Dockerfile downloads this automatically; no manual download is needed."
  fi

  # Only the newest version is provided: drop every other release and its tag.
  for old in $(gh release list -R "$REPO" --limit 200 --json tagName -q '.[].tagName'); do
    if [ "$old" != "$VERSION" ]; then
      echo "[release] deleting old release $old"
      gh release delete "$old" -R "$REPO" --cleanup-tag --yes
    fi
  done
  echo "[release] done: https://github.com/$REPO/releases/latest/download/mmx-linux-amd64"
fi
