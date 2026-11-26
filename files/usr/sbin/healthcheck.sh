#!/usr/bin/env bash
set -u
for u in postgresql unifi-core unifi-protect; do
    systemctl is-active --quiet "$u" || { echo "$u not active"; exit 1; }
done
curl -ksf -o /dev/null https://localhost/ || { echo "https check failed"; exit 1; }
