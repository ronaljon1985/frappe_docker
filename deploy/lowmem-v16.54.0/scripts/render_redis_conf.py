#!/usr/bin/env python3
"""Render a Redis config from a template and a secret file. Prints nothing."""

import pathlib
import sys


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: render_redis_conf.py TEMPLATE DEST PASSWORD_FILE")
    template = pathlib.Path(sys.argv[1])
    dest = pathlib.Path(sys.argv[2])
    password = pathlib.Path(sys.argv[3]).read_text(encoding="utf-8").strip()
    if len(password) < 24 or not password.isalnum():
        raise SystemExit("password file is invalid")
    text = template.read_text(encoding="utf-8")
    if text.count("__REDIS_PASSWORD__") != 1:
        raise SystemExit("template placeholder is invalid")
    rendered = text.replace("__REDIS_PASSWORD__", password)
    if "__REDIS_PASSWORD__" in rendered or password not in rendered:
        raise SystemExit("redis config render failed")
    dest.write_text(rendered, encoding="utf-8")
    dest.chmod(0o644)


if __name__ == "__main__":
    main()
