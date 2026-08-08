# Hutch and Cottontail Responsibility Split

Status: implemented current-cycle boundary with deferred compiler extraction

## Scope

This cycle separates project and build-time responsibilities between Hutch and
Cottontail while preserving Cottontail's current source-loading behavior.

It does not introduce a new application graph, dynamic libraries, optional
capabilities, or a new packaged-app format. It also does not make Cottontail's
compiler removable yet. Those are separate future milestones.

The rule for this cycle is:

- Hutch owns project mutation, build orchestration, and developer commands.
- Cottontail owns JavaScript execution, module loading, and runtime APIs.

## Implementation Status

Hutch now contains the package-manager and project-command Zig sources, owns
their public command routes, runs package scripts, and performs launch-time
dependency installation before starting Cottontail. Cottontail rejects those
public commands with a Hutch diagnostic and no longer contains a package
downloader or project-mutation command path.

Three narrow Cottontail services remain during this cycle: package-import
analysis, source-create analysis, and legacy binary-lockfile conversion. Hutch
owns when those services are invoked and all resulting filesystem mutation.
The compiler implementation behind `hutch build` also remains in Cottontail as
described below.

## Hutch Ownership

Hutch directly owns and implements:

- `install`, `add`, `remove`, `update`, `outdated`, `link`, and `unlink`.
- Lockfile creation and mutation, workspace installation, dependency lifecycle
  scripts, package caches, registry access, and package extraction.
- `pm`, `audit`, `patch`, `pack`, `publish`, `bunx`, `init`, `create`, and
  package-manager upgrade behavior.
- Discovery and orchestration of `hutch.config.ts` and `package.json` scripts.
- Bun-compatible launch-time auto-install before a project command, including
  the `auto`, `fallback`, `force`, and `disable` modes.
- Build, test, development-server, watch, hot-reload, and Electrobun packaging
  orchestration.

The package-manager Zig implementation and its command-level tests live in
Hutch. Hutch does not delegate `install` back to the Cottontail executable.

## Cottontail Ownership

Cottontail continues to own:

- JavaScriptCore, the VM, event loop, timers, promises, and process lifecycle.
- ESM and CommonJS loading, `require`, dynamic import, and workers.
- Runtime reading of `package.json`, `node_modules`, package exports/imports,
  package conditions, and module type.
- `Bun.resolve` and Node-compatible module resolution.
- TypeScript, JSX, and other source transformation currently required when
  Cottontail directly executes source files.
- Runtime APIs including files, streams, fetch, HTTP, TLS, sockets, subprocesses,
  crypto, FFI, and other Node, Web, and Bun APIs.
- `Bun.$` and the Bun shell. Shell execution is a runtime primitive analogous
  to `node:child_process`; Hutch can use it while orchestrating project scripts.
- Existing compiler-backed compatibility APIs during this cycle.

Cottontail may read an already-installed package tree, but it must not download,
install, update, or mutate packages. A missing package remains a deterministic
module-resolution error and may tell the developer to run `hutch install`.
The launch-time auto-install preflight runs in Hutch before Cottontail starts.

## Build APIs

`bun build`, `Bun.build`, `Bun.Transpiler`, plugins, macros, and standalone
compilation conceptually belong to Hutch. Physically extracting their compiler
implementation is not part of this cycle because the same compiler is currently
used by Cottontail to execute arbitrary TypeScript, JSX, workers, and dynamic
imports.

For this cycle:

- Hutch owns the public build command and Electrobun build flow.
- Hutch may invoke Cottontail's existing compiler-backed compatibility API.
- Cottontail retains that implementation so existing behavior does not regress.
- No compiler code is duplicated between the repositories.

Moving the implementation itself without a prebuilt graph would require either
duplicating the compiler, introducing a build RPC between the binaries, or
restricting Cottontail to precompiled JavaScript. None is a clean file move, so
that extraction is deferred.

## Command Breakdown

| Surface | Owner after this cycle | Implementation action |
| --- | --- | --- |
| `bun install`, package mutation, lockfiles | Hutch | Hutch-owned implementation and tests |
| `bun run` and package scripts | Hutch orchestration | Cottontail still executes JS entrypoints |
| `bunx`, `init`, `create`, `pm`, `publish` | Hutch | Hutch-owned implementation and tests |
| `bun build`, `Bun.build`, transpiler, plugins | Hutch-facing, temporarily Cottontail-backed | Keep compiler implementation for now |
| `bun test` | Hutch orchestration | Keep runtime test hooks for now |
| Bake, dev, watch, hot reload | Hutch orchestration | Retain required Cottontail runtime hooks |
| REPL and Cottontail CLI completions | Cottontail | Retain as runtime CLI compatibility |
| `Bun.$`, `Bun.spawn`, `node:child_process` | Cottontail | Keep as runtime APIs |
| `require`, import, workers, `Bun.resolve` | Cottontail | Keep current filesystem resolver |
| `Bun.file`, fetch, serve, crypto, streams | Cottontail | Keep as runtime APIs |

## Compatibility Accounting

The copied Bun 1.3.10 corpus contains 1,445 runnable files. The ownership index
assigns 100 package-manager and project-command files to Hutch and the remaining
1,345 runtime files to Cottontail, with no overlap or unclassified files. Hutch
passes all 100 owned files and records zero expected failures.

`test/cli/install/semver.test.ts` and
`test/cli/run/shell-keepalive.test.ts` remain Cottontail-owned because they test
`Bun.semver` and `Bun.$` runtime behavior rather than Hutch orchestration. The
copied Hutch snapshot excludes those files and their exclusive fixtures while
retaining their canonical Bun provenance in the shared ownership index.

Cottontail-local project and package-manager regressions that exercise the
split live in Hutch's local regression suite. Package executable shebang routing
launches JavaScript and TypeScript bins through the selected Cottontail runtime.
The exposed `bun:internal-for-testing` utility test remains in Cottontail because
it tests a runtime module rather than a project command.

Use these commands to inspect and execute Hutch's ownership:

```sh
node scripts/run-bun-package-manager-tests.js --check
node scripts/run-bun-package-manager-tests.js --all --jobs 4
node scripts/run-local-package-manager-tests.js --all
```

The runner prints enabled, expected-failure, and unexpected counts separately.
Re-importing the copied snapshot preserves Hutch's measured status metadata,
and manifest validation rejects stale aggregate counts.

## Definition of Done

- `hutch install` and all package-manager commands execute Hutch-owned Zig code.
- Hutch no longer delegates package installation to Cottontail.
- Cottontail cannot install, update, or download a package; equivalent
  launch-time auto-install behavior is owned by Hutch.
- Cottontail still runs the same JavaScript, TypeScript, package imports,
  workers, dynamic imports, and runtime APIs it runs today.
- Hutch owns project scripts and build/test/development command orchestration.
- Existing Node and Bun compatibility tests remain represented under the
  repository that owns the behavior.

Cross-platform Electrobun and Dash application validation remains a release
gate. It is intentionally separate from this source-ownership boundary.
