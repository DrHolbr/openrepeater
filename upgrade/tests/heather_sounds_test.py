#!/usr/bin/env python3
"""Fixture checks for the Heather installer. The official archive is not required."""

import importlib.util
import os
import stat
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "upgrade" / "install_heather_sounds.py"
PIN = ROOT / "upgrade" / "share" / "heather-16k-25.05.sha256"
OFFICIAL = "e79e61bec17a24fad093edfb21e7f8ca51af33b9590db954b4789271db2957dd"

spec = importlib.util.spec_from_file_location("heather", SCRIPT)
heather = importlib.util.module_from_spec(spec)
spec.loader.exec_module(heather)


def check(condition, label):
    if not condition:
        raise SystemExit("FAIL: " + label)
    print("ok: " + label)


def write_archive(path, entries):
    with tarfile.open(path, "w:bz2") as tar:
        for entry in entries:
            info = tarfile.TarInfo(entry["name"])
            kind = entry["kind"]
            if kind == "dir":
                info.type = tarfile.DIRTYPE
                info.mode = 0o755
                tar.addfile(info)
            elif kind == "reg":
                data = entry["data"]
                info.type = tarfile.REGTYPE
                info.size = len(data)
                info.mode = 0o644
                import io
                tar.addfile(info, io.BytesIO(data))
            elif kind == "sym":
                info.type = tarfile.SYMTYPE
                info.linkname = entry["target"]
                tar.addfile(info)
            elif kind == "lnk":
                info.type = tarfile.LNKTYPE
                info.linkname = entry["target"]
                tar.addfile(info)
            elif kind == "chr":
                info.type = tarfile.CHRTYPE
                tar.addfile(info)
            else:
                raise SystemExit("bad fixture kind")


def run_install(archive, dest_root, pin_text):
    pin_path = dest_root / "pin"
    pin_path.write_text(pin_text + "\n")
    os.environ["ORP_SOUNDS_TEST_HARNESS"] = "1"
    os.environ["ORP_SOUNDS_PIN"] = str(pin_path)
    os.environ["ORP_ROOT"] = str(dest_root)
    digest = __import__("hashlib").sha256(archive.read_bytes()).hexdigest()
    try:
        heather.install(str(archive), str(dest_root / "usr/local/share/svxlink/sounds/en_US"), str(pin_path), True)
        return 0, digest
    except heather.Refuse as exc:
        return 2, str(exc)


