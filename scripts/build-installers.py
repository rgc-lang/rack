#!/usr/bin/env python3
"""Build native installers (.deb / .pkg / .exe) for one RGC platform.

The native packages are an alternative to `install.sh`: they place a complete,
system-wide toolchain (rack + rgc + standard library) on the machine, while
`install.sh` uses `rack self` to manage per-user toolchains in ~/.rgc.

Layout chosen so the compiler finds its standard library without environment
variables or symlinks:

  linux    /usr/bin/{rack,rgc}            /usr/lib/rgc/*.rg
  macos    /usr/local/bin/{rack,rgc}      /usr/local/lib/rgc/*.rg
  windows  {app}\\bin\\{rack.exe,rgc.exe,lib\\*.rg}

The compiler searches /usr/lib/rgc and /usr/local/lib/rgc, or a `lib` directory
next to its own executable, so no environment variable or wrapper script is
needed.

Usage:
  python3 scripts/build-installers.py \\
      --version 0.2.0 --platform linux-x64 \\
      --rgc-archive dist/rgc-linux-x64.tar.gz \\
      --rack-archive dist/rack-linux-x64.tar.gz \\
      --out dist
"""

import argparse
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

APP_ID = "8E2B4C1A-7F3D-4A6E-9C5B-2D1F0E3A7B94"
MAINTAINER = "RGC Maintainers <maintainers@rgc-dev.tensorplay.cn>"
HOMEPAGE = "https://rgc-dev.tensorplay.cn"


def fail(message: str) -> "NoReturn":
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def extract_tar_gz(archive: Path, dest: Path) -> None:
    dest = dest.resolve()
    with tarfile.open(archive, "r:gz") as tf:
        for member in tf.getmembers():
            target = (dest / member.name).resolve()
            if target != dest and dest not in target.parents:
                fail(f"unsafe path in {archive}: {member.name}")
        try:
            tf.extractall(dest, filter="data")
        except TypeError:
            tf.extractall(dest)


def find_binary(root: Path, component: str, os_name: str) -> Path:
    name = component + (".exe" if os_name == "windows" else "")
    for rel in (name, f"bin/{name}"):
        path = root / rel
        if path.is_file():
            return path
    matches = sorted(p for p in root.rglob(name) if p.is_file())
    if matches:
        return matches[0]
    fail(f"{component} binary not found in {root}")
    raise AssertionError("unreachable")


def find_lib(root: Path) -> Path:
    for candidate in (root / "lib", root / "bin" / "lib"):
        if candidate.is_dir():
            return candidate
    matches = sorted(p for p in root.rglob("lib") if p.is_dir())
    if matches:
        return matches[0]
    fail(f"standard library directory not found in {root}")
    raise AssertionError("unreachable")


