#!/usr/bin/env python3
"""Assert the rendered Compose document matches the low-memory deployment contract."""

import json
import sys


def fail(message):
    raise SystemExit(message)


def main():
    document = json.load(sys.stdin)
    if document.get("name") != "erpnext-lowmem":
        fail("project name is not erpnext-lowmem")

    services = document.get("services") or {}
    required = [
        "db",
        "redis-cache",
        "redis-queue",
        "configurator",
        "create-site",
        "backend",
        "frontend",
        "websocket",
        "worker",
        "scheduler",
        "restore",
    ]
    for name in required:
        if name not in services:
            fail("missing service " + name)

    networks = document.get("networks") or {}
    data_net = networks.get("data") or {}
    app_net = networks.get("app") or {}
    if data_net.get("internal") is not True:
        fail("data network is not internal")
    if data_net.get("name") != "erpnext-lowmem-data":
        fail("data network name mismatch")
    if app_net.get("name") != "erpnext-lowmem-app":
        fail("app network name mismatch")
    if app_net.get("internal") is True:
        fail("app network must reach the published frontend")

    volume_names = {
        "db-data": "erpnext-lowmem-db-data",
        "sites": "erpnext-lowmem-sites",
        "logs": "erpnext-lowmem-logs",
        "redis-queue-data": "erpnext-lowmem-redis-queue-data",
    }
    volumes = document.get("volumes") or {}
    for key, expected in volume_names.items():
        if (volumes.get(key) or {}).get("name") != expected:
            fail("volume name mismatch for " + key)

    images = {
        "db": "mariadb:11.8",
        "redis-cache": "redis:8.6-alpine",
        "redis-queue": "redis:8.6-alpine",
    }
    for name, image in images.items():
        if services[name].get("image") != image:
            fail(name + " image mismatch")
    for name in required:
        if name in images:
            continue
        if services[name].get("image") != "frappe/erpnext:v16.54.0":
            fail(name + " image is not the pinned erpnext tag")
        if services[name].get("pull_policy") != "never":
            fail(name + " may pull from a registry at runtime")

    for name in ("db", "redis-cache", "redis-queue", "backend", "frontend", "websocket", "worker", "scheduler"):
        if services[name].get("restart") != "unless-stopped":
            fail(name + " restart policy mismatch")
    for name in ("configurator", "create-site", "restore"):
        if services[name].get("restart") != "no":
            fail(name + " must not restart")

    if services["restore"].get("profiles") != ["task"]:
        fail("restore must be behind the task profile")

    private = ("db", "redis-cache", "redis-queue", "configurator", "create-site", "worker", "scheduler", "restore")
    for name in private:
        attached = services[name].get("networks") or {}
        if "app" in attached or list(attached) != ["data"]:
            fail(name + " must attach only to the internal data network")
    for name in ("backend", "websocket"):
        attached = services[name].get("networks") or {}
        if set(attached) != {"data", "app"}:
            fail(name + " network attachment mismatch")
    if set((services["frontend"].get("networks") or {})) != {"app"}:
        fail("frontend must not join the database network")

    for name, service in services.items():
        for port in service.get("ports") or []:
            if name != "frontend":
                fail(name + " publishes a port")
            published = str(port.get("published"))
            target = int(port.get("target"))
            if published != "80" or target != 8080:
                fail("frontend port mapping is not host 80 to container 8080")
        blob = json.dumps(service)
        if "docker.sock" in blob or "/opt/zhenbei-escort" in blob:
            fail(name + " references docker.sock or the existing service tree")
        if "MYSQL_ROOT_PASSWORD" in (service.get("environment") or {}):
            fail("database password must not be a plain environment value")

    db_env = services["db"].get("environment") or {}
    if db_env.get("MYSQL_ROOT_PASSWORD_FILE") != "/run/secrets/db_root_password":
        fail("database root password file is not configured")
    frontend_env = services["frontend"].get("environment") or {}
    if frontend_env.get("FRAPPE_SITE_NAME_HEADER") != "frontend":
        fail("site header is not fixed to frontend")
    if str(frontend_env.get("NGINX_LISTEN_PORT")) != "8080":
        fail("container nginx port changed")
    backend_env = services["backend"].get("environment") or {}
    if str(backend_env.get("GUNICORN_WORKERS")) != "1":
        fail("gunicorn worker count is not 1")
    if str(backend_env.get("GUNICORN_THREADS")) != "2":
        fail("gunicorn thread count is not 2")

    worker_command = " ".join(services["worker"].get("command") or [])
    if "run_worker.sh" not in worker_command:
        fail("worker command is unexpected")
    db_command = " ".join(services["db"].get("command") or [])
    if "innodb-snapshot-isolation=OFF" not in db_command:
        fail("MariaDB snapshot isolation override is missing")
    if services["db"].get("mem_limit") in (None, 0, "0"):
        fail("database memory limit is missing")


if __name__ == "__main__":
    main()
