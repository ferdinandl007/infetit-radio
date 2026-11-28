#!/usr/bin/env python3
"""Install the optional SheetSage2 transcriber for VibePlayer on Apple silicon."""

import argparse
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from install_models import SUPPORT, download_repo

SOURCE = "https://github.com/hangry-labs/yue2.git"
SOURCE_REVISION = "bb064cfb3ab7856ddc884474fb1255f960756c1d"
WEIGHTS_REVISION = "c3868e507fff12d9a77bf3740cbe9e166211556f"
WEIGHTS = {
    "MERT-v2-FullSong-Q8_0.gguf": "35a6032ec7e8123c02becdefc7bfe10a3adb33faa8a1951dc0af864b4494b8ef",
    "SheetSage2-Q8_0.gguf": "95d8fa8761753b4833782a52b68d5c0afa3bd3cfbc03d3dcbbf8ded0c13f611e",
}


def install_transcriber(directory):
    binary = directory / "yue-transcribe"
    if binary.is_file() and binary.stat().st_mode & 0o111:
        return
    if shutil.which("cmake") is None:
        raise RuntimeError("Install CMake before building the melody tools.")
    with tempfile.TemporaryDirectory(prefix="vibeplayer-sheetsage-") as work:
        source = Path(work) / "source"
        build = Path(work) / "build"
        subprocess.run(["git", "init", "--quiet", str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "fetch", "--quiet", "--depth", "1", SOURCE, SOURCE_REVISION], check=True)
        subprocess.run(["git", "-C", str(source), "checkout", "--quiet", "--detach", "FETCH_HEAD"], check=True)
        # Avoid shadowing the C++ <version> header on case-insensitive volumes.
        (source / "VERSION").rename(source / "YUE2_VERSION")
        cmake = source / "CMakeLists.txt"
        cmake.write_text(cmake.read_text().replace('${CMAKE_SOURCE_DIR}/VERSION', '${CMAKE_SOURCE_DIR}/YUE2_VERSION'))
        subprocess.run(["cmake", "-S", str(source), "-B", str(build), "-DCMAKE_BUILD_TYPE=Release",
                        "-DBUILD_SHARED_LIBS=OFF", "-DGGML_METAL=ON", "-DGGML_METAL_EMBED_LIBRARY=ON"], check=True)
        subprocess.run(["cmake", "--build", str(build), "--target", "yue-transcribe", "--parallel", "6"], check=True)
        with tempfile.TemporaryDirectory(prefix=".vibeplayer-install-", dir=directory) as stage:
            installed = Path(stage) / binary.name
            shutil.copy2(build / binary.name, installed)
            installed.replace(binary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=SUPPORT / "YuE2NativeAssets/Reference")
    args = parser.parse_args()
    if (platform.system(), platform.machine()) != ("Darwin", "arm64"):
        parser.error("Run this command on an Apple silicon Mac.")
    args.directory.mkdir(parents=True, exist_ok=True)
    download_repo("botp/YuE2-GGUF", WEIGHTS_REVISION, WEIGHTS, args.directory)
    install_transcriber(args.directory)
    print(f"Melody tools installed in {args.directory}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"VibePlayer melody setup: {error}")
