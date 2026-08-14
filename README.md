# Hutch

Hutch is the native build and workspace CLI for Electrobun projects. Its global
installation has two parts:

- `hutch`, a small launcher that reads an optional project version pragma.
- `hutch-engine`, the versioned engine that owns scripts, builds, toolchains, and
  Electrobun orchestration.

Cottontail is an independently released runtime. Hutch resolves it from the same
global content store when JavaScript execution is needed; it is not embedded in
or version-locked to a Hutch release. JavaScript dependency installation is
delegated to the project's external package manager. Hutch does not implement
npm registry resolution or mutate package-manager lockfiles.

## Install

Install the current production release on macOS or Linux:

```sh
curl -fsSL https://hutch.blackboard.sh/hutch/install.sh | sh
```

Install the canary target alongside production as `hutch-canary`:

```sh
curl -fsSL https://hutch.blackboard.sh/hutch/install.sh |
  sh -s -- --channel canary
```

On Windows:

```powershell
& ([scriptblock]::Create((irm https://hutch.blackboard.sh/hutch/install.ps1)))
```

Pass `-Channel canary` to install `hutch-canary.exe`. Both installers also accept
an exact semantic version or full build revision. Releases are stored side by
side under `~/.hutch/releases`. The installer atomically refreshes the native
launcher and records the selected exact release in
`~/.hutch/state/selections.json`; `hutch self update` advances that selection
for the next invocation. The Unix installer adds `~/.hutch/bin` to the detected
zsh, bash, fish, or POSIX shell profile and prints the command that activates it
in the current terminal. Pass `--no-modify-path` to only print that command.
`stable` is accepted as an installer channel alias for `production`.

## Project Pins

The first line of `hutch.config.ts` can pin
either layer:

```ts
// @hutch cli=0.4.1 cottontail=0.2.3
```

Accepted selectors are `production`, `stable`, `canary`, an exact semantic
version, or `build:<full-git-revision>`. `stable` resolves to `production`. The
same pragma works in a directly invoked
JavaScript or TypeScript entrypoint. An entrypoint field overrides the matching
config field; omitted fields continue to use the invocation channel.

Malformed pragmas and unavailable releases are hard errors. A project pin never
replaces the global production or canary selection.

## Package Managers

Hutch delegates JavaScript dependency operations to an external package
manager. `npm` is the default; projects can select `bun`, `pnpm`, or `yarn` in
`hutch.config.ts`, or provide an explicit executable:

```ts
export default {
  packageManager: "pnpm",
  // Or: packageManager: { name: "pnpm", executable: "/opt/tools/pnpm" },
  scripts: {
    install: ["hutch", "install"],
  },
};
```

`hutch install [args...]` runs `<package-manager> install [args...]`. `hutch pm
[args...]` passes the remaining arguments through unchanged. Other package
operations stay native to the selected manager; for example, use `hutch pm add
three` rather than a Hutch-specific add command. Hutch does not read
`package.json`, resolve dependencies, emulate lifecycle scripts, or mutate
lockfiles.

The external `bun` package-manager executable comes from `PATH` (or the explicit
`executable` above). It is intentionally separate from the Bun runtime bundled
inside an Electrobun devkit for `mainProcess: "bun"`; Hutch does not expose or
repurpose that application runtime as a package manager.

On Windows, Hutch invokes npm/pnpm/yarn `.cmd` and `.bat` shims only through its
native argv adapter. The underlying Windows batch format cannot preserve NUL,
carriage-return, or line-feed arguments, so Hutch rejects those values instead
of changing them. Shell-string tasks refuse batch shims entirely; use `hutch
pm`, an argv-form task such as `["npm", "run", "dev"]`, or a native executable.

## Store Status

`hutch status` prints everything Hutch manages on disk: the resolved home and
which rule selected it (`HUTCH_HOME` or the default `~/.hutch`), every installed
release with its per-install disk usage and local selection, every installed
toolchain, object reachability and live leases, and the projects registered
against those objects. A project whose directory no longer exists is marked.
Sizes are recursive file totals; symlinks are counted but never followed, so a
launcher symlink cannot pull an out-of-store tree into a total.

