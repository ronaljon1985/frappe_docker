#!/bin/bash
set +x
set -euo pipefail

# shellcheck disable=SC1091
source /opt/bundle-scripts/container_common.sh
wait_tcp db 3306 240
wait_tcp redis-cache 6379 120
wait_tcp redis-queue 6379 120
exec bench worker --queue short,default,long
