#!/usr/bin/env bash
# ─── Build dvpnd for macOS (amd64 + arm64) on the GCP host, never on the laptop ───
# Cross-compiles with CGO off from a `git archive` of ~/work/sentinel-official-cf4c (never push
# that tree), devnet ldflags (same identity as #31/#32), and copies the binaries back.
# Usage (laptop): bash scripts/e2e/mac/build-dvpnd.sh <commit> <tag>
#   e.g.          bash scripts/e2e/mac/build-dvpnd.sh 6ef55a8 cf4c372-ddv6
set -euo pipefail
COMMIT=${1:?commit}; TAG=${2:?tag}
H=${BUILD_HOST:-ddv-mac-host-dv}
GO_VERSION=${GO_VERSION:-1.27.1}
SRC=${DVPND_TREE:-$HOME/work/sentinel-official-cf4c}
DEST=${DVPND_OUT:-$HOME/Desktop/devnet-dvpn-dvpnd-devnet/build}
FULL=$(git -C "$SRC" rev-parse "$COMMIT")
NETWORK=devnet
PROGRAM_ID=J52dyXW3a6mkatvrQct3fo6dA9vqUtcsdBt5gGqrTBXs
MINT=Hen2LVP6KooGaXEvdSyCHWghsEY4gLLn7wix8z6zHFSa

# This laptop has core.autocrlf=true system-wide and `git archive` applies it: templates would
# arrive CRLF and go:embed bakes them into dvpnd (OpenVPN/WireGuard configs with \r). Force LF.
git -c core.autocrlf=false -c core.eol=lf -C "$SRC" archive "$FULL" sentinel-dvpnd sentinel-go-sdk sentinel-programs \
  | ssh "$H" "rm -rf ~/dvpnd-src && mkdir -p ~/dvpnd-src && tar -xf - -C ~/dvpnd-src"
ssh "$H" bash -s -- "$GO_VERSION" "$FULL" "$TAG" "$NETWORK" "$PROGRAM_ID" "$MINT" <<'REMOTE'
set -euo pipefail
GO_VERSION=$1; FULL=$2; TAG=$3; NETWORK=$4; PROGRAM_ID=$5; MINT=$6
if ! ~/go-sdk/bin/go version 2>/dev/null | grep -q "go$GO_VERSION "; then
  rm -rf ~/go-sdk ~/go-dl.tgz
  curl -fsSL -o ~/go-dl.tgz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  mkdir -p ~/go-sdk && tar -xzf ~/go-dl.tgz -C ~/go-sdk --strip-components=1 && rm -f ~/go-dl.tgz
fi
export PATH="$HOME/go-sdk/bin:$PATH" CGO_ENABLED=0 GOFLAGS=-mod=readonly
SDK=github.com/sentinel-official/sentinel-go-sdk/v3
LD="-s -w -X $SDK/version.Commit=$FULL -X $SDK/version.Tag=$TAG -X $SDK/version.Network=$NETWORK -X $SDK/version.ProgramID=$PROGRAM_ID -X $SDK/version.Mint=$MINT"
CR=$(printf '\r')
if grep -rlI "$CR" ~/dvpnd-src/sentinel-go-sdk --include='*.tmpl' | grep -q .; then echo 'CRLF templates in the source tree: refusing to build' >&2; exit 1; fi
cd ~/dvpnd-src/sentinel-dvpnd
mkdir -p ~/dvpnd-out
for a in amd64 arm64; do
  # -p 4: the host also runs the macOS guest
  GOOS=darwin GOARCH=$a nice go build -p 4 -trimpath -ldflags "$LD" -o ~/dvpnd-out/dvpnd-darwin-$a-$TAG ./cmd/dvpnd
  # embedded OpenVPN config must be LF (positive control: the line itself is there)
  b=~/dvpnd-out/dvpnd-darwin-$a-$TAG
  [ "$(grep -ac 'persist-tun' "$b")" -gt 0 ] && [ "$(grep -ac "persist-tun$CR" "$b")" = 0 ] || { echo "$b embeds CRLF configs" >&2; exit 1; }
done
cd ~/dvpnd-out && sha256sum dvpnd-darwin-*-"$TAG"
REMOTE
mkdir -p "$DEST"
for a in amd64 arm64; do scp -q "$H:dvpnd-out/dvpnd-darwin-$a-$TAG" "$DEST/"; done
( cd "$DEST" && sha256sum dvpnd-darwin-*-"$TAG" )
