# Hutch Compatibility Tests

Hutch owns the build-time and package-manager portion of the Bun v1.3.10
compatibility corpus. Cottontail remains the JavaScript runtime that executes
the copied `bun:test` files; a Hutch-owned preload redirects `bunExe()` and
`process.execPath` child commands to the Hutch binary under test.

The canonical ownership index is
[`bun-v1.3.10-ownership.json`](./bun-v1.3.10-ownership.json). It assigns each of
Bun v1.3.10's 1,445 runnable files to exactly one owner, so repository-local
copies are never double-counted.

Hutch owns and passes 100 files with zero expected failures. Cottontail owns
the remaining 1,345 runtime files.

## Commands

Validate ownership and copied-file accounting without running upstream tests:

```sh
node scripts/run-bun-package-manager-tests.js --check
```

List the Hutch-owned corpus:

```sh
node scripts/run-bun-package-manager-tests.js --list
```

Run one focused file:

```sh
node scripts/run-bun-package-manager-tests.js \
  --test test/cli/install/architecture-match.test.ts
```

Run a focused path expression:

```sh
node scripts/run-bun-package-manager-tests.js \
  --match '^test/cli/run/(?:if-present|workspaces)\.test\.ts$'
```

The complete suite requires an explicit `--all`. Override binaries with
`HUTCH_COMPAT_BINARY` and `HUTCH_COMPAT_COTTONTAIL` when they are not in the
default local build locations.

## Refreshing

The imported snapshot is owned by Hutch and does not depend on Cottontail at
refresh time. Its JavaScript tests intentionally execute under Cottontail while
their child CLI calls target Hutch. To reproduce the original fork-point import
from a sibling Cottontail checkout:

```sh
node scripts/import-bun-package-manager-tests.js
```

Pass `--source` to use another copy of the pinned Bun v1.3.10 snapshot. The
importer rejects a changed canonical denominator or ownership count.
