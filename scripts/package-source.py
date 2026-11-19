#!/usr/bin/env python3
"""Export the current public source snapshot without Git history or ignored local data."""
import pathlib
import hashlib
import plistlib
import subprocess
import tarfile

root = pathlib.Path(__file__).resolve().parent.parent
subprocess.run(["python3", str(root / "scripts/audit-publication.py")], check=True)
if not (root / "LICENSE").is_file():
    raise SystemExit("Choose a project LICENSE before preparing the public source archive")
version = plistlib.loads((root / "Support/Info.plist").read_bytes())["CFBundleShortVersionString"]
destination = root / f"build/releases/RepoDesk-{version}-source.tar.gz"
destination.parent.mkdir(parents=True, exist_ok=True)
paths = subprocess.check_output(["git", "-C", str(root), "ls-files", "--cached", "--others",
                                 "--exclude-standard", "-z"]).split(b"\0")


def portable_metadata(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    info.mtime = 0
    info.pax_headers = {}
    return info


with tarfile.open(destination, "w:gz") as archive:
    for raw in sorted(set(filter(None, paths))):
        path = pathlib.Path(raw.decode())
        source = root / path
        if source.is_file() and not source.is_symlink():
            archive.add(source, arcname=str(pathlib.Path("RepoDesk") / path), recursive=False,
                        filter=portable_metadata)
destination.with_suffix(destination.suffix + ".sha256").write_text(
    f"{hashlib.sha256(destination.read_bytes()).hexdigest()}  {destination.name}\n"
)
print(destination)
