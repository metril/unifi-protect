#!/usr/bin/env bash
# Back up state when the image version changed, then record the new version.
# Fails closed (exit 1, marker untouched) if the backup cannot be completed.
set -euo pipefail

VERSION_FILE=/etc/unifi-protect-image-version
MARKER=/data/.image-version
BACKUPS=/data/backups
KEEP=2
SOURCES=(/data/postgresql /srv/postgresql /data/unifi-core /persistent)

log() { echo "[pre-upgrade-backup] $*"; }

new=$(cat "$VERSION_FILE" 2>/dev/null || echo unknown)
mkdir -p /data
old=""
[ -f "$MARKER" ] && old=$(cat "$MARKER")

if [ "$old" = "$new" ]; then
    log "image version unchanged ($new)"
    exit 0
fi

has_data=0
for d in /data/postgresql /data/unifi-core; do
    if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then has_data=1; fi
done

if [ -z "$old" ] && [ "$has_data" = 0 ]; then
    log "first boot, nothing to back up"
    echo "$new" > "$MARKER"
    exit 0
fi

dest="$BACKUPS/${old:-unknown}-$(date +%Y%m%d-%H%M%S)"
tmp="$dest.tmp"
mkdir -p "$BACKUPS"
# remove leftovers of interrupted runs
find "$BACKUPS" -mindepth 1 -maxdepth 1 -name '*.tmp' -exec rm -rf {} +
trap 'rm -rf "$tmp"' EXIT

# prune before copying so the space is available: keep the newest KEEP-1 now, KEEP after this run
mapfile -t all < <(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
for d in "${all[@]:$((KEEP - 1))}"; do
    log "pruning $d"
    rm -rf "$d"
done

need=0
for src in "${SOURCES[@]}"; do
    if [ -e "$src" ]; then need=$((need + $(du -sk "$src" | cut -f1))); fi
done
avail=$(df -Pk "$BACKUPS" | awk 'NR==2 {print $4}')
if [ "$avail" -lt $((need + need / 20 + 1024)) ]; then
    log "ERROR: not enough free space for backup: need ${need}K (+5%), have ${avail}K on $BACKUPS"
    log "ERROR: refusing to start the new version ($new) without a backup; free space or remove $BACKUPS"
    exit 1
fi

log "version ${old:-none} -> $new, backing up ${need}K to $dest"
mkdir -p "$tmp"
for src in "${SOURCES[@]}"; do
    if [ -e "$src" ]; then cp -a --parents "$src" "$tmp"; fi
done
mv "$tmp" "$dest"
echo "$new" > "$MARKER"
log "backup done, marker set to $new"
