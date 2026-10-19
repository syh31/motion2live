#!/usr/bin/env python3
"""One-command Android Motion Photo to Apple Live Photo conversion."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid


ROOT = Path(__file__).resolve().parent.parent
SPLITTER = ROOT / "tools" / "make_livephoto_still.py"
MKSTILL = ROOT / "bin" / "mkstill"
MKMOV = ROOT / "bin" / "mkmov"
VALIDATE = ROOT / "bin" / "validate"


def run(command: list[str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, check=True)


def input_suffix(path: Path) -> str:
    with path.open("rb") as stream:
        header = stream.read(16)
    if header.startswith(b"\xff\xd8"):
        return ".jpg"
    if len(header) >= 12 and header[4:8] == b"ftyp":
        return ".heic"
    raise SystemExit("error: input is not a JPEG/HEIC Motion Photo")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Convert a JPEG/HEIC Android Motion Photo to an Apple Live Photo pair.")
    parser.add_argument("src", help="source Motion Photo")
    parser.add_argument("out", help="output base path; writes OUT.HEIC/JPG and OUT.MOV")
    parser.add_argument("--still-format", choices=("heic", "jpeg"), default="heic")
    parser.add_argument("--hdr", choices=("auto", "preserve", "sdr"), default="auto")
    parser.add_argument("--uuid", dest="content_identifier")
    parser.add_argument("--date", help="override MOV date (ISO-8601, for example 2026-09-11T02:45:51Z)")
    parser.add_argument("--primary", type=int, help="explicit source byte offset where video starts")
    parser.add_argument("--video-length", type=int, help="explicit trailing video length")
    parser.add_argument("--force", action="store_true", help="replace existing output files")
    parser.add_argument("--no-validate", action="store_true", help="skip the final structural validation")
    args = parser.parse_args()

    source = Path(args.src).expanduser().resolve()
    if not source.is_file():
        raise SystemExit(f"error: source does not exist: {source}")
    missing = [str(tool) for tool in (MKSTILL, MKMOV, VALIDATE) if not tool.is_file()]
    if missing:
        raise SystemExit("error: compiled tools are missing; run ./build.sh first\n  " + "\n  ".join(missing))

    base = Path(args.out).expanduser().resolve()
    if base.suffix.lower() in (".heic", ".heif", ".jpg", ".jpeg", ".mov"):
        base = base.with_suffix("")
    still_extension = ".HEIC" if args.still_format == "heic" else ".JPG"
    final_still = base.with_suffix(still_extension)
    final_movie = base.with_suffix(".MOV")
    for output in (final_still, final_movie):
        if output.exists() and not args.force:
            raise SystemExit(f"error: output exists: {output} (use --force to replace it)")
    final_still.parent.mkdir(parents=True, exist_ok=True)

    cid = (args.content_identifier or str(uuid.uuid4())).upper()
    try:
        with tempfile.TemporaryDirectory(prefix=".motion2live-", dir=final_still.parent) as temp_name:
            temp = Path(temp_name)
            raw_still = temp / ("source" + input_suffix(source))
            raw_movie = temp / "source.mp4"
            staged_still = temp / final_still.name
            staged_movie = temp / final_movie.name

            split_command = [
                sys.executable, str(SPLITTER), str(source), str(raw_still),
                "--video-out", str(raw_movie), "--uuid", cid,
            ]
            if args.primary is not None:
                split_command += ["--primary", str(args.primary)]
            if args.video_length is not None:
                split_command += ["--video-length", str(args.video_length)]
            run(split_command)

            run([
                str(MKSTILL), str(raw_still), str(staged_still), cid,
                args.still_format, "--hdr", args.hdr,
            ])
            movie_command = [str(MKMOV), str(raw_movie), str(staged_movie), cid]
            if args.date:
                movie_command += ["--date", args.date]
            run(movie_command)
            if not args.no_validate:
                run([str(VALIDATE), str(staged_still), str(staged_movie)])

            os.replace(staged_still, final_still)
            os.replace(staged_movie, final_movie)
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"error: conversion command failed with status {error.returncode}") from error

    print("\nLive Photo pair created:")
    print(f"  still : {final_still}")
    print(f"  movie : {final_movie}")
    print(f"  id    : {cid}")


if __name__ == "__main__":
    main()
