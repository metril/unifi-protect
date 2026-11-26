#!/usr/bin/env python3
"""Print docker build args (KEY=VALUE per line) derived from versions.json."""
import hashlib
import json
import pathlib
import sys


def fw_tag(v):
    """<fw-version>-<hash of what determines the fwdebs content>."""
    h = hashlib.sha256()
    h.update(" ".join(v["packages_to_extract"]).encode())
    h.update((pathlib.Path(__file__).parent / "extract_debs.sh").read_bytes())
    return f"{v['firmware']['version']}-{h.hexdigest()[:10]}"


def build_args(v, source_sha=""):
    prod = v["products"]
    fw = v["firmware"]
    items = [f"{n},{p['url']},{p.get('sha256', '')}" for n, p in sorted(prod.items())]
    base = v["base_image"]
    return {
        "BASE_IMAGE": f"{base.get('ref', 'debian:13').split('@')[0]}@{base['digest']}",
        "FW_URL": fw["url"],
        "FW_VERSION": fw["version"],
        "FW_TAG": fw_tag(v),
        "FW_SHA256": fw.get("sha256", ""),
        "FW_SIZE": str(fw.get("size", "")),
        "FW_PACKAGES": " ".join(v["packages_to_extract"]),
        "PRODUCT_DEBS": " ".join(items),
        "PROTECT_VERSION": prod["unifi-protect"]["version"],
        "IMAGE_VERSION": f"{prod['unifi-protect']['version']}-fw{fw['version']}",
        "SOURCE_SHA": source_sha,
    }


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "versions.json"
    sha = sys.argv[2] if len(sys.argv) > 2 else ""
    with open(path) as f:
        for k, val in build_args(json.load(f), sha).items():
            print(f"{k}={val}")
