#!/usr/bin/env python3
"""Split an Android Motion Photo into its still container and trailing video.

The splitter understands JPEG/Ultra HDR and HEIC/HEIF based Motion Photos. It
prefers the lengths declared by the Google Motion Photo XMP container and falls
back to locating a valid trailing ISO-BMFF ``ftyp`` box. The still bytes are
copied verbatim: JPEG MPF/ISO gain-map data and HEIF auxiliary images are not
decoded, rewritten, or discarded here.

The output still is intentionally not turned into a Live Photo by this tool.
Pass it to ``mkstill`` to add Apple's MakerNote identifier, and pass the video
to ``mkmov`` to add the matching QuickTime identifier.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import struct
import sys
import uuid as uuidlib


VIDEO_SEMANTICS = {"motionphoto", "microvideo"}
VIDEO_MIMES = {"video/mp4", "video/quicktime"}


def _xmp_packets(data: bytes):
    """Yield UTF-8 XMP packets found in JPEG APP1 or HEIF metadata payloads."""
    start = 0
    while True:
        a = data.find(b"<x:xmpmeta", start)
        if a < 0:
            return
        b = data.find(b"</x:xmpmeta>", a)
        if b < 0:
            return
        b += len(b"</x:xmpmeta>")
        yield data[a:b].decode("utf-8", "replace")
        start = b


def _attrs(fragment: str) -> dict[str, str]:
    return dict(re.findall(r"([A-Za-z][\w.-]*:[\w.-]+)=['\"]([^'\"]*)['\"]", fragment))


def motion_video_length_from_xmp(data: bytes) -> int | None:
    """Return the declared trailing video length, preferring Container:Item."""
    fallbacks: list[int] = []
    for xmp in _xmp_packets(data):
        for item in re.findall(r"<Container:Item\b[^>]*>", xmp, re.I | re.S):
            attrs = _attrs(item)
            semantic = attrs.get("Item:Semantic", "").lower()
            mime = attrs.get("Item:Mime", "").lower()
            length = attrs.get("Item:Length")
            if length and (semantic in VIDEO_SEMANTICS or mime in VIDEO_MIMES):
                value = int(length)
                if value > 0:
                    return value

        for pattern in (
            r"GCamera:MicroVideoOffset=['\"](\d+)['\"]",
            r"GCamera:MotionPhotoVideoLength=['\"](\d+)['\"]",
            r"OpCamera:VideoLength=['\"](\d+)['\"]",
        ):
            match = re.search(pattern, xmp)
            if match and int(match.group(1)) > 0:
                fallbacks.append(int(match.group(1)))
    return fallbacks[0] if fallbacks else None


def image_kind(data: bytes) -> str:
    if data.startswith(b"\xff\xd8"):
        return "jpeg"
    if len(data) >= 12 and data[4:8] == b"ftyp":
        brands = data[8:40]
        if any(brand in brands for brand in
               (b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1", b"avif")):
            return "heif"
    raise ValueError("input is neither a JPEG nor a supported HEIC/HEIF Motion Photo")


def _box_size(data: bytes, offset: int) -> tuple[int, int] | None:
    if offset < 0 or offset + 8 > len(data):
        return None
    size = struct.unpack_from(">I", data, offset)[0]
    header = 8
    if size == 1:
        if offset + 16 > len(data):
            return None
        size = struct.unpack_from(">Q", data, offset + 8)[0]
        header = 16
    elif size == 0:
        size = len(data) - offset
    if size < header or offset + size > len(data):
        return None
    return size, header


def looks_like_video_bmff(data: bytes, offset: int) -> bool:
    """Conservatively validate a candidate MP4/QuickTime top-level box chain."""
    info = _box_size(data, offset)
    if not info or data[offset + 4:offset + 8] != b"ftyp":
        return False
    size, _ = info
    brands = data[offset + 8:offset + min(size, 64)]
    image_brands = (b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1", b"avif")
    if any(brand in brands for brand in image_brands):
        return False

    cursor = offset
    found = set()
    # A normal motion clip exposes moov/mdat near the top level. Limit the scan
    # to avoid interpreting an ftyp byte sequence inside encoded media payload.
    for _ in range(32):
        info = _box_size(data, cursor)
        if not info:
            return False
        box_size, _ = info
        found.add(data[cursor + 4:cursor + 8])
        if b"moov" in found and b"mdat" in found:
            return True
        cursor += box_size
        if cursor >= len(data) or cursor - offset > 16 * 1024 * 1024:
            break
    return b"moov" in found and b"mdat" in found


def scan_video_offset(data: bytes, start: int) -> int | None:
    cursor = max(0, start)
    while True:
        type_at = data.find(b"ftyp", cursor)
        if type_at < 0:
            return None
        candidate = type_at - 4
        if candidate >= start and looks_like_video_bmff(data, candidate):
            return candidate
        cursor = type_at + 4


def detect_video_range(data: bytes, kind: str, explicit_offset: int | None,
                       explicit_length: int | None) -> tuple[int, int, str]:
    if explicit_offset is not None:
        offset = explicit_offset
        method = "explicit --primary"
    else:
        declared = explicit_length or motion_video_length_from_xmp(data)
        offset = len(data) - declared if declared else None
        method = "XMP trailing video length" if declared else "ISO-BMFF scan"
        if offset is not None and not looks_like_video_bmff(data, offset):
            # Vendor fallback fields are occasionally the size of only one
            # sub-clip. Prefer a structurally valid MP4 boundary in that case.
            offset = None
        if offset is None:
            # HEIF starts with its own ftyp at zero, so skip that first box.
            offset = scan_video_offset(data, 2 if kind == "jpeg" else 8)
            method = "ISO-BMFF scan"

    if offset is None or not (0 < offset < len(data)):
        raise ValueError("cannot determine where the trailing video starts; pass --primary N")
    if not looks_like_video_bmff(data, offset):
        raise ValueError(f"byte offset {offset} is not a valid MP4/QuickTime boundary")

    length = explicit_length or (len(data) - offset)
    if length <= 0 or offset + length > len(data):
        raise ValueError("invalid video length")
    # Motion Photo video is conventionally the final item. Preserve all bytes
    # if a stale vendor fallback length undershoots it.
    if offset + length != len(data):
        length = len(data) - offset
    return offset, length, method


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".tmp")
    temp.write_bytes(data)
    os.replace(temp, path)


def main() -> None:
    parser = argparse.ArgumentParser(description="Split JPEG/HEIC Motion Photo still and video data.")
    parser.add_argument("src", help="Motion Photo file")
    parser.add_argument("out", help="verbatim still output (.jpg/.heic)")
    parser.add_argument("--video-out", help="write the extracted MP4/MOV here")
    parser.add_argument("--primary", type=int, help="explicit byte offset where video starts")
    parser.add_argument("--video-length", type=int, help="explicit trailing video length")
    parser.add_argument("--uuid", help="pairing identifier (default: random UUID v4)")
    parser.add_argument("--id-file", help="also write the chosen identifier here")
    args = parser.parse_args()

    src = Path(args.src)
    data = src.read_bytes()
    try:
        kind = image_kind(data)
        offset, length, method = detect_video_range(data, kind, args.primary, args.video_length)
    except ValueError as error:
        sys.exit(f"error: {error}")

    cid = (args.uuid or str(uuidlib.uuid4())).upper()
    still = data[:offset]
    video = data[offset:offset + length]
    atomic_write(Path(args.out), still)
    if args.video_out:
        atomic_write(Path(args.video_out), video)
    if args.id_file:
        atomic_write(Path(args.id_file), (cid + "\n").encode("ascii"))

    print(f"source            : {src} ({len(data)} bytes, {kind})")
    print(f"video detection   : {method}")
    print(f"video offset      : {offset}")
    print(f"video length      : {length}")
    print(f"ContentIdentifier : {cid}")
    print(f"wrote still       : {args.out} ({len(still)} bytes, byte-exact prefix)")
    if args.video_out:
        print(f"wrote video       : {args.video_out} ({len(video)} bytes)")


if __name__ == "__main__":
    main()
