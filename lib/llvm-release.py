#!/usr/bin/env python3
"""Select an official stable LLVM x86-64 Linux release with an API SHA256."""
import json
import re
import sys

major = int(sys.argv[1])
candidates = []
for release in json.load(sys.stdin):
    match = re.fullmatch(r"llvmorg-(\d+)\.(\d+)\.(\d+)", release.get("tag_name", ""))
    if not match or release.get("draft") or release.get("prerelease"):
        continue
    version = tuple(map(int, match.groups()))
    if version[0] != major:
        continue
    expected = f"LLVM-{'.'.join(match.groups())}-Linux-X64.tar.xz"
    for asset in release.get("assets", []):
        digest = asset.get("digest") or ""
        url = asset.get("browser_download_url") or ""
        if (asset.get("name") == expected
                and re.fullmatch(r"sha256:[0-9a-f]{64}", digest)
                and url.startswith("https://github.com/llvm/llvm-project/releases/download/")):
            candidates.append((version, expected, url, digest[7:], int(asset["size"])))
if not candidates:
    sys.exit("No compatible official LLVM archive with a published SHA256 was found.")
_, name, url, checksum, size = max(candidates)
print(name, url, checksum, size, sep="\t")
