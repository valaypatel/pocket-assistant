#!/usr/bin/env python3
"""Builds build/music-lambda.zip for AWS Lambda (Python 3.12, x86_64).

Dependencies come from requirements.lock, which pins every one, and are fetched as Linux wheels, so the zip is correct even when built
on a Mac. The zip is reproducible: the same inputs give the same bytes, so
Terraform only redeploys when the code or requirements really change.

    python3 build.py
"""

import shutil
import stat
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "build"
PACKAGE = BUILD / "package"
ZIP = BUILD / "music-lambda.zip"
# Lambda's Python 3.12 runtime (glibc 2.34) runs any of these Linux wheels.
PLATFORMS = [
    "manylinux_2_28_x86_64",
    "manylinux_2_17_x86_64",
    "manylinux2014_x86_64",
    "manylinux_2_5_x86_64",
    "manylinux1_x86_64",
]
FIXED_TIME = (2026, 1, 1, 0, 0, 0)  # zip needs 1980 or later


def main() -> None:
    shutil.rmtree(BUILD, ignore_errors=True)
    PACKAGE.mkdir(parents=True)

    subprocess.run(
        [
            sys.executable, "-m", "pip", "install",
            "--quiet", "--disable-pip-version-check",
            "--target", str(PACKAGE),
            *[arg for tag in PLATFORMS for arg in ("--platform", tag)],
            "--implementation", "cp",
            "--python-version", "3.12",
            "--only-binary=:all:",
            # Exactly the pinned versions, and nothing else (see requirements.lock).
            "--no-deps",
            "-r", str(ROOT / "requirements.lock"),
        ],
        check=True,
    )
    shutil.copy2(ROOT / "app" / "handler.py", PACKAGE / "handler.py")

    for cache in PACKAGE.rglob("__pycache__"):
        shutil.rmtree(cache, ignore_errors=True)

    files = sorted(p for p in PACKAGE.rglob("*") if p.is_file())
    with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in files:
            info = zipfile.ZipInfo(path.relative_to(PACKAGE).as_posix(), FIXED_TIME)
            info.compress_type = zipfile.ZIP_DEFLATED
            mode = stat.S_IMODE(path.stat().st_mode) | 0o444
            info.external_attr = (stat.S_IFREG | mode) << 16
            archive.writestr(info, path.read_bytes())

    size = ZIP.stat().st_size / (1024 * 1024)
    print(f"{ZIP.relative_to(ROOT)}: {len(files)} files, {size:.1f} MB")
    if size > 49:
        sys.exit("The zip is over Lambda's 50 MB direct-upload limit.")


if __name__ == "__main__":
    main()
