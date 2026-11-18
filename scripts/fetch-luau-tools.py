"""Download the pinned Luau tools the type and native-code tests run into .luau-tools/."""

import hashlib
import io
from pathlib import Path
import platform
import sys
import tempfile
import urllib.request
import zipfile


LUAU_VERSION = "0.743"
LUAU_LSP_VERSION = "1.68.0"

LUAU_ASSETS = {
    "Linux": ("luau-ubuntu.zip", "99d45afb4afaee00ba631c526c8e8c76c67b60f6f119953ce6409be6d6953663"),
    "Darwin": ("luau-macos.zip", "4334afbfb0c05ee697c9bfea64a85f950249c1e8f6f7d99aaa5a24ee362b09c3"),
}
LUAU_LSP_ASSETS = {
    "Linux": ("luau-lsp-linux-x86_64.zip", "b86d4ecf28cf8356a8f8c8e0826ce0e43607847a4cfad3ef34e170dee76103a8"),
    "Darwin": ("luau-lsp-macos.zip", "fff45d60ec5e020d4ec7bfbe6132c3b834f092cd8faafa68e786197f0fb8bfdb"),
}
GLOBAL_TYPES_SHA256 = "66c27c8ee220ee480d6794089c8a721956d34fe3bddc877cbf603f4bea6d4c75"

DESTINATION = Path(__file__).resolve().parent.parent / ".luau-tools"


def download(url: str, sha256: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read(128 * 1024 * 1024)
    if hashlib.sha256(data).hexdigest() != sha256:
        raise SystemExit(f"{url} does not match its pinned checksum; refusing to install it")
    return data


def install(name: str, data: bytes, executable: bool):
    DESTINATION.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=DESTINATION) as directory:
        temporary = Path(directory) / name
        temporary.write_bytes(data)
        if executable:
            temporary.chmod(0o755)
        temporary.replace(DESTINATION / name)


def main():
    system = platform.system()
    if system not in LUAU_ASSETS:
        sys.exit(f"there are no pinned Luau tools for {system}")

    if not (DESTINATION / "luau-compile").exists():
        asset, sha256 = LUAU_ASSETS[system]
        archive = download(f"https://github.com/luau-lang/luau/releases/download/{LUAU_VERSION}/{asset}", sha256)
        install("luau-compile", zipfile.ZipFile(io.BytesIO(archive)).read("luau-compile"), True)

    if not (DESTINATION / "luau-lsp").exists():
        asset, sha256 = LUAU_LSP_ASSETS[system]
        archive = download(
            f"https://github.com/JohnnyMorganz/luau-lsp/releases/download/{LUAU_LSP_VERSION}/{asset}", sha256
        )
        install("luau-lsp", zipfile.ZipFile(io.BytesIO(archive)).read("luau-lsp"), True)

    if not (DESTINATION / "globalTypes.d.luau").exists():
        definitions = download(
            f"https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/{LUAU_LSP_VERSION}/scripts/globalTypes.d.luau",
            GLOBAL_TYPES_SHA256,
        )
        install("globalTypes.d.luau", definitions, False)


if __name__ == "__main__":
    main()
