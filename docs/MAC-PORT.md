# macOS port — what changed from the Linux app (#32)

Shared code (`src/core`, services, renderer, CLI catalogue) is the same as #31/#32. Only the
platform layer below differs. Windows column: see `docs/LINUX-PORT.md`.

| Linux (#32) | macOS (#33) | Files |
|---|---|---|
| unix socket `/var/lib/dvpnd/client/daemon.sock`, group `dvpn` + setfacl ACL | `/var/db/dvpnd/client/daemon.sock` (no spaces), 0660 group `dvpn` (`dseditgroup`) + `chmod +a "user:<u> allow read,write"` for the user who ran setup | `core/daemon/client.ts`, `main/daemon/manager.ts` |
| systemd `dvpnd-client.service` | LaunchDaemon `/Library/LaunchDaemons/network.sentinel.devnet-dvpn.dvpnd.plist` (RunAtLoad, KeepAlive, ThrottleInterval); `launchctl bootstrap / kickstart -k / bootout system` | `resources/scripts/setup-daemon.sh`, `service-ctl.sh` |
| binaries in `/usr/local/lib/devnet-dvpn` | same path, root-owned copies, `com.apple.quarantine` removed (app may sit in `~/Downloads` or be replaced on update) | `setup-daemon.sh` |
| `dvpnd init --role client` | same (darwin default is already client; passed anyway) | `main/daemon/manager.ts` |
| `pkexec` / `sudo -n` / root → `dvpn-helper` | `osascript -e 'do shell script "<helper> <step> <args>" with administrator privileges'` on a desktop (args already `SAFE_ARG`-validated, single-quote escaped), `sudo -n` over SSH, direct as root | `main/system/elevate.ts` |
| nftables `inet dvpnd` | dvpnd pf anchor + token; Restore network removes only ours, never `pfctl -F all` / `pfctl -d` | `remove-tunnels.sh` |
| `resolvectl` / `resolvconf` | `networksetup` (dvpnd default) / `none`; leftover check `scutil --dns`; flush `dscacheutil -flushcache` + `killall -HUP mDNSResponder` | `core/daemon/config.ts`, `main/system/dns-check.ts` |
| `ip -o link`, `/proc` | `ifconfig -l` (utunN owned by our processes), `ps -axo pid,comm,args` for orphans from our dirs only | `main/system/tunnels.ts` |
| apt + PPA | Homebrew as the user: `wireguard-tools wireguard-go openvpn bash`; AmneziaWG `amneziawg-go` + `amneziawg-tools`; report `/usr/local/var/devnet-dvpn/install-deps.json` | `main/system/drivers.ts`, `install-deps.sh` |
| GNOME gsettings / KDE kioslaverc | `networksetup -getsocksfirewallproxy / -setsocksfirewallproxy / -setsocksfirewallproxystate` for every enabled network service; backup first, restore only if still ours | `main/system/proxy.ts` |
| Browser from PATH | `/Applications/{Google Chrome,Microsoft Edge,Chromium,Brave Browser}.app`, same flags | `main/system/browser.ts` |
| libsecret (`secret-tool`) | Keychain via `security add/find/delete-generic-password -s devnet-dvpn -a cli-wallet:<dir>`; the secret goes in on stdin, never argv | `cli/keystore.ts` |
| safeStorage libsecret/KWallet, `basic_text` refused | safeStorage on Keychain (always encrypted) | `main/wallet/electron-keystore.ts` |
| XDG autostart | `app.setLoginItemSettings({ openAtLogin, openAsHidden })` | `main/system/autostart.ts` |
| gnome-terminal / konsole … | Terminal.app (`open -a Terminal <rc script>`) | `main/services/cli-exec.ts` |
| `~/.config/Devnet dVPN` | `~/Library/Application Support/Devnet dVPN` | `main/runtime.ts` |
| `.deb` + AppImage | `.dmg` + `.zip`, x64 + arm64, ad-hoc signed; first-run setup creates group, LaunchDaemon, `/usr/local/bin/devnet-dvpn`; `uninstall-cleanup` reverses it | `electron-builder.yml`, `build/mac/*`, `build/cli/devnet-dvpn` |
| deps lock: Linux builds | darwin amd64 + arm64 builds of the same versions (Hysteria2 2.13.0, V2Ray 5.53.0, Xray 26.3.27), SHA-256 against each publisher's digest; dvpnd darwin built from cf4c372-ddv4 | `build/deps.lock.json`, `scripts/fetch-deps.mjs` |
| Tests on GCP VM `ddv-linux-1` | GCP host `ddv-mac-host-1` → macOS Sonoma guest (OSX-KVM): `scripts/e2e/mac/*` | `scripts/e2e/mac/*` |