def copy_tree(src: Path, dst: Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    for entry in sorted(src.iterdir()):
        target = dst / entry.name
        if entry.is_dir():
            copy_tree(entry, target)
        elif entry.is_file():
            shutil.copyfile(entry, target)
            target.chmod(0o644)


def install_binary(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    dst.chmod(0o755)


def directory_size_kib(root: Path) -> int:
    total = 0
    for path in root.rglob("*"):
        if path.is_file():
            total += path.stat().st_size
    return max(1, total // 1024)


def build_deb(version: str, platform: str, rgc_bin: Path, lib_dir: Path,
              rack_bin: Path, out: Path, work: Path) -> Path:
    arch = {"linux-x64": "amd64", "linux-arm64": "arm64"}[platform]
    payload = work / "payload"
    install_binary(rack_bin, payload / "usr/bin/rack")
    install_binary(rgc_bin, payload / "usr/bin/rgc")
    copy_tree(lib_dir, payload / "usr/lib/rgc")

    control_dir = payload / "DEBIAN"
    control_dir.mkdir(parents=True, exist_ok=True)
    control = (
        f"Package: rgc\n"
        f"Version: {version}\n"
        f"Architecture: {arch}\n"
        f"Maintainer: {MAINTAINER}\n"
        f"Section: devel\n"
        f"Priority: optional\n"
        f"Installed-Size: {directory_size_kib(payload)}\n"
        f"Depends: libc6, libstdc++6, zlib1g\n"
        f"Homepage: {HOMEPAGE}\n"
        f"Description: RGC compiler and rack package manager\n"
        f" RGC is a small self-hosted language with a cargo-like package\n"
        f" manager. This package installs a system-wide compiler and its\n"
        f" standard library.\n"
    )
    (control_dir / "control").write_text(control, encoding="utf-8")

    path = out / f"rgc-{version}-{platform}.deb"
    subprocess.run(
        ["dpkg-deb", "--build", "--root-owner-group", str(payload), str(path)],
        check=True,
    )
    return path


def build_pkg(version: str, platform: str, rgc_bin: Path, lib_dir: Path,
              rack_bin: Path, out: Path, work: Path) -> Path:
    payload = work / "payload"
    install_binary(rack_bin, payload / "usr/local/bin/rack")
    install_binary(rgc_bin, payload / "usr/local/bin/rgc")
    copy_tree(lib_dir, payload / "usr/local/lib/rgc")

    path = out / f"rgc-{version}-{platform}.pkg"
    subprocess.run(
        [
            "pkgbuild",
            "--root", str(payload),
            "--identifier", "cn.tensorplay.rgc",
            "--version", version,
            "--install-location", "/",
            "--ownership", "recommended",
            str(path),
        ],
        check=True,
    )
    return path


def find_iscc(explicit: str | None) -> str:
    if explicit:
        return explicit
    candidates = [
        r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe",
        r"C:\Program Files\Inno Setup 6\ISCC.exe",
    ]
    for candidate in candidates:
        if Path(candidate).is_file():
            return candidate
    found = shutil.which("ISCC") or shutil.which("iscc")
    if found:
        return found
    fail("Inno Setup compiler (ISCC.exe) not found; install Inno Setup 6 or pass --iscc")
    raise AssertionError("unreachable")


def build_exe(version: str, platform: str, rgc_bin: Path, lib_dir: Path,
              rack_bin: Path, out: Path, work: Path, iscc_arg: str | None) -> Path:
    arch = platform.split("-", 1)[1]
    stage = work / "stage"
    bin_dir = stage / "bin"
    install_binary(rack_bin, bin_dir / "rack.exe")
    install_binary(rgc_bin, bin_dir / "rgc.exe")
    copy_tree(lib_dir, bin_dir / "lib")

    arch_allowed = "x64compatible" if arch == "x64" else "arm64"
    iss = work / "rgc.iss"
    # `%` formatting keeps Inno's own {app}/{autopf} constants readable; the
    # doubled `{{` before the AppId is Inno's escape for a literal `{`.
    iss.write_text(
        r"""[Setup]
AppId={{%(app_id)s}
AppName=RGC
AppVersion=%(version)s
AppPublisher=RGC
AppPublisherURL=%(homepage)s
DefaultDirName={autopf}\RGC
DefaultGroupName=RGC
DisableProgramGroupPage=yes
OutputDir=%(out)s
OutputBaseFilename=rgc-%(version)s-%(platform)s
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=%(arch_allowed)s
ArchitecturesInstallIn64BitMode=%(arch_allowed)s
ChangesEnvironment=yes
UninstallDisplayIcon={app}\bin\rack.exe

[Files]
Source: "%(stage)s\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Registry]
; Append {app}\bin to the machine PATH. preservestringtype keeps the existing
; REG_EXPAND_SZ type, and the Check keeps re-installs from adding a duplicate.
Root: HKLM; Subkey: "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}\bin"; Flags: preservestringtype; Check: NeedsAddPath(ExpandConstant('{app}\bin'))

[Code]
function PathEntry(S: string): string;
var
  Text: string;
begin
  Text := S;
  while (Length(Text) > 1) and (Copy(Text, Length(Text), 1) = '\') do
    Delete(Text, Length(Text), 1);
  Result := Uppercase(Text);
end;

function EnvKey: string;
begin
  Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
end;

function NeedsAddPath(Param: string): Boolean;
var
  OrigPath: string;
begin
  if not RegQueryStringValue(HKLM, EnvKey, 'Path', OrigPath) then
  begin
    Result := True;
    Exit;
  end;
  Result := Pos(';' + PathEntry(Param) + ';', ';' + PathEntry(OrigPath) + ';') = 0;
end;

// Inno does not restore a registry value it overwrote, so drop only our own
// entry on uninstall and leave every other PATH item untouched.
procedure StripInstalledPath;
var
  OrigPath, NewPath, Item, Rest: string;
  Dir: string;
  P: Integer;
begin
  Dir := PathEntry(ExpandConstant('{app}\bin'));
  if not RegQueryStringValue(HKLM, EnvKey, 'Path', OrigPath) then
    Exit;
  if Pos(';' + Dir + ';', ';' + PathEntry(OrigPath) + ';') = 0 then
    Exit;
  Rest := OrigPath;
  NewPath := '';
  while Rest <> '' do
  begin
    P := Pos(';', Rest);
    if P > 0 then
    begin
      Item := Copy(Rest, 1, P - 1);
      Delete(Rest, 1, P);
    end else
    begin
      Item := Rest;
      Rest := '';
    end;
    if PathEntry(Item) <> Dir then
    begin
      if NewPath <> '' then
        NewPath := NewPath + ';';
      NewPath := NewPath + Item;
    end;
  end;
  if not RegWriteExpandStringValue(HKLM, EnvKey, 'Path', NewPath) then
    Log('uninstaller: failed to update the machine PATH');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    StripInstalledPath;
end;
"""
        % {
            "app_id": APP_ID,
            "version": version,
            "homepage": HOMEPAGE,
            "out": str(out.resolve()),
            "platform": platform,
            "arch_allowed": arch_allowed,
            "stage": str(stage.resolve()),
        },
        encoding="utf-8",
    )

    path = out.resolve() / f"rgc-{version}-{platform}.exe"
    subprocess.run([find_iscc(iscc_arg), str(iss)], check=True)
    return path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="Release version, e.g. 0.2.0")
    parser.add_argument("--platform", required=True,
                        choices=["linux-x64", "linux-arm64", "macos-x64", "macos-arm64",
                                 "windows-x64", "windows-arm64"])
    parser.add_argument("--rgc-archive", required=True, type=Path)
    parser.add_argument("--rack-archive", required=True, type=Path)
    parser.add_argument("--out", type=Path, default=Path("dist"))
    parser.add_argument("--iscc", default=None, help="Path to Inno Setup ISCC.exe")
    args = parser.parse_args()

    os_name = args.platform.split("-", 1)[0]
    args.out.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="rgc-installer-") as tmp:
        work = Path(tmp)
        rgc_root = work / "rgc"
        rack_root = work / "rack"
        extract_tar_gz(args.rgc_archive, rgc_root)
        extract_tar_gz(args.rack_archive, rack_root)
        rgc_bin = find_binary(rgc_root, "rgc", os_name)
        rack_bin = find_binary(rack_root, "rack", os_name)
        lib_dir = find_lib(rgc_root)

        if os_name == "linux":
            path = build_deb(args.version, args.platform, rgc_bin, lib_dir,
                             rack_bin, args.out, work)
        elif os_name == "macos":
            path = build_pkg(args.version, args.platform, rgc_bin, lib_dir,
                             rack_bin, args.out, work)
        else:
            path = build_exe(args.version, args.platform, rgc_bin, lib_dir,
                             rack_bin, args.out, work, args.iscc)

    print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
