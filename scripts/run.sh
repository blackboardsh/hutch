#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUTCH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HUTCH_BIN="$HUTCH_ROOT/zig-out/bin/hutch"

bash "$SCRIPT_DIR/build.sh"

if [[ $# -eq 0 ]]; then
  set -- --help
fi

cd "$HUTCH_ROOT"
exec "$HUTCH_BIN" "$@"
