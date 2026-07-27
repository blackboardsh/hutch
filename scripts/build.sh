#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/setup.sh"

if [[ $# -eq 0 ]]; then
  set -- build
fi

exec bash "$SCRIPT_DIR/zig.sh" "$@"