`hutch status --json` emits the same data as a machine-readable document with a
`schemaVersion` field. Like every ordinary Hutch invocation, `status` first
applies the 10-day lazy cleanup described below, then reports the remaining
store. It does not perform the zero-grace manual prune. Unreadable entries are
reported under `Issues` rather than failing the whole status command.

## Store and Cleanup

Hutch's home has four durable top-level directories:

```text
~/.hutch/
|-- bin/                  # production and canary launchers
|-- releases/
|   |-- hutch/            # installed Hutch engines
|   |-- cottontail/       # installed Cottontail runtimes
|   `-- electrobun/       # installed Electrobun cores and devkits
|-- toolchains/           # exact managed compilers
`-- state/
    |-- selections.json   # local names mapped to exact installed releases
    |-- projects/         # registered project dependency records
    |-- leases/           # objects in active use
    |-- locks/
    |-- trash/
    `-- tmp/
```

Remote release channels are resolved from fresh network metadata. Hutch does
not keep persistent copies of remote channel manifests, catalogs, artifact
indexes, or template indexes, and it does not create local channel directory
trees. Downloads may pass through `state/tmp/` while they are verified and
installed; only verified releases, toolchains, and authoritative local state
remain afterward.

Successful Electrobun preparation records the exact core/devkit, optional CEF
payload, and native toolchains in the generated project
`.hutch/dependencies.lock` and in Hutch's global project registry. Core and CEF
are independent managed objects, so a project that stops using CEF no longer
keeps that large payload reachable merely because it still uses the same core.
The currently executing Hutch release, local selections, resolvable registered
projects, and live leases protect the objects they use. A missing project or a
project whose dependency record cannot be resolved protects nothing.

Every ordinary Hutch invocation lazily removes releases and toolchains that
have remained unreachable for more than 10 days. `hutch prune --dry-run`
previews all currently unreachable objects without mutating Hutch state.
`hutch prune` performs the same reachability check with no age threshold and
immediately removes everything it reports.

`hutch reset` immediately recreates the entire Hutch home without prompting.
It reseeds the launcher, engine, and exact Hutch selection used for the reset so
the current Hutch command remains usable; every other installed release,
toolchain, selection, registration, lease, and temporary object is removed.
Neither command interprets or removes npm, Bun, pnpm, Yarn, Cargo, or Go module
caches, and neither changes project files.

Offline resolution is deliberately narrow. An already-installed exact release,
including one named by a local selection, and an already-installed toolchain can
be reused without the network. Resolving anything missing requires a fresh
network lookup and download. `hutch electrobun init` always requires the network
because template catalogs and archives are not persisted. A build can run
offline when every exact Hutch, Cottontail, and Electrobun release and every
managed toolchain it needs are already installed; dependencies owned by an
external package manager are a separate concern.

## Updates

```sh
hutch self update
hutch cottontail update
```

Interactive use checks for newer remote-channel releases at most every six
hours. Each check fetches current metadata rather than reading a persistent
metadata cache; Hutch stores only the successful check timestamp. The prompt
can update, skip that specific revision, or defer.
CI, non-interactive commands, and `HUTCH_NO_UPDATE_CHECK=1` never prompt.

Use `hutch self path`, `hutch self version`, `hutch cottontail path`, and
`hutch cottontail version` to inspect the selected installations. Each command
also accepts an explicit selector.

## Development

```sh
bash scripts/setup.sh
./vendors/zig/zig build test
./vendors/zig/zig build
./zig-out/bin/hutch --version
```

`scripts/setup.sh` only installs the pinned Zig toolchain. To run JavaScript
against a sibling Cottontail checkout:

```sh
DASH_USE_LOCAL_COTTONTAIL=1 ./zig-out/bin/hutch examples/smoke.js
```

`DASH_COTTONTAIL` and `COTTONTAIL_BINARY` override the runtime;
`HUTCH_ENGINE_BINARY` overrides the engine (not the launcher). `HUTCH_HOME`
changes the global store (default `~/.hutch`) and must remain set when a
non-default install root is used.
`DASH_ARTIFACTS_BASE_URL` selects another trusted artifact origin.

## Electrobun Projects

Run `hutch electrobun init` to choose a release template interactively, then
accept or replace its suggested project name. The chosen name controls the
created directory and the printed next steps. After preparing the project,
init runs its `install` task from `hutch.config.ts` when one is configured.
Pass `--skip-install` to leave that step to another orchestrator. Init requires
network access to fetch the current catalog and chosen template. Only
`--skip-install` prints `hutch run --if-configured install` as the explicit next
step.
The thin Electrobun npm package
delegates `npx electrobun init` and `bunx electrobun init` to
`hutch electrobun init`, installing the matching Hutch channel when needed.
Starter templates come from the selected production or canary Electrobun
catalog rather than from an npm package bundle.

Every v2 project pins its exact Electrobun release in `hutch.config.ts`:

```ts
export default {
  electrobun: { version: "2.0.0-beta.1" },
  // scripts, package-manager compatibility, and other tool configuration...
};
```

`electrobun.config.ts` owns application, build, packaging, and release settings;
it cannot select the Electrobun framework or SDK version.

`hutch electrobun init` prepares the extracted project before reporting
success. `hutch electrobun sync` repeats that preparation without building the
app. Both resolve the exact core and SDK release, optional CEF payload, and the
native compiler required by `build.mainProcess`. They atomically generate the
package-shaped editor/build facade at `.hutch/devkit`; projects should ignore
`.hutch/` by default and may extend `./.hutch/devkit/tsconfig.json`. The project
facade is generated state owned by Hutch; direct edits and committing it are
not supported workflows, and a later sync may replace it. Electrobun itself is
not an npm dependency.
Third-party JavaScript dependencies remain owned by the external package
manager invoked by a project script.

For development against an unpublished local core, set
`HUTCH_ELECTROBUN_DEVKIT_ROOT` to its absolute directory containing the exact
version/host `native-devkit.json`. Local syncs always refresh the facade so SDK
edits are visible immediately.

## Electrobun Packaging

`hutch electrobun build --env=dev` creates a runnable inner application bundle.
Canary and production builds also create the self-extracting outer wrapper,
compressed full-update archive, optional delta patch, platform installer, and
`<channel>-<os>-<arch>-update.json` in the configured artifact folder:

```sh
hutch electrobun build --env=canary
hutch electrobun build --env=production
```

Production app and installer names are unsuffixed; canary names include
`-canary`. `--env=stable` remains an alias for `--env=production`. macOS
produces a DMG unless `build.mac.createDmg` is false. Windows
produces a Setup ZIP, and Linux produces a self-extracting installer tarball.
Set `release.baseUrl` to the published artifact root to generate a delta from
the previous release, or set `release.generatePatch` to false to skip it.

Linux can also emit an opt-in Flatpak MVP without invoking Flatpak tooling:

```ts
build: {
  linux: {
    icon: "assets/icon.png",
    flatpak: {
      enabled: true,
      outputPath: "flatpak",
      // runtime, runtimeVersion, sdk, and finishArgs are optional overrides.
    },
  },
}
```

The relative `outputPath` is created under `build.artifactFolder`, with separate
identifier/channel/architecture directories. Each contains a manifest, a
Flatpak-named desktop entry, and an expanded payload that the manifest installs
under `/app`. This is intentionally an MVP recipe, not a built `.flatpak`:
`flatpak-builder` is not run, system-WebKit/runtime dependencies still require
real sandbox validation, and Electrobun's self-extractor and built-in updater
are unsupported there. Publish Flatpak builds and updates through the Flatpak
repository instead.

The native packager runs `preBuild`, `postBuild`, `postWrap`, and `postPackage`.
`postWrap` receives `ELECTROBUN_WRAPPER_BUNDLE_PATH` before signing.

For macOS code signing, set `ELECTROBUN_DEVELOPER_ID`. Notarization accepts
either App Store Connect API credentials:

```text
ELECTROBUN_APPLEAPIISSUER
ELECTROBUN_APPLEAPIKEY
ELECTROBUN_APPLEAPIKEYPATH
```

or Apple ID credentials:

```text
ELECTROBUN_APPLEID
ELECTROBUN_APPLEIDPASS
ELECTROBUN_TEAMID
```

For a local release-path test, use the ad-hoc identity and disable only the
notarization submission:

```sh
ELECTROBUN_DEVELOPER_ID=- ELECTROBUN_SKIP_NOTARIZATION=1 \
  hutch electrobun build --env=canary
