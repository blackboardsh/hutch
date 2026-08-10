# Hutch Compatibility Tests

Hutch owns the build-time and package-manager portion of the Bun v1.3.10
compatibility suite. Cottontail remains the JavaScript runtime that executes
the copied `bun:test` files; a Hutch-owned preload redirects `bunExe()` and
`process.execPath` child commands to the Hutch binary under test.

The canonical ownership index is
[`bun-v1.3.10-ownership.json`](./bun-v1.3.10-ownership.json). It assigns each of
Bun v1.3.10's 1,445 runnable files to exactly one owner, so repository-local
copies are never double-counted.

Hutch owns 103 Bun-derived JavaScript tests with zero expected failures, and
Cottontail owns the remaining 1,342 runtime files. The previously owned 100
files have a measured passing baseline; the three transferred Next Pages files
remain enabled while their focused macOS strict result is established.

## Commands

Validate ownership and copied-file accounting without running upstream tests:

```sh
node scripts/run-bun-package-manager-tests.js --check
```

List the Hutch-owned compatibility suite:

```sh
node scripts/run-bun-package-manager-tests.js --list --all
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

Every execution writes a durable run record under
`.hutch-local-tools/bun-compat-runs/`. The runner prints the exact directory at
startup, appends checksummed `file-start`, heartbeat, and `file-end` records to
`events.jsonl`, streams bounded per-file output into `logs/`, and writes
`summary.json` at completion or on a handled interruption. Use
`--report-dir <new-path>` (or `HUTCH_COMPAT_REPORT_DIR`) to choose an exact new
directory, and `HUTCH_COMPAT_REPORTS_DIR` to move the default report parent.
The `run.json` record fingerprints the runner sources, inventories, frozen
harness dependency plan, selected files, and all three binaries used by the
run. `harness-dependencies.json` records the validated content-addressed cache
generation that was privately materialized for that execution.

## Branch CI

Pushes to `compat/**` branches and manual dispatches run the complete
Hutch-owned compatibility suite on macOS arm64, Linux x64 and arm64, and
Windows x64. The workflow builds Hutch from the branch and
builds Cottontail from the full Git commit recorded in
[`upstream/cottontail.json`](./upstream/cottontail.json). It does not resolve a
moving branch, channel, or release alias, and it never publishes artifacts.

The pinned Cottontail commit must be reachable from the public
`blackboardsh/cottontail` repository before the Hutch compatibility workflow
runs. When a Hutch test depends on unreleased Cottontail work, push the
Cottontail `compat/**` branch first, then update the full commit in the Hutch
manifest. Keep the pin on a Cottontail revision targeting the same Bun fork
point recorded by Hutch's copied suite.

## Refreshing

The imported snapshot is owned by Hutch and does not depend on Cottontail at
refresh time. Its JavaScript tests intentionally execute under Cottontail while
their child CLI calls target Hutch. To reproduce the original fork-point import
from a sibling Cottontail checkout:

```sh
node scripts/import-bun-package-manager-tests.js
```

Pass `--source` to use another copy of the pinned Bun v1.3.10 snapshot. The
importer rejects a changed canonical denominator or ownership count. The Next
Pages tree records hashes for its 28 tracked fixture files; each test recreates
the ignored 29th file, `src/Counter.tsx`, from `src/Counter1.txt` in a
test-owned temporary directory.
