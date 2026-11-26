#!/usr/bin/env bash
# Download the UNVR firmware, unpack it and repack only the requested packages.
# Env: FW_URL FW_PACKAGES (space separated, globs allowed) [FW_SHA256] [FW_SIZE]
# Output: /debs/*.deb and /debs/version
set -euo pipefail

: "${FW_URL:?FW_URL is required}"
: "${FW_PACKAGES:?FW_PACKAGES is required}"
work=/opt/fw
mkdir -p "$work" /debs
cd "$work"

wget --no-verbose --progress=dot:giga -O fwupdate.bin "$FW_URL"
if [ -n "${FW_SIZE:-}" ]; then
    actual=$(stat -c %s fwupdate.bin)
    [ "$actual" = "$FW_SIZE" ] || { echo "ERROR: firmware size $actual != expected $FW_SIZE" >&2; exit 1; }
fi
if [ -n "${FW_SHA256:-}" ]; then
    echo "${FW_SHA256}  fwupdate.bin" | sha256sum -c - || { echo "ERROR: firmware sha256 mismatch" >&2; exit 1; }
fi

id build >/dev/null 2>&1 || useradd --shell /bin/bash build
chown build "$work"
binwalk --run-as=build -e fwupdate.bin
rm -f fwupdate.bin
root=$(find "$work" -type d -name squashfs-root | head -n1)
[ -n "$root" ] || { echo "ERROR: squashfs-root not found after binwalk" >&2; exit 1; }

cp "$root/usr/lib/version" /debs/version

mapfile -t installed < <(dpkg-query --admindir="$root/var/lib/dpkg" -W -f='${Package}\n')
want=()
missing=()
for pat in $FW_PACKAGES; do
    found=0
    for p in "${installed[@]}"; do
        # shellcheck disable=SC2254
        case "$p" in $pat) want+=("$p"); found=1 ;; esac
    done
    [ "$found" = 1 ] || missing+=("$pat")
done
if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: packages not found in firmware: ${missing[*]}" >&2
    echo "Update packages_to_extract in versions.json. Installed ubnt packages:" >&2
    printf '%s\n' "${installed[@]}" | grep -E '^(u|ubnt|uos|node|fluent|ulp)' >&2 || true
    exit 1
fi

cd /debs
for p in "${want[@]}"; do
    dpkg-repack --root="$root" --arch=arm64 "$p"
done
ls -lh /debs
rm -rf "$work"