```

## Releases

Hutch releases use semantic-version tags in this standalone repository:

- `vX.Y.Z` advances `hutch/channels/production.json`.
- `vX.Y.Z-canary.N` advances `hutch/channels/canary.json`.

Run `hutch push:canary` to propose the next `canary.N` release, or
`hutch push:production` to propose a production version. Both commands allow
editing the proposed semantic version before they commit, tag, and atomically
push `main` and the release tag.

The GitHub Actions matrix builds macOS ARM64, Linux x64/ARM64, and Windows x64.
It uploads one archive per revision and platform:

```text
hutch/builds/<revision>/<platform>/hutch.tar.gz
hutch/builds/<revision>/manifest.json
hutch/releases/<version>/manifest.json
hutch/channels/<production|canary>.json
hutch/install.sh
hutch/install.ps1
```

Archives contain only `bin/hutch`, `bin/hutch-engine`, and release metadata. The
mutable remote channel manifest is written after every immutable archive and
manifest. Every published object remains under the `hutch/` bucket prefix. Tags
are the only workflow trigger.

The GitHub repository requires `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, and
`R2_SECRET_ACCESS_KEY` Actions secrets. Those credentials must have object-write
access to the `electrobun-artifacts` bucket. The public URL defaults to
`https://hutch.blackboard.sh` and can be overridden independently with
`HUTCH_PUBLIC_BASE_URL` for local publishing. No public-URL secret is required
for the release workflow.

