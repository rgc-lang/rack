#!/usr/bin/env python3
"""Package an RGC toolchain component into per-OS release archives.

This script is used by the release CI workflow (`.github/workflows/release.yml`)
and can also be run locally to verify packaging. It is intentionally
self-contained so each repository (rgc, rack) can own a copy.

For the `rgc` component the archive contains the compiler binary plus the
standard library source modules (`lib/`). For `rack` it contains just the
package-manager binary. Every platform uses `.tar.gz`, including Windows, so
`rack self` can install with the RGC standard library alone (no zip support).

For `rack` the packaging step also emits the raw bootstrap binary used by
`install.sh` / `install.ps1` plus its `.sha256` checksum:

  dist/rack-linux-x64.tar.gz
  dist/rack-linux-x64
  dist/rack-linux-x64.sha256
  dist/rack-windows-x64.tar.gz
  dist/rack-windows-x64.exe
  dist/rack-windows-x64.exe.sha256

Usage:
  python3 scripts/package-release.py \\
      --component rgc \\
      --os linux --arch x64 \\
      --bin build/rgc \\
      --lib-dir lib \\
      --out dist

  python3 scripts/package-release.py \\
      --component rack \\
      --os linux --arch x64 \\
      --bin target/bin/rack \\
      --out dist
"""

import argparse
import hashlib
import shutil
import sys
import tarfile
from pathlib import Path

COMPONENTS = ("rgc", "rack")
OS_NAMES = ("linux", "macos", "windows")
ARCH_NAMES = ("x64", "arm64")


def archive_stem(component: str, os_name: str, arch: str) -> str:
    return f"{component}-{os_name}-{arch}"


def binary_arcname(component: str, os_name: str) -> str:
    return f"{component}.exe" if os_name == "windows" else component


def add_file_to_tar(tf: tarfile.TarFile, src: Path, arcname: str) -> None:
    info = tf.gettarinfo(str(src), arcname=arcname)
    if info.isfile():
        info.mode = 0o755
    with open(src, "rb") as f:
        tf.addfile(info, f)


def write_tar_gz(path: Path, files: list[tuple[Path, str]]) -> None:
    with tarfile.open(path, "w:gz") as tf:
        for src, arc in files:
            if src.is_dir():
                tf.add(str(src), arcname=arc, recursive=True)
            else:
                add_file_to_tar(tf, src, arc)


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def write_bootstrap_binary(component: str, os_name: str, arch: str,
                           bin_path: Path, out: Path) -> None:
    raw_name = archive_stem(component, os_name, arch) + (
        ".exe" if os_name == "windows" else ""
    )
    raw = out / raw_name
    shutil.copyfile(bin_path, raw)
    raw.chmod(0o755)
    digest = sha256_of(raw)
    (out / (raw_name + ".sha256")).write_text(
        f"{digest}  {raw_name}\n", encoding="utf-8"
    )
    print(f"wrote {raw}")
    print(f"wrote {out / (raw_name + '.sha256')}")


def package(component: str, os_name: str, arch: str, bin_path: Path,
            lib_dir: Path | None, out: Path) -> Path:
    if component not in COMPONENTS:
        sys.exit(f"error: --component must be one of {', '.join(COMPONENTS)}")
    if not bin_path.is_file():
        sys.exit(f"error: binary not found: {bin_path}")

    out.mkdir(parents=True, exist_ok=True)
    stem = archive_stem(component, os_name, arch)
    path = out / f"{stem}.tar.gz"

    files = [(bin_path, binary_arcname(component, os_name))]
    if component == "rgc" and lib_dir is not None:
        if not lib_dir.is_dir():
            sys.exit(f"error: lib directory not found: {lib_dir}")
        files.append((lib_dir, "lib"))

    write_tar_gz(path, files)
    print(f"wrote {path}")

    if component == "rack":
        write_bootstrap_binary(component, os_name, arch, bin_path, out)
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--component", required=True, choices=COMPONENTS)
    parser.add_argument("--os", required=True, choices=OS_NAMES)
    parser.add_argument("--arch", required=True, choices=ARCH_NAMES)
    parser.add_argument("--bin", required=True, type=Path, help="Path to the component binary")
    parser.add_argument("--lib-dir", type=Path, default=None,
                        help="Path to the standard library directory (rgc only)")
    parser.add_argument("--out", type=Path, default=Path("dist"))
    args = parser.parse_args()

    package(args.component, args.os, args.arch, args.bin, args.lib_dir, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
