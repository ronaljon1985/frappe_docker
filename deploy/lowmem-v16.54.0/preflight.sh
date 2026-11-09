#!/bin/bash
set +x
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

cd "$ROOT"
require_root
run_preflight
