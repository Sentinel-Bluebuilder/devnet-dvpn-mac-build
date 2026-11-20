#!/bin/bash
# #31 470bac7 proof (Agent M): a plain app update over an older service shows the outdated-service banner; pressing
# "Update the VPN service" updates the service (one prompt; sudo -n on this rig) and the banner goes.
# Run after chain3.sh with APP_ONLY=1 (new app, old service). Usage: bash q-banner.sh <out dir>
set -u
O=$1; rm -rf "$O"; mkdir -p "$O"
export DVPN_KEYFILE=$HOME/ksm/ksm-wallet.json DVPN_DATA_DIR=$HOME/ksm/profile PATH=/usr/local/bin:$PATH
APPD="/Applications/Devnet dVPN.app/Contents/Resources/resources/bin/sentinel-dvpnd"
LIBD=/Library/devnet-dvpn/sentinel-dvpnd
h() { shasum -a 256 "$1" 2>/dev/null | cut -c1-16; }
{
  echo "before: app dvpnd $(h "$APPD")  service dvpnd $(h "$LIBD")  $(devnet-dvpn status 2>&1 | grep Daemon)"
} > "$O/result.txt"
DVPN_UI_SCENARIO="nav=Connect;sleep=10;shot=banner;click=text:Update the VPN service;sleep=45;nav=Connect;sleep=8;shot=after" \
  UI_TIMEOUT=200 bash ~/rc-030/scripts/e2e/mac/ui-smoke.sh dark "$O/ui" > "$O/ui-smoke.log" 2>&1
B='This app was updated, but the VPN service still runs its old version'
"$HOME/node/bin/node" -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  const shown = (name) => { const i = s.findIndex((x) => x.step === `shot=${name}`); return i < 0 ? "no-step" : (s[i].visible ?? []).some((v) => v.includes(process.argv[2])) ? "banner" : "none"; };
  const click = s.find((x) => x.step.startsWith("click=text:Update the VPN service"));
  console.log(`banner_at_start=${shown("banner")}`);
  console.log(`update_click=${click ? (click.ok ? "ok" : `failed: ${click.detail}`) : "no-step"}`);
  console.log(`banner_after_update=${shown("after")}`);
' "$O/ui/scenario.json" "$B" >> "$O/result.txt" 2>&1
{
  echo "after: app dvpnd $(h "$APPD")  service dvpnd $(h "$LIBD")  $(devnet-dvpn status 2>&1 | grep Daemon)"
  grep -E 'older copies than this app|elevated step|daemon settings apply|setup' "$DVPN_DATA_DIR/logs/app.log" | tail -5 | cut -c1-200
} >> "$O/result.txt"
v=PASS
grep -q 'banner_at_start=banner' "$O/result.txt" || v=FAIL
grep -q 'update_click=ok' "$O/result.txt" || v=FAIL
grep -q 'banner_after_update=none' "$O/result.txt" || v=FAIL
[ "$(h "$APPD")" = "$(h "$LIBD")" ] || v=FAIL
echo "VERDICT $v" >> "$O/result.txt"
