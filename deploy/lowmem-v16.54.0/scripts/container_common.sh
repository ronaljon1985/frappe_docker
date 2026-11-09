#!/bin/bash
# Shared helpers for scripts that run inside the ERPNext image.

wait_tcp() {
	python3 - "$1" "$2" "$3" <<'PY'
import socket
import sys
import time

host = sys.argv[1]
port = int(sys.argv[2])
timeout_s = int(sys.argv[3])
deadline = time.time() + timeout_s
while True:
    try:
        with socket.create_connection((host, port), timeout=2):
            raise SystemExit(0)
    except OSError:
        if time.time() >= deadline:
            print("wait timed out for " + host + ":" + str(port), file=sys.stderr)
            raise SystemExit(1)
        time.sleep(2)
PY
}

enable_site_scheduler() {
	bench --site frontend enable-scheduler
	bench --site frontend scheduler resume
	bench --site frontend scheduler status
}
