#!/usr/bin/env bash
# Vendor patches. Each patch checks its anchor first and fails naming itself.
# Usage: apply_patches.sh pre|post   (pre: before the files/ overlay is copied, post: after)
set -euo pipefail

die() { echo "PATCH FAILED [$1]: $2" >&2; exit 1; }

# Keep the vendor binaries that the overlay replaces.
patch_backup_originals() {
    local f
    for f in /sbin/mdadm /sbin/ubnt-tools; do
        [ -e "$f" ] || die backup_originals "$f not present in image"
        [ -e "$f.orig" ] || mv "$f" "$f.orig"
    done
}

# unifi-core talks to ustated over gRPC; swap in the mock client (file comes from the overlay).
patch_storage_api_mock() {
    local f=/usr/share/unifi-core/app/service.js
    local search="import {StorageAPIClient}from'@ubnt/unifi-protobufs/unifi/firmware/storage/v2/api_grpc_pb.js';"
    local repl="import {StorageAPIClient}from'./mockStorageAPIClient.js';"
    [ -f "$f" ] || die storage_api_mock "$f missing"
    grep -qF "$search" "$f" || die storage_api_mock "anchor not found in $f (vendor code changed)"
    sed -i ':a;N;$!ba;s|'"$search"'|'"$repl"'|g' "$f"
    grep -qF "$repl" "$f" || die storage_api_mock "replacement not applied"
}

# pg-cluster-upgrade removes directories with plain rm -f.
patch_pg_cluster_upgrade_rm() {
    local f=/sbin/pg-cluster-upgrade
    [ -f "$f" ] || die pg_cluster_upgrade_rm "$f missing"
    grep -q 'rm -f' "$f" || die pg_cluster_upgrade_rm "anchor 'rm -f' not found in $f"
    sed -i 's/rm -f/rm -rf/' "$f"
}

# Force local PG connections to TCP.
patch_pghost_env() {
    local f=/usr/lib/ulp-go/scripts/envs.sh
    [ -f "$f" ] || die pghost_env "$f missing"
    grep -q 'PGHOST=127.0.0.1' "$f" || printf '\n\nexport PGHOST=127.0.0.1\n' >> "$f"
}

patch_misc() {
    [ -d /etc/sudoers.d ] || die misc "/etc/sudoers.d missing"
    [ -e /usr/bin/uled-ctrl ] || touch /usr/bin/uled-ctrl
    chmod +x /usr/bin/uled-ctrl
    chown root:root /etc/sudoers.d/*
}

patch_enable_units() {
    local u
    for u in network_setup storage_disk dbpermissions fix_hosts fix_apt_ubiquiti_sources \
             init_console ustated-mock pre-upgrade-backup disable-auto-update; do
        [ -f "/etc/systemd/system/$u.service" ] || die enable_units "unit $u.service missing from overlay"
        systemctl enable "$u"
    done
}

case "${1:-}" in
    pre)  patch_backup_originals ;;
    post) patch_storage_api_mock; patch_pg_cluster_upgrade_rm; patch_pghost_env; patch_misc; patch_enable_units ;;
    *)    echo "usage: $0 pre|post" >&2; exit 2 ;;
esac
echo "patches ($1) applied"
