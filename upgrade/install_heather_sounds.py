#!/usr/bin/env python3
"""Install the pinned Heather 25.05 English clips as regular files.

The archive root is en_US-heather-16k. SvxLink looks up sounds/en_US, so the
install copies that root's children into en_US and does not nest another
directory. Symlinks that resolve to a regular file inside the archive are
copied as new regular files. The installed tree contains no symlinks.

The digest is checked before any destination write. Archive ownership and
mode bits are not applied. This does not download the archive and does not
prove that a clip is spoken by SvxLink 26.05.
"""

import hashlib
import os
import posixpath
import shutil
import stat
import sys
import tarfile
import tempfile
from datetime import datetime, timezone

ROOT_NAME = "en_US-heather-16k"
OFFICIAL_SHA256 = "e79e61bec17a24fad093edfb21e7f8ca51af33b9590db954b4789271db2957dd"
OFFICIAL_SIZE = 14324550
MAX_LINK_HOPS = 8


class Refuse(Exception):
    pass


def refuse(message):
    raise Refuse(message)


def pin_digest(path):
    text = ""
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                text = stripped
                break
    if not text or text == "UNVERIFIED":
        refuse("Heather archive digest is not pinned. Nothing was extracted.")
    if len(text) != 64 or any(ch not in "0123456789abcdef" for ch in text):
        refuse("pinned digest is not 64 hex characters. Nothing was extracted.")
    return text


def ancestors_are_real(path):
    acc = ""
    rest = path[1:] if path.startswith("/") else path
    while rest:
        part, sep, rest = rest.partition("/")
        if not part:
            continue
        acc = acc + "/" + part
        if rest and os.path.islink(acc):
            refuse("symbolic link in the archive path at %s. Nothing was extracted." % acc)


def member_parts(name):
    if not name or name.startswith("/") or "\\" in name:
        refuse("archive member %s escapes the sound root. Nothing was extracted." % name)
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts):
        refuse("archive member %s escapes the sound root. Nothing was extracted." % name)
    if parts[0] != ROOT_NAME:
        refuse("archive root is %s, expected %s. Nothing was extracted." % (parts[0], ROOT_NAME))
    return parts


def resolve_link(name, linkname, by_name, seen):
    if not linkname or linkname.startswith("/") or "\\" in linkname:
        refuse("symlink %s has a non-relative target. Nothing was extracted." % name)
    if name in seen:
        refuse("symlink cycle at %s. Nothing was extracted." % name)
    seen.add(name)
    joined = posixpath.normpath(posixpath.join(posixpath.dirname(name), linkname))
    if joined != ROOT_NAME and not joined.startswith(ROOT_NAME + "/"):
        refuse("symlink %s escapes the sound root. Nothing was extracted." % name)
    info = by_name.get(joined)
    if info is None:
        refuse("symlink %s is dangling. Nothing was extracted." % name)
    if info.isdir():
        refuse("symlink %s names a directory. Nothing was extracted." % name)
    if info.issym():
        if len(seen) > MAX_LINK_HOPS:
            refuse("symlink %s is too deep. Nothing was extracted." % name)
        return resolve_link(joined, info.linkname, by_name, seen)
    if not info.isreg():
        refuse("symlink %s does not name a regular file. Nothing was extracted." % name)
    return info


def validate_members(members):
    by_name = {}
    for info in members:
        name = info.name
        if name in by_name:
            refuse("duplicate archive member %s. Nothing was extracted." % name)
        member_parts(name)
        if info.islnk() or info.ischr() or info.isblk() or info.isfifo() or info.isdev():
            refuse("archive member %s is not a directory, file, or symlink. Nothing was extracted." % name)
        if not (info.isdir() or info.isreg() or info.issym()):
            refuse("archive member %s has an unsupported type. Nothing was extracted." % name)
        by_name[name] = info
    if ROOT_NAME not in by_name or not by_name[ROOT_NAME].isdir():
        refuse("archive does not contain the %s directory. Nothing was extracted." % ROOT_NAME)
    resolved = {}
    for info in members:
        if info.issym():
            resolved[info.name] = resolve_link(info.name, info.linkname, by_name, set())
    return by_name, resolved


def write_tree(archive, members, resolved, stage_root):
    ordered = sorted(members, key=lambda item: (item.name.count("/"), item.name))
    for info in ordered:
        rel = info.name[len(ROOT_NAME):].lstrip("/")
        dest = stage_root if rel == "" else os.path.join(stage_root, rel)
        if os.path.islink(dest):
            refuse("staging path became a symlink at %s. Nothing was installed." % dest)
        if info.isdir():
            if dest != stage_root:
                os.mkdir(dest, 0o755)
            continue
        if info.issym():
            target = resolved[info.name]
            source = archive.extractfile(target)
            if source is None:
                refuse("regular file %s could not be read. Nothing was installed." % target.name)
            with open(dest, "wb") as handle:
                shutil.copyfileobj(source, handle)
            os.chmod(dest, 0o644)
            continue
        source = archive.extractfile(info)
        if source is None:
            refuse("regular file %s could not be read. Nothing was installed." % info.name)
        with open(dest, "wb") as handle:
            shutil.copyfileobj(source, handle)
        os.chmod(dest, 0o644)


