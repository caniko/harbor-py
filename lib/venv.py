"""Prepare a CPython venv and install its command-scoped interpreter launcher."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile


def configuration(path):
    return dict(
        line.split(" = ", 1)
        for line in (path / "pyvenv.cfg").read_text().splitlines()
        if " = " in line
    )


def compatible(path, site):
    try:
        cfg = configuration(path)
        base = Path(sys._base_executable).resolve()
        # uv records home/version_info; CPython additionally records executable.
        recorded = Path(cfg.get("executable", str(Path(cfg["home"]) / base.name)))
        version = cfg.get("version_info", cfg.get("version", ""))
        return (
            recorded.resolve() == base
            and version.split(".")[:2]
            == [str(sys.version_info.major), str(sys.version_info.minor)]
            and (cfg.get("include-system-site-packages", "false").lower() == "true")
            == site
        )
    except (OSError, KeyError):
        return False


def create(path, site):
    subprocess.run(
        [
            sys.executable,
            "-m",
            "venv",
            "--without-pip",
            *(["--system-site-packages"] if site else []),
            str(path),
        ],
        check=True,
    )


@contextlib.contextmanager
def venv_lock(path):
    # Keep the anchor beside the venv: replacement moves/removes the venv itself.
    # Never unlink it, including on failure, so waiters retain the same inode.
    path.parent.mkdir(parents=True, exist_ok=True)
    anchor = path.parent / f".{path.name}.harbor-python.lock"
    fd = os.open(anchor, os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ValueError(f"venv lock must be a regular file: {anchor}")
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def prepare(path, site):
    with venv_lock(path):
        prepare_locked(path, site)


def prepare_locked(path, site):
    if path.is_symlink():
        raise ValueError(f"venv directory must not be a symlink: {path}")
    if compatible(path, site):
        return
    if not path.exists():
        create(path, site)
        return
    marker = path / ".harbor-python.json"
    if not (path / "pyvenv.cfg").is_file():
        raise ValueError(
            f"incompatible unmanaged venv at {path}; move it aside before recreating it"
        )
    if not marker.is_file():
        # A uv run outside the shell recreates the project venv without the
        # site policy; uv.lock rebuilds it, so it is as replaceable as ours.
        try:
            uv_created = "uv" in configuration(path)
        except OSError:
            uv_created = False
        if not uv_created:
            raise ValueError(
                f"incompatible unmanaged venv at {path}; move it aside before recreating it"
            )
        print(
            f"harbor-py: replacing uv-created venv at {path} (interpreter/site policy mismatch)",
            file=sys.stderr,
        )
    # Retain the previous environment if creation fails (including ABI errors).
    with tempfile.TemporaryDirectory(prefix=".harbor-venv-", dir=path.parent) as tmp:
        previous = Path(tmp) / "previous"
        path.rename(previous)
        try:
            create(path, site)
        except BaseException:
            if path.exists():
                shutil.rmtree(path)
            previous.rename(path)
            raise


def wrap(path, launcher, site):
    with venv_lock(path):
        wrap_locked(path, launcher, site)


def wrap_locked(path, launcher, site):
    if path.is_symlink() or not compatible(path, site):
        raise ValueError(
            f"venv does not match the selected interpreter/site policy: {path}"
        )
    # Both creators use aliases, but rewrite each alias explicitly so uv's
    # recreation and --copies venvs receive the same runtime.
    # Unique temporary names keep concurrent shell entries from unlinking
    # each other's in-flight aliases. Publish each alias and receipt atomically.
    with tempfile.TemporaryDirectory(prefix=".harbor-python-", dir=path / "bin") as tmp:
        for name in [
            "python",
            "python3",
            f"python{sys.version_info.major}.{sys.version_info.minor}",
        ]:
            temporary = Path(tmp) / name
            temporary.symlink_to(launcher)
            temporary.replace(path / "bin" / name)
        marker = Path(tmp) / "marker.json"
        marker.write_text(
            json.dumps(
                {
                    "base_executable": str(Path(sys._base_executable).resolve()),
                    "system_site_packages": site,
                }
            )
            + "\n"
        )
        marker.replace(path / ".harbor-python.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=["prepare", "wrap"])
    parser.add_argument("--venv", type=Path, required=True)
    parser.add_argument("--launcher", type=Path, required=True)
    parser.add_argument("--system-site-packages", action="store_true")
    args = parser.parse_args()
    if sys.implementation.name != "cpython":
        parser.error("scoped venv launchers require CPython")
    path = args.venv.absolute()
    try:
        with venv_lock(path):
            if args.operation == "prepare":
                prepare_locked(path, args.system_site_packages)
            wrap_locked(path, args.launcher, args.system_site_packages)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"harbor-py: {error}\n")


if __name__ == "__main__":
    main()
