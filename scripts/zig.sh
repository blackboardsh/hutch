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
# Compiler architecture can differ when an older Zig pin uses emulation. Follow
# the Node host architecture unless the caller supplied an explicit Zig target.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    if [[ "${1:-}" == "build" ]]; then
      has_target=false
      for arg in "$@"; do
        if [[ "$arg" == -Dtarget=* ]]; then has_target=true; fi
      done
      if [[ "$has_target" == false ]]; then
        case "$(node -p 'process.arch')" in
          arm64) set -- "$@" -Dtarget=aarch64-windows-msvc ;;
          x64) set -- "$@" -Dtarget=x86_64-windows-msvc ;;
          *) echo "hutch: unsupported Windows target architecture" >&2; exit 1 ;;
        esac
      fi
    fi
    ;;
esac
exec "$ZIG_BIN" "$@"
