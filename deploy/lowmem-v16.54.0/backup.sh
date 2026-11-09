#!/bin/bash
set +x
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

cd "$ROOT"
require_root
take_lock
guard_snapshot
stamp=$(date -u +%Y%m%dT%H%M%SZ)
create_backup "$ROOT/backups/$stamp"
guard_assert_stable
log "备份完成: $ROOT/backups/$stamp"
