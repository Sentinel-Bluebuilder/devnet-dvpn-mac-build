#!/usr/bin/env bash
# ─── Build the patched Xray for macOS (amd64 + arm64) on the GCP host, never on the laptop ───
# Upstream Xray 26.3.27 cannot look up processes on macOS ("process lookup is not supported"),
# so split tunnelling by app cannot match an app there. docs/patches/xray-0001-darwin-find-process.patch
# adds the lookup (sysctl pcblist_n + kern.procargs2). Same flags as the official release build
# (CGO off, -trimpath, -s -w, empty build id); core.build names the patch level.
# Usage (laptop): bash scripts/e2e/mac/build-xray.sh [build-tag]   (default ddv1)
set -euo pipefail
BUILD=${1:-ddv1}
H=${BUILD_HOST:-ddv-mac-host-dv}
VERSION=v26.3.27
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
DEST=${DVPND_OUT:-$HOME/Desktop/devnet-dvpn-dvpnd-devnet/build}
PATCH="$ROOT/docs/patches/xray-0001-darwin-find-process.patch"
CR=$(printf '\r')
if grep -q "$CR" "$PATCH"; then echo 'patch has CRLF line ends: refusing' >&2; exit 1; fi

ssh "$H" "rm -rf ~/xray-build && git clone -q -c advice.detachedHead=false --depth 1 --branch $VERSION https://github.com/XTLS/Xray-core ~/xray-build"
ssh "$H" "cd ~/xray-build && git apply --whitespace=nowarn -" < "$PATCH"
ssh "$H" bash -s -- "$BUILD" <<'REMOTE'
set -euo pipefail
BUILD=$1
export PATH="$HOME/go-sdk/bin:$PATH" CGO_ENABLED=0
cd ~/xray-build
GOOS=darwin GOARCH=amd64 nice go test -count=1 -c -o /dev/null ./common/net/
mkdir -p ~/dvpnd-out
for a in amd64 arm64; do
  GOOS=darwin GOARCH=$a nice go build -p 4 -trimpath -buildvcs=false \
    -ldflags "-X github.com/xtls/xray-core/core.build=$BUILD -s -w -buildid=" \
    -o ~/dvpnd-out/xray-darwin-$a-26.3.27-$BUILD ./main
done
cd ~/dvpnd-out && sha256sum xray-darwin-*-26.3.27-$BUILD
REMOTE
mkdir -p "$DEST"
for a in amd64 arm64; do scp -q "$H:dvpnd-out/xray-darwin-$a-26.3.27-$BUILD" "$DEST/"; done
(cd "$DEST" && sha256sum xray-darwin-*-26.3.27-"$BUILD")
