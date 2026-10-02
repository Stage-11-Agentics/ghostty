#!/usr/bin/env python3
"""Reproduce C11-294's minimal libxev archive without changing any Zig cache."""
import gzip
import hashlib
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

UPSTREAM_SHA = "34fa50878aec6e5fa8f532867001ab3c36fae23e"
SOURCE_URL = f"https://deps.files.ghostty.org/libxev-{UPSTREAM_SHA}.tar.gz"
SOURCE_SHA256 = "6003ea6b96e4a518a128f932327d79a11bd30996b13b73baeb29916379487dd7"
ARCHIVE_ROOT = f"libxev-c11-{UPSTREAM_SHA}"


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: build-archive.py OUTPUT_DIRECTORY")
    out = Path(sys.argv[1]).resolve()
    out.mkdir(parents=True, exist_ok=True)
    original = out / "original.tar.gz"
    if not original.exists():
        subprocess.run(["curl", "--fail", "--location", "--retry", "2",
                        SOURCE_URL, "--output", str(original)], check=True)
    payload = original.read_bytes()
    if hashlib.sha256(payload).hexdigest() != SOURCE_SHA256:
        raise SystemExit("original archive checksum mismatch")
    candidate = out / "candidate"
    if candidate.exists():
        raise SystemExit(f"refusing to replace existing candidate: {candidate}")
    candidate.mkdir()
    prefix = f"libxev-{UPSTREAM_SHA}/"
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        for entry in archive.getmembers():
            if entry.isdir() and entry.name.rstrip("/") == prefix.rstrip("/"):
                continue
            if not entry.name.startswith(prefix):
                raise SystemExit(f"unexpected archive member: {entry.name}")
            relative = Path(entry.name[len(prefix):])
            if relative.is_absolute() or ".." in relative.parts:
                raise SystemExit(f"unsafe archive member: {entry.name}")
            destination = candidate / relative
            if entry.isdir():
                destination.mkdir(parents=True, exist_ok=True)
            elif entry.isfile():
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.extractfile(entry) as source, destination.open("wb") as target:
                    shutil.copyfileobj(source, target)
                destination.chmod(0o755 if entry.mode & 0o111 else 0o644)
            else:
                raise SystemExit(f"unsupported archive member: {entry.name}")
    patch = Path(__file__).resolve().with_name("queued-write-backpressure.patch")
    subprocess.run(["git", "apply", "--check", str(patch)], cwd=candidate, check=True)
    subprocess.run(["git", "apply", str(patch)], cwd=candidate, check=True)

    # Sorted POSIX tar entries with normalized ownership/time/modes and a gzip
    # header without a filename or timestamp produce repeatable archive bytes.
    archive_path = out / f"{ARCHIVE_ROOT}.tar.gz"
    with archive_path.open("wb") as raw:
        with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
                for path in [candidate, *sorted(candidate.rglob("*"))]:
                    suffix = path.relative_to(candidate).as_posix()
                    name = ARCHIVE_ROOT if suffix == "." else f"{ARCHIVE_ROOT}/{suffix}"
                    entry = tarfile.TarInfo(name)
                    entry.uid = entry.gid = entry.mtime = 0
                    entry.uname = entry.gname = ""
                    if path.is_dir():
                        entry.type = tarfile.DIRTYPE
                        entry.mode = 0o755
                        archive.addfile(entry)
                    else:
                        entry.mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
                        entry.size = path.stat().st_size
                        with path.open("rb") as source:
                            archive.addfile(entry, source)
    print(f"candidate={candidate}")
    print(f"archive={archive_path}")
    print(f"sha256={hashlib.sha256(archive_path.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
