#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import io
import zipfile
from pathlib import Path


PACKAGES = (
    ("quarantine-pypi-alpha", "quarantine_pypi_alpha", "alpha"),
    ("quarantine-pypi-beta", "quarantine_pypi_beta", "beta"),
)
VERSION = "1.0.0"


def hash_record(path: str, contents: bytes) -> tuple[str, str, str]:
    digest = hashlib.sha256(contents).digest()
    encoded = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return path, f"sha256={encoded}", str(len(contents))


def build_wheel(source_root: Path, output_root: Path, distribution: str, package: str) -> Path:
    dist_info = f"{package}-{VERSION}.dist-info"
    wheel_name = f"{package}-{VERSION}-py3-none-any.whl"
    wheel_path = output_root / wheel_name
    marker = source_root / package / "__init__.py"

    metadata = (
        "Metadata-Version: 2.1\n"
        f"Name: {distribution}\n"
        f"Version: {VERSION}\n"
        "Summary: Harmless local package for the Nexus quarantine POC\n"
        "Requires-Python: >=3.8\n"
        "\n"
    ).encode("utf-8")
    wheel = (
        "Wheel-Version: 1.0\n"
        "Generator: nexus-quarantine-poc\n"
        "Root-Is-Purelib: true\n"
        "Tag: py3-none-any\n"
        "\n"
    ).encode("utf-8")

    entries: list[tuple[str, bytes]] = [
        (f"{package}/__init__.py", marker.read_bytes()),
        (f"{dist_info}/METADATA", metadata),
        (f"{dist_info}/WHEEL", wheel),
    ]
    records = [hash_record(path, contents) for path, contents in entries]
    records.append((f"{dist_info}/RECORD", "", ""))
    record_buffer = io.StringIO(newline="")
    writer = csv.writer(record_buffer, lineterminator="\n")
    writer.writerows(records)
    entries.append((f"{dist_info}/RECORD", record_buffer.getvalue().encode("utf-8")))

    with zipfile.ZipFile(wheel_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path, contents in entries:
            info = zipfile.ZipInfo(path, (2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, contents)

    return wheel_path


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Build dependency-free wheels for the Nexus quarantine POC."
    )
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    arguments.output.mkdir(parents=True, exist_ok=True)
    source_root = arguments.repository_root / "samples" / "pypi"

    for distribution, package, _ in PACKAGES:
        wheel = build_wheel(source_root, arguments.output, distribution, package)
        print(wheel)


if __name__ == "__main__":
    main()
