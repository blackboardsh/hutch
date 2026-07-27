#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUTCH_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZIG_BIN="$HUTCH_ROOT/vendors/zig/zig"

if [[ ! -x "$ZIG_BIN" ]]; then
  echo "hutch: vendored Zig compiler not found at $ZIG_BIN. Run bash scripts/setup.sh first." >&2
  exit 1
fi

cd "$HUTCH_ROOT"
exec "$ZIG_BIN" "$@"
