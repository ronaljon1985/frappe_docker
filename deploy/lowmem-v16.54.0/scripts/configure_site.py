#!/usr/bin/env python3
"""Write bench connectivity config. Reads secrets from files and does not print them."""

import json
from pathlib import Path

BENCH = Path("/home/frappe/frappe-bench")
SITES = BENCH / "sites"
CONFIG = SITES / "common_site_config.json"


def read_secret(name):
    value = Path("/run/secrets", name).read_text(encoding="utf-8").strip()
    if len(value) < 24:
        raise SystemExit("secret " + name + " is missing or too short")
    return value


def main():
    SITES.mkdir(parents=True, exist_ok=True)
    apps = [
        path.name
        for path in (BENCH / "apps").iterdir()
        if path.is_dir() and not path.name.startswith(".")
    ]
    apps.sort(key=lambda name: (name != "frappe", name))
    if "frappe" not in apps or "erpnext" not in apps:
        raise SystemExit("baked image is missing frappe or erpnext")
    (SITES / "apps.txt").write_text("\n".join(apps) + "\n", encoding="utf-8")

    config = {}
    if CONFIG.exists() and CONFIG.stat().st_size > 0:
        loaded = json.loads(CONFIG.read_text(encoding="utf-8"))
        if not isinstance(loaded, dict):
            raise SystemExit("common_site_config.json is not an object")
        config = loaded

    cache_password = read_secret("redis_cache_password")
    queue_password = read_secret("redis_queue_password")
    config.update(
        {
            "db_host": "db",
            "db_port": 3306,
            "redis_cache": "redis://:" + cache_password + "@redis-cache:6379",
            "redis_queue": "redis://:" + queue_password + "@redis-queue:6379",
            "redis_socketio": "redis://:" + queue_password + "@redis-queue:6379",
            "socketio_port": 9000,
            "chromium_path": "/usr/lib/chromium/chromium-headless-shell",
        }
    )
    CONFIG.write_text(json.dumps(config, indent=1) + "\n", encoding="utf-8")
    CONFIG.chmod(0o640)
    print("common_site_config.json updated")


if __name__ == "__main__":
    main()
