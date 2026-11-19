#!/usr/bin/env python3
"""Read-only publication scan. Reports locations and rule names, never matched secrets."""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RULES = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "GitHub token": re.compile(rb"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,})\b"),
    "AWS access key": re.compile(rb"\bAKIA[0-9A-Z]{16}\b"),
    "personal home path": re.compile(rb"/Users/" + rb"(?!you(?:/|\b)|example(?:/|\b)|Shared(?:/|\b))[^/\s\"'<>]+/"),
}


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def findings(data):
    if b"\0" in data[:8192]:
        return []
    return [name for name, pattern in RULES.items() if pattern.search(data)]


def working_files():
    paths = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
    for raw in sorted(set(filter(None, paths))):
        path = pathlib.Path(raw.decode())
        absolute = ROOT / path
        if absolute.is_file() and not absolute.is_symlink():
            yield str(path), absolute.read_bytes()


def history_files():
    # Inspect unique blobs, including files deleted or replaced in later commits.
    process = subprocess.Popen(["git", "-C", str(ROOT), "cat-file", "--batch"],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    try:
        for line in git("rev-list", "--objects", "--all").splitlines():
            object_id, _, raw_path = line.partition(b" ")
            if not raw_path:
                continue
            process.stdin.write(object_id + b"\n")
            process.stdin.flush()
            header = process.stdout.readline().split()
            if len(header) != 3:
                raise RuntimeError("Unexpected git cat-file response")
            size = int(header[2])
            data = process.stdout.read(size)
            process.stdout.read(1)
            if header[1] == b"blob":
                yield f"{raw_path.decode(errors='replace')}@{object_id[:10].decode()}", data
    finally:
        process.stdin.close()
        process.stdout.close()
        process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="Also inspect all local Git history")
    args = parser.parse_args()
    hits = []
    scanned = 0
    for source in ([working_files(), history_files()] if args.history else [working_files()]):
        for path, data in source:
            scanned += 1
            labels = findings(data)
            if labels:
                hits.append((path, labels))
    for path, labels in hits[:40]:
        print(f"{path}: {', '.join(labels)}")
    print(f"Scanned {scanned} files/blobs; {len(hits)} locations need review.")
    print("This pattern scan does not replace manual review of company code, screenshots and logs.")
    return bool(hits)


if __name__ == "__main__":
    sys.exit(main())
