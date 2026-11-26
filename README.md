# unifi-protect

UniFi Protect (UOS 6 / Debian 13, Protect 7.3) in a privileged arm64 Docker container, built from the Ubiquiti UNVR firmware and product debs. Updates are detected, built, tested and published automatically.

Image: `ghcr.io/metril/unifi-protect:stable` (also `:previous`, `:<protect-version>`, `:sha-<short>`). PostgreSQL stays at 14 with the same data paths, so existing `/srv`, `/data` and `/persistent` volumes carry over.

## Deploy (Dockhand stack / plain compose)

1. Paste `compose/compose.yaml` as a stack, or point Dockhand at this repo.
2. Set the variables from `compose/.env.example` as stack variables (or `.env`).
3. Deploy. The `traefik-proxy` network must already exist.

| Variable | Meaning |
|---|---|
| `STORAGE_PATH` | absolute host path holding `srv/`, `data/`, `persistent/` |
| `UNVR_IP`, `LAN_SUBNET`, `LAN_GATEWAY` | macvlan address, subnet, gateway |
| `MACVLAN_PARENT` | host NIC for macvlan |
| `MAC_ADDRESS` | pinned MAC (device identity derives from it) |
| `LAN_SUBNET_PREFIX` | first three octets of the LAN; unset = interface renaming is skipped |
| `IMAGE`, `STORAGE_DISK`, `DEBUG` | optional |

After first setup, in-app auto-update is switched off automatically (`autoUpdate.schedule: null`); versions only change through the image.

## Migrating from metril/unifi-protect-unvr-docker-arm64

1. `docker compose down`, then a cold backup: `tar czf backup.tgz storage/data storage/persistent storage/srv/postgresql`.
2. Use the new compose with the same volume paths (`STORAGE_PATH`), the same IP and MAC; start it.
3. On first boot with a new image version, `pre-upgrade-backup.service` copies `/data/postgresql`, `/srv/postgresql`, `/data/unifi-core` and `/persistent` to `/data/backups/<oldver>-<timestamp>/` (last 2 kept).
4. Verify login, cameras and recordings.

Rollback: set the image to `:previous`, stop, restore the matching `/data/backups/...` directories (or the tar), start.

## Automation

- `update.yml` (daily): `scripts/resolve_versions.py` picks the newest Ubiquiti firmware and product debs that are at least `soak_days` (3) old, never downgrades, and fails on API schema changes. If `versions.json` changed it calls `build.yml`; on success it commits `versions.json` to `main`. If a ruleset blocks the `GITHUB_TOKEN` push to `main`, add an optional `SYNC_TOKEN` secret (a PAT with bypass); it is used when present. Failures open one `auto-update-failure` issue.
- `build.yml`: native arm64 build (`fwdebs` stage cached as `ghcr.io/metril/unifi-protect-fwdebs:<fw-version>`, registry layer cache), pytest unit/smoke/upgrade shards, aggregator check `build-result`, then publish on `main`.
- `upstream-watch.yml` (weekly): issue when dciancu's `main`/PR list or topper59's PR #83 changes. Port changes by hand.
- `ghcr-cleanup.yml` (weekly): remove untagged GHCR versions.

Local: `python scripts/build_args.py | sed 's/^/--build-arg /'`, or `pip install -r requirements-dev.txt && pytest -n auto tests/`. Container tests need `IMAGE=...` (and `OLD_IMAGE=...` for the upgrade test).

## Credits and license

Derived from [dciancu/unifi-protect-unvr-docker-arm64](https://github.com/dciancu/unifi-protect-unvr-docker-arm64) and topper59's UOS 6 / Debian 13 port (PR #83); thanks to both. The upstream repository declares no license file, so its original files are credited here but not relicensed. Original work in this repository is MIT licensed (`LICENSE`). Ubiquiti software is downloaded at build time and is not covered by this license; this is not an official Ubiquiti product.
