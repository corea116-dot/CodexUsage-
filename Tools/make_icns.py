#!/usr/bin/env python3

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
from pathlib import Path


REPRESENTATIONS = (
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
)


def make_icns(source: Path, destination: Path) -> None:
    chunks: list[bytes] = []
    with tempfile.TemporaryDirectory(prefix="codex-usage-icon-") as temporary_directory:
        temporary_path = Path(temporary_directory)
        for chunk_type, pixel_size in REPRESENTATIONS:
            png_path = temporary_path / f"{pixel_size}.png"
            subprocess.run(
                ["sips", "-z", str(pixel_size), str(pixel_size), str(source), "--out", str(png_path)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            png_data = png_path.read_bytes()
            if not png_data.startswith(b"\x89PNG\r\n\x1a\n"):
                raise ValueError(f"{png_path} is not a PNG")
            chunks.append(chunk_type.encode("ascii") + struct.pack(">I", len(png_data) + 8) + png_data)

    contents = b"".join(chunks)
    destination.write_bytes(b"icns" + struct.pack(">I", len(contents) + 8) + contents)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: make_icns.py SOURCE_PNG DESTINATION_ICNS")
    make_icns(Path(sys.argv[1]), Path(sys.argv[2]))