def main():
    pin_line = ""
    for line in PIN.read_text().splitlines():
        if line.strip() and not line.strip().startswith("#"):
            pin_line = line.strip()
            break
    check(pin_line == OFFICIAL, "pinned digest is the verified 25.05 asset digest")

    tmp = Path(tempfile.mkdtemp(prefix="orp-heather-test."))
    good = tmp / "good.tar.bz2"
    payload = b"RIFF-fixture-clip"
    write_archive(good, [
        {"name": "en_US-heather-16k", "kind": "dir"},
        {"name": "en_US-heather-16k/Core", "kind": "dir"},
        {"name": "en_US-heather-16k/EchoLink", "kind": "dir"},
        {"name": "en_US-heather-16k/Core/repeater.wav", "kind": "reg", "data": payload},
        {"name": "en_US-heather-16k/EchoLink/repeater.wav", "kind": "sym", "target": "../Core/repeater.wav"},
    ])
    digest = __import__("hashlib").sha256(good.read_bytes()).hexdigest()
    dest_root = tmp / "root1"
    dest_root.mkdir()
    code, _detail = run_install(good, dest_root, digest)
    check(code == 0, "internal alias archive is accepted")
    sound = dest_root / "usr/local/share/svxlink/sounds/en_US"
    core = sound / "Core" / "repeater.wav"
    alias = sound / "EchoLink" / "repeater.wav"
    check(core.is_file() and not core.is_symlink(), "core clip is a regular file")
    check(alias.is_file() and not alias.is_symlink(), "alias clip was materialized as a regular file")
    check(core.read_bytes() == payload and alias.read_bytes() == payload, "materialized alias matches the target bytes")
    check(not sound.name.endswith("heather-16k"), "install does not nest the archive root name")
    check(stat.S_IMODE(core.stat().st_mode) == 0o644, "clip mode is 0644")
    check(stat.S_IMODE((sound / "Core").stat().st_mode) == 0o755, "directory mode is 0755")
    code, _detail = run_install(good, dest_root, digest)
    check(code == 0, "second install succeeds")
    backups = list((dest_root / "usr/local/share/svxlink/sounds").glob("en_US.bak.*"))
    check(len(backups) == 1 and (backups[0] / "Core" / "repeater.wav").read_bytes() == payload, "previous tree is kept as a backup")
    check(alias.read_bytes() == payload and not alias.is_symlink(), "second install is still regular files")

    def expect_refuse(label, entries):
        archive = tmp / (label.replace(" ", "_") + ".tar.bz2")
        write_archive(archive, entries)
        root = tmp / label.replace(" ", "_")
        root.mkdir()
        code, detail = run_install(archive, root, __import__("hashlib").sha256(archive.read_bytes()).hexdigest())
        installed = root / "usr/local/share/svxlink/sounds/en_US"
        check(code == 2 and not installed.exists(), label + " (" + detail + ")")

    base = [
        {"name": "en_US-heather-16k", "kind": "dir"},
        {"name": "en_US-heather-16k/Core", "kind": "dir"},
        {"name": "en_US-heather-16k/Core/repeater.wav", "kind": "reg", "data": payload},
    ]
    expect_refuse("absolute symlink is refused", base + [
        {"name": "en_US-heather-16k/EchoLink", "kind": "dir"},
        {"name": "en_US-heather-16k/EchoLink/repeater.wav", "kind": "sym", "target": "/etc/passwd"},
    ])
    expect_refuse("escaping symlink is refused", base + [
        {"name": "en_US-heather-16k/EchoLink", "kind": "dir"},
        {"name": "en_US-heather-16k/EchoLink/repeater.wav", "kind": "sym", "target": "../../outside.wav"},
    ])
    expect_refuse("dangling symlink is refused", base + [
        {"name": "en_US-heather-16k/missing.wav", "kind": "sym", "target": "no-such.wav"},
    ])
    expect_refuse("symlink cycle is refused", [
        {"name": "en_US-heather-16k", "kind": "dir"},
        {"name": "en_US-heather-16k/a.wav", "kind": "sym", "target": "b.wav"},
        {"name": "en_US-heather-16k/b.wav", "kind": "sym", "target": "a.wav"},
    ])
    expect_refuse("hardlink is refused", base + [
        {"name": "en_US-heather-16k/Core/again.wav", "kind": "lnk", "target": "en_US-heather-16k/Core/repeater.wav"},
    ])
    expect_refuse("device member is refused", base + [
        {"name": "en_US-heather-16k/Core/device", "kind": "chr"},
    ])
    expect_refuse("member traversal is refused", base + [
        {"name": "../escape.txt", "kind": "reg", "data": b"nope"},
    ])
    expect_refuse("symlink to a directory is refused", base + [
        {"name": "en_US-heather-16k/aliasdir", "kind": "sym", "target": "Core"},
    ])
    wrong = tmp / "wrong-root"
    wrong.mkdir()
    code, detail = run_install(good, wrong, "0" * 64)
    check(code == 2 and "does not match" in detail, "a digest mismatch writes nothing")
    link = tmp / "archive-link"
    link.symlink_to(good)
    os.environ["ORP_SOUNDS_PIN"] = str(tmp / "unused-pin")
    try:
        heather.install(str(link), str(tmp / "nope"), str(PIN), True)
        raise SystemExit("FAIL: symlink archive was accepted")
    except heather.Refuse as exc:
        check("not a regular file" in str(exc), "a symlinked archive is refused")
    print("heather sound installer checks passed")


if __name__ == "__main__":
    main()
