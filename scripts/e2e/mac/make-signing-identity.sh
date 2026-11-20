#!/bin/bash
# ─── One-time: create the Mac build's STABLE self-signed code-signing identity (DIR 11-13, Mac rc.2) ───
# Runs IN THE BUILD GUEST, once. Makes ~/ddv-signing/ with:
#   ddv-signing.keychain-db   a build-only keychain holding the identity (password in keychain.pass, 0600)
#   identity.p12 + p12.pass   the exportable backup (copy BOTH to the laptop: ~/memory/mac-signing/, never a repo)
#   identity.sha1             the SHA-1 codesign signs with (DVPN_MAC_SIGN_IDENTITY)
#   env.sh                    `source` it before `npm run release:mac`
# Re-running refuses when the identity exists: a NEW certificate changes every user's Keychain grant once more.
# Restore on another build Mac: copy the folder back and run with --import.
set -euo pipefail
D=$HOME/ddv-signing
KC=$D/ddv-signing.keychain-db
NAME='Devnet dVPN Code Signing'
mode=${1:-create}

new_keychain() {
  [ -f "$D/keychain.pass" ] || { umask 077; openssl rand -hex 24 > "$D/keychain.pass"; }
  [ -f "$KC" ] || security create-keychain -p "$(cat "$D/keychain.pass")" "$KC"
  security unlock-keychain -p "$(cat "$D/keychain.pass")" "$KC"
  security set-keychain-settings -t 3600 "$KC"
  # codesign may use the key without a prompt (no GUI on a build run)
  security import "$D/identity.p12" -k "$KC" -P "$(cat "$D/p12.pass")" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$D/keychain.pass")" "$KC" >/dev/null
  # not on the user's search list: the build hook adds it only while it signs (codesign needs that for an untrusted identity)
}

if [ "$mode" = create ]; then
  if [ -f "$D/identity.p12" ]; then echo "identity exists in $D (refusing to replace it: every user would be asked again)"; exit 1; fi
  mkdir -p "$D"; chmod 700 "$D"; umask 077
  cat > "$D/cert.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
O = Devnet dVPN contributors
[ ext ]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes -config "$D/cert.cnf" -keyout "$D/key.pem" -out "$D/cert.pem" 2>/dev/null
  openssl rand -hex 24 > "$D/p12.pass"
  openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -name "$NAME" -out "$D/identity.p12" -passout "file:$D/p12.pass" 2>/dev/null
  rm -f "$D/key.pem"
elif [ "$mode" != --import ]; then echo "usage: $0 [--import]"; exit 2; fi

new_keychain
SHA=$(security find-identity -p codesigning "$KC" | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}')
[ -n "$SHA" ] || { echo "identity not found in $KC"; security find-identity -p codesigning "$KC"; exit 1; }
echo "$SHA" > "$D/identity.sha1"
cat > "$D/env.sh" <<EOF
export DVPN_MAC_SIGN_IDENTITY=$SHA
export DVPN_MAC_SIGN_KEYCHAIN=$KC
export DVPN_MAC_SIGN_KEYCHAIN_PASS_FILE=$D/keychain.pass
EOF
echo "identity $SHA ($NAME) in $KC"
echo "cert sha256: $(openssl x509 -in "$D/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
