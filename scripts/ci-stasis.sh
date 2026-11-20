#!/usr/bin/env bash
# ─── Typecheck + unit tests on stasis-ops (keeps the laptop's RAM for the AI sessions) ───
#   bash scripts/ci-stasis.sh            → HEAD of local main
# Sends an incremental git bundle, checks it out in ~/fleet/mac/repo, runs `npm ci` only when the
# lockfile changed, then typecheck + vitest in node:22 with --cpus 2 as a normal user (uid 1000).
# docs/patches/ never leaves the laptop through here: the bundle carries history, so the clone is
# kept on stasis-ops only (owner allows it there; never pushed anywhere).
set -euo pipefail
cd "$(dirname "$0")/.."
HOST=${CI_HOST:-stasis-ops}
REMOTE_DIR=fleet/mac
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
base=$(ssh "$HOST" "git -C ~/$REMOTE_DIR/repo rev-parse HEAD 2>/dev/null || true")
if [ -n "$base" ] && git cat-file -e "$base" 2>/dev/null; then
  [ "$base" = "$(git rev-parse HEAD)" ] || git bundle create "$tmp/inc.bundle" "$base..main" >/dev/null 2>&1
else
  git bundle create "$tmp/inc.bundle" main >/dev/null 2>&1
fi
ssh "$HOST" "mkdir -p ~/$REMOTE_DIR"
[ -f "$tmp/inc.bundle" ] && scp -q "$tmp/inc.bundle" "$HOST:$REMOTE_DIR/inc.bundle"
head=$(git rev-parse HEAD)
ssh "$HOST" "bash -s" <<EOF
set -euo pipefail
cd ~/$REMOTE_DIR
if [ ! -d repo/.git ]; then git clone -q inc.bundle repo; fi
cd repo
[ -f ../inc.bundle ] && git fetch -q ../inc.bundle main:refs/remotes/b/main && rm -f ../inc.bundle
git checkout -q --detach $head
lock=\$(sha256sum package-lock.json | cut -c1-16)
docker() { if command -v docker >/dev/null && docker info >/dev/null 2>&1; then command docker "\$@"; else sudo docker "\$@"; fi; }
run() { docker run --rm --cpus 2 -u 1000:1000 -e HOME=/tmp -e npm_config_cache=/w/.npm-cache -v "\$PWD":/w -w /w node:22 bash -lc "\$1"; }
if [ "\$(cat ../lock.sha 2>/dev/null)" != "\$lock" ] || [ ! -d node_modules ]; then
  run 'npm ci --ignore-scripts --no-audit --no-fund >/dev/null' && echo "\$lock" > ../lock.sha
fi
echo "ci $head: typecheck"; run 'npm run -s typecheck' && echo "typecheck OK"
echo "ci $head: vitest"; run 'npx vitest run 2>&1 | grep -E "Test Files|Tests |FAIL" | head -20'
EOF
