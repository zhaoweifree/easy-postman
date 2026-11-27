#!/usr/bin/env python3
"""Repack a .deb archive so its control/data members use a dpkg-compatible
compressor (xz by default, gzip for very old dpkg).

Why this exists:
  On Ubuntu 24.04+ (dpkg >= 1.21.18) `dpkg-deb --build` defaults to zstd, and
  `jpackage --type deb` inherits that. Older dpkg releases (Debian 11, Ubuntu
  20.04, openEuler, UOS/Kylin, ...) then fail with:

      dpkg-deb: error: archive ... uses unknown compression for member
      'control.tar.zst', giving up

  xz is understood by every dpkg since 1.17 (2013), so normalizing to xz is
  enough. The tar payload is decompressed and recompressed byte-for-byte, so
  file metadata and the md5sums member stay untouched.

Usage:
  python build/deb-repack.py in.deb                 # -> xz, in place
  python build/deb-repack.py in.deb -o out.deb      # -> xz, new file
  python build/deb-repack.py in.deb --compression gzip

Requires nothing but the standard library except when the input uses zstd:
install `zstandard` (pip install zstandard) or let the script fall back to a
`zstd` executable on PATH.
"""

from __future__ import annotations

import argparse
import gzip
import io
import lzma
import os
import shutil
import subprocess
import sys
import tarfile


AR_MAGIC = b"!<arch>\n"
HEADER_SIZE = 60


class Member:
    __slots__ = ("name", "mtime", "uid", "gid", "mode", "data")

    def __init__(self, name: str, mtime: int, uid: int, gid: int, mode: int, data: bytes):
        self.name = name
        self.mtime = mtime
        self.uid = uid
        self.gid = gid
        self.mode = mode
        self.data = data


def read_ar(path: str) -> list[Member]:
    with open(path, "rb") as fh:
        blob = fh.read()
    if not blob.startswith(AR_MAGIC):
        raise SystemExit(f"{path}: not a deb/ar archive")
    pos = len(AR_MAGIC)
    members: list[Member] = []
    while pos + HEADER_SIZE <= len(blob):
        header = blob[pos : pos + HEADER_SIZE]
        pos += HEADER_SIZE
        if header[58:60] != b"`\n":
            raise SystemExit(f"{path}: bad ar member header at offset {pos - HEADER_SIZE}")
        raw_name = header[0:16].decode("ascii", "replace").strip()
        name = raw_name.rstrip("/")
        mtime = int(header[16:28].decode("ascii", "replace").strip() or "0")
        uid = int(header[28:34].decode("ascii", "replace").strip() or "0")
        gid = int(header[34:40].decode("ascii", "replace").strip() or "0")
        mode = int(header[40:48].decode("ascii", "replace").strip() or "100644", 8)
        size = int(header[48:58].decode("ascii", "replace").strip())
        data = blob[pos : pos + size]
        pos += size + (size % 2)  # members are 2-byte aligned
        members.append(Member(name, mtime, uid, gid, mode, data))
    return members


def write_ar(path: str, members: list[Member]) -> None:
    with open(path, "wb") as fh:
        fh.write(AR_MAGIC)
        for m in members:
            # dpkg-deb writes member names without the GNU "name/" suffix;
            # mirror that so old/alternative ar readers see the same layout.
            name_field = m.name.ljust(16)[:16]
            mode_field = f"{m.mode:o}".ljust(8)[:8]
            size_field = str(len(m.data)).ljust(10)[:10]
            header = (
                f"{name_field}{m.mtime:<12}{m.uid:<6}{m.gid:<6}{mode_field}{size_field}`\n"
            ).encode("ascii")
            assert len(header) == HEADER_SIZE, header
            fh.write(header)
            fh.write(m.data)
            if len(m.data) % 2:
                fh.write(b"\n")


def decompress(data: bytes, name: str) -> bytes:
    if name.endswith(".tar.xz"):
        return lzma.decompress(data)
    if name.endswith(".tar.gz"):
        return gzip.decompress(data)
    if name.endswith(".tar.zst"):
        return _decompress_zstd(data, name)
    if name.endswith(".tar.bz2"):
        return __import__("bz2").decompress(data)
    if name.endswith(".tar"):
        return data
    raise SystemExit(f"unsupported member compressor: {name}")


