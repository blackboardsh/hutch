# Hutch test-harness dependencies

This Hutch-owned package and lock contain only the dependencies needed to run
the Bun-derived package-manager tests. The runner installs this lock with
`--frozen-lockfile`; it does not resolve dependencies from the copied upstream
test package at run time.

When reviewing a new upstream baseline, update the exact versions in
`package.json`, regenerate `bun.lock` with Hutch's `--lockfile-only` install,
and run `node --test scripts/bun-harness-dependencies.test.js`. The direct
versions must continue to match the reviewed upstream test package exactly.
