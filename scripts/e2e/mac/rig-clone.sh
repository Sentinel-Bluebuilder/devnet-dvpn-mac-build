#!/usr/bin/env bash
# ─── Second Mac rig from rig 1's disk (no macOS reinstall) ───
#   bash scripts/e2e/mac/rig-clone.sh snap     pause rig 1's guest, snapshot its host disk, resume
#   bash scripts/e2e/mac/rig-clone.sh create   disk + VM ddv-mac-host-n2 from the snapshot, boot the guest
# Then, IN the clone only: guest-personalize.sh (own wallet + device), back the new key up in
# ~/memory/ddv-vm-wallets/. Never during a running matrix on rig 1 (the pause would void a case).
set -euo pipefail
P=project-c124f7da-cd20-4a27-8d4
G=(--project "$P" --account "vm-api@$P.iam.gserviceaccount.com")
ZONE=${ZONE:-us-central1-b}
SRC=ddv-mac-host-n1; DST=ddv-mac-host-n2; SNAP=ddv-mac-n1-snap
case "${1:-}" in
  snap)
    ssh ddv-mac-host "python3 - <<'PY'
import json, socket, os
s = socket.socket(socket.AF_UNIX); s.connect(os.path.expanduser('~/qmp.sock')); f = s.makefile('rw')
f.readline(); f.write(json.dumps({'execute': 'qmp_capabilities'}) + '\n'); f.flush(); f.readline()
f.write(json.dumps({'execute': 'stop'}) + '\n'); f.flush(); print('guest paused', f.readline().strip())
PY
sync"
    t0=$(date +%s)
    gcloud compute snapshots delete "$SNAP" "${G[@]}" --quiet >/dev/null 2>&1 || true
    gcloud compute snapshots create "$SNAP" --source-disk "$SRC" --source-disk-zone us-central1-b --labels lane=mac,owner=33-mac "${G[@]}" --async >/dev/null
    # Writes may resume once the snapshot leaves CREATING (its point in time is fixed).
    until st=$(gcloud compute snapshots describe "$SNAP" "${G[@]}" --format='value(status)' 2>/dev/null) && [ -n "$st" ] && [ "$st" != CREATING ]; do sleep 5; done
    ssh ddv-mac-host "python3 - <<'PY'
import json, socket, os
s = socket.socket(socket.AF_UNIX); s.connect(os.path.expanduser('~/qmp.sock')); f = s.makefile('rw')
f.readline(); f.write(json.dumps({'execute': 'qmp_capabilities'}) + '\n'); f.flush(); f.readline()
f.write(json.dumps({'execute': 'cont'}) + '\n'); f.flush(); print('guest resumed', f.readline().strip())
PY"
    echo "snapshot $SNAP status $st; guest paused $(( $(date +%s) - t0 )) s"
    ;;
  create)
    until [ "$(gcloud compute snapshots describe "$SNAP" "${G[@]}" --format='value(status)')" = READY ]; do sleep 10; done
    gcloud compute disks create "$DST" --zone "$ZONE" --source-snapshot "$SNAP" --type pd-balanced --labels lane=mac,owner=33-mac "${G[@]}"
    gcloud compute instances create "$DST" --zone "$ZONE" --machine-type n2-standard-2 \
      --disk "name=$DST,boot=yes,auto-delete=yes" --enable-nested-virtualization \
      --provisioning-model STANDARD --no-service-account --no-scopes --labels lane=mac,owner=33-mac "${G[@]}"
    ip=$(gcloud compute instances describe "$DST" --zone "$ZONE" "${G[@]}" --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
    echo "rig 2 host IP $ip (update ~/.ssh/config ddv-mac-host-2, then: ssh ddv-mac-host-2 'bash ~/guest-boot.sh')"
    ;;
  *) echo 'usage: rig-clone.sh snap|create' >&2; exit 2 ;;
esac