def _decompress_zstd(data: bytes, name: str) -> bytes:
    try:
        import zstandard  # type: ignore

        dctx = zstandard.ZstdDecompressor()
        try:
            return dctx.decompress(data)
        except zstandard.ZstdError:
            # frame header without content size (streamed) -> use streaming API
            return dctx.decompressobj().decompress(data)
    except ImportError:
        pass
    exe = shutil.which("zstd")
    if exe:
        return subprocess.run(
            [exe, "-d", "-q", "-c"], input=data, stdout=subprocess.PIPE, check=True
        ).stdout
    raise SystemExit(
        f"{name}: zstd payload needs the 'zstandard' module (pip install zstandard) "
        "or a zstd executable on PATH"
    )


def compress(payload: bytes, compression: str) -> tuple[str, bytes]:
    if compression == "xz":
        return ".tar.xz", lzma.compress(payload, format=lzma.FORMAT_XZ, preset=6)
    if compression == "gzip":
        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz:
            gz.write(payload)
        return ".tar.gz", buf.getvalue()
    raise SystemExit(f"unsupported target compression: {compression}")


def describe(payload: bytes) -> str:
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:") as tar:
        count = sum(1 for _ in tar)
    return f"{count} entries"


def repack(src: str, dst: str, compression: str) -> None:
    members = read_ar(src)
    names = [m.name for m in members]
    if "debian-binary" not in names:
        raise SystemExit(f"{src}: missing debian-binary member")

    out: list[Member] = []
    summary: list[str] = []
    for m in members:
        if not (m.name.startswith("control.tar.") or m.name.startswith("data.tar.")):
            out.append(m)
            continue
        stem = m.name.split(".tar.")[0]
        payload = decompress(m.data, m.name)
        suffix, packed = compress(payload, compression)
        new_name = f"{stem}{suffix}"
        summary.append(f"  {m.name} ({len(m.data) / 1048576:.1f} MB) -> {new_name} "
                       f"({len(packed) / 1048576:.1f} MB, {describe(payload)})")
        out.append(Member(new_name, m.mtime, m.uid, m.gid, m.mode, packed))

    # debian-binary must come first, then control.tar.*, then data.tar.*
    order = {"debian-binary": 0}
    ordered = sorted(out, key=lambda m: order.get(m.name, 1 if m.name.startswith("control.tar") else 2))

    write_ar(dst, ordered)
    print(f"re-packed {os.path.basename(src)} with {compression}:")
    print("\n".join(summary))


def verify(path: str) -> None:
    """Fail loudly if anything the broken dpkg cannot read is still inside."""
    members = read_ar(path)
    names = [m.name for m in members]
    bad = [n for n in names if n.endswith(".zst")]
    if bad:
        raise SystemExit(f"verification failed: still uses zstd member(s) {bad}")
    for m in members:
        if m.name.startswith("control.tar.") or m.name.startswith("data.tar."):
            payload = decompress(m.data, m.name)
            with tarfile.open(fileobj=io.BytesIO(payload), mode="r:") as tar:
                for _ in tar:
                    pass
    control = next(m for m in members if m.name.startswith("control.tar."))
    payload = decompress(control.data, control.name)
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:") as tar:
        info = tar.extractfile("./control") or tar.extractfile("control")
        fields = dict(
            line.split(": ", 1)
            for line in info.read().decode("utf-8", "replace").splitlines()
            if ": " in line
        )
    print(f"verified {os.path.basename(path)}: members={names} "
          f"package={fields.get('Package')} version={fields.get('Version')} "
          f"arch={fields.get('Architecture')}")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description="Normalize deb member compression for old dpkg")
    ap.add_argument("deb", help="input .deb")
    ap.add_argument("-o", "--output", help="output .deb (default: overwrite input)")
    ap.add_argument("-c", "--compression", choices=("xz", "gzip"), default="xz")
    ap.add_argument("--no-verify", action="store_true")
    args = ap.parse_args(argv)

    src = os.path.abspath(args.deb)
    if not os.path.isfile(src):
        raise SystemExit(f"not found: {src}")
    dst = os.path.abspath(args.output) if args.output else src
    tmp = dst + ".tmp" if dst == src else dst
    repack(src, tmp, args.compression)
    if not args.no_verify:
        verify(tmp)
    if tmp != dst:
        os.replace(tmp, dst)
    if dst == src:
        print(f"updated {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
