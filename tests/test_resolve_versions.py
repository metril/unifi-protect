import copy
import json
from datetime import datetime, timezone

import pytest
import resolve_versions as r

from conftest import load

NOW = datetime(2026, 11, 25, tzinfo=timezone.utc)


def base_versions():
    return {
        "firmware": {"url": "https://x/old.bin", "version": "6.0.11", "released": "2026-10-07"},
        "base_image": {"ref": "debian:13", "digest": "sha256:abc"},
        "packages_to_extract": ["uos"],
        "products": {n: {"url": f"https://x/{n}.deb", "version": "0.0.1", "released": "2020-01-01"}
                     for n in r.PRODUCTS},
        "soak_days": 3,
    }


def make_fetch(fw=None, product=None):
    fw = fw or load("firmware_list.json")
    product = product or load("product_ms.json")

    def fetch(url):
        return fw if "platform~~unvr" in url else product
    return fetch


def write(tmp_path, d):
    p = tmp_path / "versions.json"
    p.write_text(json.dumps(d))
    return p


def test_normal_bump(tmp_path, monkeypatch):
    out = tmp_path / "gh_out"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    p = write(tmp_path, base_versions())
    assert r.main(["--versions", str(p)], fetch=make_fetch(), now=NOW) == 0
    new = json.loads(p.read_text())
    assert new["firmware"]["version"] == "6.0.17"
    assert new["firmware"]["sha256"]
    assert new["products"]["ms"]["version"] == "5.1.317"
    assert "changed=true" in out.read_text()


def test_unchanged_does_not_write(tmp_path, monkeypatch):
    monkeypatch.delenv("GITHUB_OUTPUT", raising=False)
    p = write(tmp_path, base_versions())
    r.main(["--versions", str(p)], fetch=make_fetch(), now=NOW)
    mtime = p.stat().st_mtime_ns
    out = tmp_path / "gh_out"
    monkeypatch.setenv("GITHUB_OUTPUT", str(out))
    assert r.main(["--versions", str(p)], fetch=make_fetch(), now=NOW) == 0
    assert p.stat().st_mtime_ns == mtime
    assert "changed=false" in out.read_text()


def test_soak_not_met_keeps_older(tmp_path):
    # 6.0.17 was created 2026-11-10; one day later it is still inside a 3d soak
    now = datetime(2026, 11, 11, tzinfo=timezone.utc)
    p = write(tmp_path, base_versions())
    assert r.main(["--versions", str(p), "--dry-run"], fetch=make_fetch(), now=now) == 0
    cur = base_versions()
    new, notes = r.resolve(cur, make_fetch(), now)
    assert new["firmware"]["version"] == "6.0.11"  # newest eligible (>=3d old), 6.0.17 skipped


def test_soak_nothing_eligible_keeps_current():
    cur = base_versions()
    new, notes = r.resolve(cur, make_fetch(), datetime(2026, 5, 1, tzinfo=timezone.utc))
    assert new == cur
    assert any("keeping current" in n for n in notes)


def test_never_downgrades():
    cur = base_versions()
    cur["firmware"]["version"] = "9.9.9"
    new, notes = r.resolve(cur, make_fetch(), NOW)
    assert new["firmware"]["version"] == "9.9.9"
    assert any("keeping current" in n for n in notes)


def test_schema_change_missing_download_link(tmp_path, capsys):
    fw = copy.deepcopy(load("firmware_list.json"))
    for it in fw["_embedded"]["firmware"]:
        del it["_links"]["data"]
    p = write(tmp_path, base_versions())
    assert r.main(["--versions", str(p)], fetch=make_fetch(fw=fw), now=NOW) == 1
    assert "_links.data.href" in capsys.readouterr().err


def test_schema_change_missing_embedded(tmp_path, capsys):
    p = write(tmp_path, base_versions())
    assert r.main(["--versions", str(p)], fetch=make_fetch(product={"items": []}), now=NOW) == 1
    assert "_embedded.firmware" in capsys.readouterr().err


def test_invalid_versions_json(tmp_path, capsys):
    d = base_versions()
    del d["soak_days"]
    p = write(tmp_path, d)
    assert r.main(["--versions", str(p)], fetch=make_fetch(), now=NOW) == 1
    assert "soak_days" in capsys.readouterr().err


def test_build_args():
    import build_args
    args = build_args.build_args({**base_versions(), "packages_to_extract": ["a", "b"]})
    assert args["FW_PACKAGES"] == "a b"
    assert args["BASE_IMAGE"] == "debian:13@sha256:abc"
