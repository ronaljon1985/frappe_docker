#!/usr/bin/env python3
"""Log in as Administrator using the root-only password file. Never prints it."""

import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


def request(opener, url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {})
    try:
        with opener.open(req, timeout=60) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read()


def main():
    if len(sys.argv) < 2:
        raise SystemExit("usage: check_login.py BUNDLE_ROOT [BASE_URL]")
    root = Path(sys.argv[1])
    base = sys.argv[2] if len(sys.argv) > 2 else "http://127.0.0.1"
    password = (root / "secrets" / "admin_password").read_text(encoding="utf-8").strip()
    if len(password) < 24:
        print("admin password file is invalid")
        return 1

    anonymous = urllib.request.build_opener()
    status, body = request(anonymous, base + "/login")
    if status != 200 or len(body) < 200:
        print("login page failed status=" + str(status))
        return 1
    page = body.decode("utf-8", errors="replace").lower()
    if "frappe" not in page and "login" not in page and "erpnext" not in page:
        print("login page missing expected marker")
        return 1

    status, body = request(anonymous, base + "/api/method/ping")
    if status != 200 or b"pong" not in body:
        print("ping failed status=" + str(status))
        return 1

    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())
    payload = urllib.parse.urlencode({"usr": "Administrator", "pwd": password}).encode()
    status, body = request(
        opener,
        base + "/api/method/login",
        data=payload,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
        },
    )
    if status != 200:
        print("login failed status=" + str(status))
        return 1
    try:
        message = json.loads(body.decode("utf-8")).get("message")
    except json.JSONDecodeError:
        print("login response was not json")
        return 1
    if message != "Logged In":
        print("login response message mismatch")
        return 1

    status, body = request(opener, base + "/api/method/frappe.auth.get_logged_user")
    if status != 200 or b"Administrator" not in body:
        print("session check failed status=" + str(status))
        return 1
    print("login ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
