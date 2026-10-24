#!/usr/bin/env python3
"""Create or verify deterministic transfer fixtures; never build or publish a release."""
import argparse
import gzip
import hashlib
import io
from pathlib import Path
import tarfile
import zipfile


def fixture_files():
    """Mirror the release upload's file types without containing a usable CLI."""
    content = "Artifact transfer fixture only. Not an installable release.\n中文\n".encode()
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w", format=tarfile.USTAR_FORMAT) as archive:
        info = tarfile.TarInfo("iphone-use/README.txt")
        info.size = len(content)
        info.mode = 0o644
        archive.addfile(info, io.BytesIO(content))
    gzip_buffer = io.BytesIO()
    with gzip.GzipFile(fileobj=gzip_buffer, mode="wb", filename="", mtime=0) as archive:
        archive.write(tar_buffer.getvalue())
    zip_buffer = io.BytesIO()
    with zipfile.ZipFile(zip_buffer, "w", compression=zipfile.ZIP_STORED) as archive:
        info = zipfile.ZipInfo("iphone-use/README.txt", (1980, 1, 1, 0, 0, 0))
        info.external_attr = 0o100644 << 16
        archive.writestr(info, content)
    files = {
        "iphone-use-0.0.0-transfer-macos-arm64.tar.gz": gzip_buffer.getvalue(),
        "iphone-use-plugin-0.0.0-transfer.zip": zip_buffer.getvalue(),
        "iphone-use.rb": b"# Transfer fixture only; not an installable formula.\n",
    }
    for name, data in list(files.items()):
        if name.endswith((".tar.gz", ".zip")):
            files[name + ".sha256"] = f"{hashlib.sha256(data).hexdigest()}  {name}\n".encode()
    return files


def prepare(directory):
    # Refuse old contents so an incomplete creation cannot reuse a previous result.
    directory.mkdir(parents=True, exist_ok=False)
    for name, data in fixture_files().items():
        (directory / name).write_bytes(data)


def verify(directory):
    expected = fixture_files()
    if not directory.is_dir() or directory.is_symlink():
        raise ValueError("Missing or invalid downloaded artifact directory")
    actual = {path.name for path in directory.iterdir()}
    if actual != set(expected):
        raise ValueError(f"Artifact inventory differs: missing={sorted(set(expected) - actual)}, "
                         f"unexpected={sorted(actual - set(expected))}")
    for name, data in expected.items():
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Artifact is not a regular file: {name}")
        if hashlib.sha256(path.read_bytes()).digest() != hashlib.sha256(data).digest():
            raise ValueError(f"Artifact digest differs: {name}")
    print(f"Artifact transfer passed: {len(expected)} files, exact layout and SHA-256; no release published.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "verify"))
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    {"prepare": prepare, "verify": verify}[args.operation](args.directory)


if __name__ == "__main__":
    main()