def install(archive_path, dest, pin_file, harness):
    if not harness and os.geteuid() != 0:
        refuse("sound installation runs as root")
    if not archive_path or not archive_path.startswith("/"):
        refuse("archive path is not absolute. Nothing was extracted.")
    if os.path.islink(archive_path) or not os.path.isfile(archive_path):
        refuse("archive is not a regular file. Nothing was extracted.")
    ancestors_are_real(archive_path)
    pinned = pin_digest(pin_file)
    digest = hashlib.sha256()
    size = 0
    with open(archive_path, "rb") as handle:
        while True:
            block = handle.read(1024 * 1024)
            if not block:
                break
            size += len(block)
            digest.update(block)
    actual = digest.hexdigest()
    if actual != pinned:
        refuse("archive digest does not match the pin. Nothing was extracted.")
    if pinned == OFFICIAL_SHA256 and size != OFFICIAL_SIZE:
        refuse("official archive size is %s bytes, expected %s. Nothing was extracted." % (size, OFFICIAL_SIZE))
    with tarfile.open(archive_path, "r:bz2") as archive:
        members = [info for info in archive.getmembers()]
        _by_name, resolved = validate_members(members)
        stage = tempfile.mkdtemp(prefix="orp-heather.")
        try:
            os.chmod(stage, 0o755)
            write_tree(archive, members, resolved, stage)
        except Exception:
            shutil.rmtree(stage, ignore_errors=True)
            raise
    if os.path.islink(dest):
        shutil.rmtree(stage, ignore_errors=True)
        refuse("sounds destination is a symbolic link. Nothing was installed.")
    parent = os.path.dirname(dest)
    acc = ""
    for part in parent.split("/")[1:]:
        acc = acc + "/" + part
        if os.path.islink(acc):
            shutil.rmtree(stage, ignore_errors=True)
            refuse("symbolic link in the sounds path at %s. Nothing was installed." % acc)
        if not os.path.isdir(acc):
            os.mkdir(acc, 0o755)
    if os.path.lexists(dest):
        if not os.path.isdir(dest) or os.path.islink(dest):
            shutil.rmtree(stage, ignore_errors=True)
            refuse("sounds destination is not a real directory. Nothing was installed.")
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = os.path.join(parent, "en_US.bak." + stamp)
        os.rename(dest, backup)
    os.rename(stage, dest)
    for dirpath, dirnames, filenames in os.walk(dest):
        os.chmod(dirpath, 0o755)
        for filename in filenames:
            path = os.path.join(dirpath, filename)
            if os.path.islink(path):
                refuse("installed sounds contain a symbolic link at %s." % path)
            os.chmod(path, 0o644)
    if not harness:
        for dirpath, dirnames, filenames in os.walk(dest):
            os.chown(dirpath, 0, 0)
            for filename in filenames:
                os.chown(os.path.join(dirpath, filename), 0, 0)
    return dest


def main(argv):
    script_dir = os.path.dirname(os.path.abspath(__file__))
    pin_file = os.environ.get("ORP_SOUNDS_PIN", os.path.join(script_dir, "share", "heather-16k-25.05.sha256"))
    archive = argv[1] if len(argv) > 1 else os.environ.get("ORP_SOUNDS_ARCHIVE", "")
    root = os.environ.get("ORP_ROOT", "").rstrip("/")
    dest = root + "/usr/local/share/svxlink/sounds/en_US"
    harness = os.environ.get("ORP_SOUNDS_TEST_HARNESS", "0") == "1"
    try:
        installed = install(archive, dest, pin_file, harness)
    except Refuse as exc:
        print("refused: %s" % exc, file=sys.stderr)
        return 2
    except tarfile.TarError as exc:
        print("refused: archive could not be read (%s). Nothing was extracted." % exc, file=sys.stderr)
        return 2
    print("installed %s" % installed)
    print("materialized=regular-files")
    print("symlinks=0")
    print("source=https://github.com/sm0svx/svxlink-sounds-en_US-heather/releases/download/25.05/svxlink-sounds-en_US-heather-16k-25.05.tar.bz2")
    print("compatibility=25.05 selected for 26.05 because no 26.05 speech pack was published; runtime playback is unverified")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
