#!/usr/bin/env python3
"""Resolve the newest eligible Ubiquiti firmware and product debs into versions.json.

Stdlib only. A release is eligible once it is at least `soak_days` old.
The script never downgrades, validates every API item and fails loudly on a
schema change. versions.json is rewritten only when the content changed.
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

API = "https://fw-update.ubnt.com/api/firmware"
FIRMWARE_FILTERS = {"platform": "unvr", "channel": "release"}
PRODUCT_PLATFORM = "uos-deb13-arm64"
PRODUCTS = [
    "unifi-protect", "ai-feature-console", "ai-feature-controller", "ms", "msr",
    "msp", "mst", "msf", "ds", "protect-verify", "unifi-rclone",
    "unifi-user-assets", "unifi-face-shared-lib",
]
REQUIRED_TOP = ("firmware", "base_image", "packages_to_extract", "products", "soak_days")
UA = "unifi-protect-resolver/1"


class SchemaError(Exception):
    """The API or versions.json does not have the expected shape."""


def http_json(url, retries=3):
    last = None
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as e:
            last = e
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"fetching {url} failed after {retries} attempts: {last}")


def list_url(filters, limit=10):
    q = "&".join(f"filter=eq~~{k}~~{v}" for k, v in filters.items())
    return f"{API}?{q}&sort=-version&limit={limit}"


def parse_version(v):
    """'v6.0.17+701d2b2' -> '6.0.17'."""
    return v.lstrip("v").split("+")[0]


def version_key(v):
    nums = re.findall(r"\d+", parse_version(v))
    if not nums:
        raise SchemaError(f"unparseable version {v!r}")
    return tuple(int(n) for n in nums)


def parse_time(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, AttributeError) as e:
        raise SchemaError(f"bad timestamp {s!r}") from e


def normalize(item, what):
    """Validate one API firmware item and return the fields we store."""
    if not isinstance(item, dict):
        raise SchemaError(f"{what}: item is not an object")
    missing = [k for k in ("version", "created") if k not in item]
    try:
        url = item["_links"]["data"]["href"]
    except (KeyError, TypeError):
        url = None
        missing.append("_links.data.href")
    if missing:
        raise SchemaError(f"{what}: API item missing {', '.join(missing)} (keys: {sorted(item)})")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise SchemaError(f"{what}: bad download url {url!r}")
    out = {
        "url": url,
        "version": parse_version(item["version"]),
        "released": parse_time(item["created"]).strftime("%Y-%m-%d"),
    }
    sha = item.get("sha256_checksum")
    size = item.get("file_size")
    if sha:
        out["sha256"] = sha
    if isinstance(size, int):
        out["size"] = size
    return out, parse_time(item["created"]), item["version"]


def items_of(doc, what):
    try:
        items = doc["_embedded"]["firmware"]
    except (KeyError, TypeError):
        raise SchemaError(f"{what}: response lacks _embedded.firmware") from None
    if not isinstance(items, list):
        raise SchemaError(f"{what}: _embedded.firmware is not a list")
    return items


def pick(doc, what, now, soak_days, current):
    """Newest soaked release, or `current` when none qualifies / it would downgrade."""
    cutoff = now - timedelta(days=soak_days)
    eligible = []
    for it in items_of(doc, what):
        norm, created, raw = normalize(it, what)
        if created <= cutoff:
            eligible.append((version_key(raw), norm))
    if not eligible:
        return current, f"{what}: no release older than {soak_days}d, keeping current"
    best = max(eligible, key=lambda t: t[0])[1]
    if current and version_key(current["version"]) > version_key(best["version"]):
        return current, f"{what}: newest eligible {best['version']} < current {current['version']}, keeping current"
    return best, None


def resolve(cur, fetch, now):
    validate_versions(cur)
    soak = cur["soak_days"]
    new = json.loads(json.dumps(cur))
    notes = []
    fw, note = pick(fetch(list_url(FIRMWARE_FILTERS)), "firmware", now, soak, cur["firmware"])
    new["firmware"] = fw
    notes.append(note)
    for name in PRODUCTS:
        url = list_url({"product": name, "channel": "release", "platform": PRODUCT_PLATFORM}, 5)
        p, note = pick(fetch(url), f"product {name}", now, soak, cur["products"].get(name))
        if p is None:
            raise SchemaError(f"product {name}: no releases returned")
        new["products"][name] = p
        notes.append(note)
    return new, [n for n in notes if n]


def validate_versions(d):
    if not isinstance(d, dict):
        raise SchemaError("versions.json is not an object")
    missing = [k for k in REQUIRED_TOP if k not in d]
    if missing:
        raise SchemaError(f"versions.json missing keys: {', '.join(missing)}")
    if not isinstance(d["soak_days"], int) or d["soak_days"] < 0:
        raise SchemaError("soak_days must be a non-negative integer")
    for k in ("url", "version"):
        if k not in d["firmware"]:
            raise SchemaError(f"firmware missing {k}")
    if not d["packages_to_extract"]:
        raise SchemaError("packages_to_extract is empty")
    if "digest" not in d["base_image"]:
        raise SchemaError("base_image missing digest")
    for n, p in d["products"].items():
        for k in ("url", "version", "released"):
            if k not in p:
                raise SchemaError(f"product {n} missing {k}")


def set_output(key, value):
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as f:
            f.write(f"{key}={value}\n")


def summarize(old, new):
    lines = []
    if old["firmware"]["version"] != new["firmware"]["version"]:
        lines.append(f"firmware: {old['firmware']['version']} -> {new['firmware']['version']}")
    for n, p in new["products"].items():
        o = old["products"].get(n)
        if not o or o["version"] != p["version"]:
            lines.append(f"{n}: {o['version'] if o else '-'} -> {p['version']}")
    return lines


def main(argv=None, fetch=http_json, now=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--versions", default="versions.json")
    ap.add_argument("--dry-run", action="store_true", help="do not write the file")
    a = ap.parse_args(argv)
    now = now or datetime.now(timezone.utc)
    try:
        with open(a.versions) as f:
            cur = json.load(f)
        new, notes = resolve(cur, fetch, now)
    except (SchemaError, RuntimeError, OSError, json.JSONDecodeError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1
    for n in notes:
        print(f"note: {n}")
    changed = new != cur
    for line in summarize(cur, new):
        print(line)
    print(f"changed={'true' if changed else 'false'}")
    if changed and not a.dry_run:
        with open(a.versions, "w") as f:
            json.dump(new, f, indent=2)
            f.write("\n")
    set_output("changed", "true" if changed else "false")
    if "unifi-protect" in new["products"]:
        set_output("protect_version", new["products"]["unifi-protect"]["version"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
