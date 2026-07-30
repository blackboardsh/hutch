#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/build.sh" build test
node "$SCRIPT_DIR/local-stack.test.js"
node --test "$SCRIPT_DIR/release-contract.test.js" "$SCRIPT_DIR/release-version.test.js"
node "$SCRIPT_DIR/run-bun-package-manager-tests.js" --check
