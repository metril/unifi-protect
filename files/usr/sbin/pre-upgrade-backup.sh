#!/usr/bin/env bash
# Back up state when the image version changed, then record the new version.
set -euo pipefail

VERSION_FILE=/etc/unifi-protect-image-version
MARKER=/data/.image-version
BACKUPS=/data/backups
KEEP=2

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
    [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ] && has_data=1
done

if [ -z "$old" ] && [ "$has_data" = 0 ]; then
    log "first boot, nothing to back up"
else
    dest="$BACKUPS/${old:-unknown}-$(date +%Y%m%d-%H%M%S)"
    log "version ${old:-none} -> $new, backing up to $dest"
    mkdir -p "$dest"
    for src in /data/postgresql /srv/postgresql /data/unifi-core /persistent; do
        [ -e "$src" ] && cp -a --parents "$src" "$dest"
    done
    # prune: keep the newest $KEEP backups
    mapfile -t all < <(find "$BACKUPS" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
    for old_dir in "${all[@]:$KEEP}"; do
        log "pruning $old_dir"
        rm -rf "$old_dir"
    done
fi

echo "$new" > "$MARKER"
log "marker set to $new"
