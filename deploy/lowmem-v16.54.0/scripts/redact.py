#!/usr/bin/env python3
"""Replace secret values found in files with ***. Does not print the values."""

import pathlib
import sys


def load_secrets(folder):
    found = []
    if not folder.is_dir():
        return found
    for path in sorted(folder.iterdir()):
        if not path.is_file() or "password" not in path.name:
            continue
        value = path.read_text(encoding="utf-8", errors="ignore").strip()
        if len(value) >= 8:
            found.append(value)
    return found


def main():
    folders = [pathlib.Path(arg) for arg in sys.argv[1:]] or [pathlib.Path("/run/secrets")]
    secrets = []
    for folder in folders:
        secrets.extend(load_secrets(folder))
    for line in sys.stdin:
        for secret in secrets:
            line = line.replace(secret, "***")
        sys.stdout.write(line)


if __name__ == "__main__":
    main()
