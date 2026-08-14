#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "$SCRIPT_DIR/build.sh" build
bash "$SCRIPT_DIR/build.sh" build test
node "$SCRIPT_DIR/local-stack.test.js"
node "$SCRIPT_DIR/release-store-smoke.js"
node --test \
  "$SCRIPT_DIR/r2-settings.test.js" \
  "$SCRIPT_DIR/release-contract.test.js" \
  "$SCRIPT_DIR/release-version.test.js" \
  "$SCRIPT_DIR/verify-linux-glibc.test.js"
node --test --test-concurrency=1 \
  "$SCRIPT_DIR/../tests/storage-contract.test.js"
node --test --test-concurrency=1 \
  "$SCRIPT_DIR/../tests/electrobun/build-lifecycle-lock.test.js" \
  "$SCRIPT_DIR/../tests/electrobun/decorator-bundle.test.js" \
  "$SCRIPT_DIR/../tests/electrobun/init-scaffold.test.js" \
  "$SCRIPT_DIR/../tests/electrobun/javascript-sdk-subpaths.test.js" \
  "$SCRIPT_DIR/../tests/electrobun/non-index-main-entrypoint.test.js" \
  "$SCRIPT_DIR/../tests/electrobun/published-platform-artifact.test.js" \
  "$SCRIPT_DIR/../tests/electrobun/tsconfig-path-alias-bundle.test.js" \
  "$SCRIPT_DIR/../tests/electrobun/v2-devkit-sync.test.js"
node --test "$SCRIPT_DIR/zig-hostname-connect-patch.test.js"