## Commands

- `hutch <entrypoint.js|entrypoint.ts> [args...]`
- `hutch <script-name> [args...]`
- `hutch run [--if-configured] [script-name] [args...]`
- `hutch build [args...]`
- `hutch electrobun <init|sync|build|run|dev> [args...]`
- `hutch self <path|version|update> [selector]`
- `hutch cottontail <path|version|update> [selector]`
- `hutch status [--json]`
- `hutch prune [--dry-run]`
- `hutch reset`

Scripts resolve exclusively from the nearest `hutch.config.ts`. A string is
command text parsed and executed by the selected Cottontail release's Bun.$
shell. A non-empty array is exact argv. Invocation arguments are appended as
separately escaped Bun.$ interpolations for strings and exact argv entries for
arrays:

```ts
export default {
  scripts: {
    dev: ["npm", "run", "dev"],
    deps: ["pnpm", "install"],
    lint: "eslint .",
  },
};
```

String values always use Bun.$ command semantics, even when the entire string
looks like a JavaScript or TypeScript filename. Hutch does not infer an
execution mode from a filename extension and does not send string tasks to the
host's `/bin/sh` or `cmd.exe`.

Hutch does not inspect `package.json`, add `node_modules/.bin` to `PATH`, or
emulate npm lifecycle variables when running these tasks. The configured
package manager owns those semantics. Hutch invokes the selected Cottontail
release for JavaScript execution, runtime compatibility APIs, and
compiler-backed build paths.

`hutch run --if-configured <script-name>` uses the same config-only lookup but
exits successfully when the task is absent. It is intended for generic setup
seams such as Electrobun init's optional `install` task; it never infers an
installer or package manager from project files.
