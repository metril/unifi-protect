"""Container tests. Need docker (privileged) and IMAGE env var; OLD_IMAGE for the upgrade test."""
import os
import subprocess
import time
import urllib.request
import ssl
import urllib.error
import uuid

import pytest

pytestmark = pytest.mark.container
IMAGE = os.environ.get("IMAGE")
OLD_IMAGE = os.environ.get("OLD_IMAGE")
TIMEOUT = int(os.environ.get("HEALTH_TIMEOUT", "600"))

if not IMAGE:
    pytest.skip("IMAGE not set", allow_module_level=True)


def docker(*args, check=True):
    return subprocess.run(["docker", *args], capture_output=True, text=True, check=check)


def run_container(image, name, data_root):
    for d in ("srv", "data", "persistent"):
        os.makedirs(data_root / d, exist_ok=True)
    docker(
        "run", "-d", "--name", name, "--privileged", "--cgroupns=host", "--hostname", "UNVR",
        "--add-host", "UNVR:127.0.1.1", "-e", "container=docker", "-e", "STORAGE_DISK=/dev/sda",
        "--tmpfs", "/run", "--tmpfs", "/run/lock", "--tmpfs", "/tmp",
        "-v", "/sys/fs/cgroup:/sys/fs/cgroup",
        "-v", f"{data_root}/srv:/srv", "-v", f"{data_root}/data:/data",
        "-v", f"{data_root}/persistent:/persistent",
        "--security-opt", "apparmor=unconfined", "--security-opt", "seccomp=unconfined",
        "-p", "127.0.0.1::443", image,
    )


def wait_healthy(name):
    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        st = docker("inspect", "-f", "{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}",
                    name, check=False).stdout.split()
        if st[:1] == ["false"]:
            raise AssertionError(f"{name} exited:\n{docker('logs', '--tail', '80', name, check=False).stdout}")
        if st[1:] == ["healthy"]:
            return
        if len(st) == 1:  # image without HEALTHCHECK (old fork image): probe directly
            ok = docker("exec", name, "bash", "-c",
                        "systemctl is-active --quiet unifi-protect && curl -ksf -o /dev/null https://localhost/",
                        check=False).returncode == 0
            if ok:
                return
        time.sleep(10)
    raise AssertionError(f"{name} not healthy in {TIMEOUT}s:\n{docker('logs', '--tail', '80', name, check=False).stdout}")


def unit_active(name, unit):
    return docker("exec", name, "systemctl", "is-active", unit, check=False).stdout.strip() == "active"


@pytest.fixture
def cname(request):
    name = f"unifi-protect-test-{os.environ.get('PYTEST_XDIST_WORKER', 'gw0')}-{uuid.uuid4().hex[:6]}"
    names = [name]
    request.addfinalizer(lambda: [docker("rm", "-f", n, check=False) for n in names])
    return names


def https_status(name):
    port = docker("port", name, "443/tcp").stdout.split(":")[-1].strip()
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    class NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None
    op = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ctx), NoRedirect)
    try:
        return op.open(f"https://127.0.0.1:{port}/", timeout=15).status
    except urllib.error.HTTPError as e:
        return e.code


def test_smoke(cname, tmp_path):
    name = cname[0]
    run_container(IMAGE, name, tmp_path)
    wait_healthy(name)
    for unit in ("postgresql", "unifi-core", "unifi-protect"):
        assert unit_active(name, unit), unit
    assert https_status(name) in (200, 302)


@pytest.mark.skipif(not OLD_IMAGE, reason="OLD_IMAGE not set")
def test_upgrade(cname, tmp_path):
    old = cname[0]
    new = old + "-new"
    cname.append(new)
    run_container(OLD_IMAGE, old, tmp_path)
    wait_healthy(old)
    docker("stop", "-t", "120", old)
    docker("rm", old)
    run_container(IMAGE, new, tmp_path)
    wait_healthy(new)
    assert unit_active(new, "unifi-protect")
    backups = list((tmp_path / "data" / "backups").glob("*"))
    assert backups, "pre-upgrade backup was not created"
