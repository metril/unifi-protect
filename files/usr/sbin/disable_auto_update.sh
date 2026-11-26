#!/usr/bin/env bash
# Set autoUpdate.schedule to null in unifi-core's firmware.yaml (in-app updates break the container).
set -euo pipefail

log() { echo "[disable-auto-update] $*"; }

find_yaml() { find /data/unifi-core /etc/unifi-core -name firmware.yaml 2>/dev/null | head -n1; }

yaml=""
for _ in $(seq 1 60); do
    yaml=$(find_yaml)
    [ -n "$yaml" ] && break
    sleep 5
done
[ -n "$yaml" ] || { log "firmware.yaml not found, nothing to do"; exit 0; }

tmp=$(mktemp)
awk '
    /^[[:space:]]*autoUpdate:/ { inblock=1; print; next }
    inblock && /^[[:space:]]*schedule:/ {
        match($0, /^[[:space:]]*/); ind=substr($0, 1, RLENGTH)
        print ind "schedule: null"; inblock=0; next
    }
    inblock && /^[^[:space:]]/ { inblock=0 }
    { print }
' "$yaml" > "$tmp"

if cmp -s "$yaml" "$tmp"; then
    log "auto update already disabled"
    rm -f "$tmp"
    exit 0
fi
cat "$tmp" > "$yaml"
rm -f "$tmp"
log "disabled autoUpdate.schedule in $yaml, restarting unifi-core"
systemctl try-restart unifi-core.service || true
