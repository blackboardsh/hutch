# Hutch

Hutch is the native build and workspace CLI for Electrobun projects. Its global
installation has two parts:

- `hutch`, a small launcher that reads an optional project version pragma.
- `hutch-engine`, the versioned engine that owns scripts, builds, toolchains, and
  Electrobun orchestration.

Bun is the default JavaScript/TypeScript script and test runner. Cottontail is
experimental and opt-in via `HUTCH_RUNTIME=cottontail`.

Cottontail is released and stored independently, but every Hutch release names
the Cottontail version it was built and tested with. An unpinned project uses
that pair for internal configuration and bundling helpers; an explicit Cottontail pin wins.
JavaScript dependencies install through Hutch's minimal built-in npm-compatible
resolver by default, or through an explicitly selected external package manager.

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
`~/.hutch/state/selections.json`; `hutch upgrade` advances that selection for
the next invocation (`hutch self update` is its explicit long form). The Unix
installer adds `~/.hutch/bin` to the detected
zsh, bash, fish, or POSIX shell profile and prints the command that activates it
in the current terminal. Pass `--no-modify-path` to only print that command.
`stable` is accepted as an installer channel alias for `production`.

Windows ARM64 is initially available on the canary channel. The PowerShell
installer detects the native CPU even from an emulated x64 shell. Existing
x64 launchers keep selecting x64 releases; rerun the installer with
`-Channel canary` to install the native `hutch-canary.exe`. Its paired ARM64
Cottontail supports JavaScriptCore's Baseline, DFG, FTL, and WebAssembly JITs.
After updating an x64 canary on ARM64 hardware, Hutch prints the native
installer command. Automatic architecture migration is not enabled yet.

## Project Pins

The first line of `hutch.config.ts` can pin
either layer:

```ts
// @hutch cli=0.4.1 cottontail=0.2.3
```

Accepted selectors are `production`, `stable`, `canary`, `latest`, an exact
semantic version, or `build:<full-git-revision>`. `stable` and `latest` resolve
to `production`. The same pragma works in a directly invoked
JavaScript or TypeScript entrypoint. An entrypoint field overrides the matching
config field; omitted fields continue to use the invocation channel.

Malformed pragmas and unavailable releases are hard errors. A project pin never
replaces the global production or canary selection.

Without a pragma, the CLI floats on the active channel and Cottontail runs the
release paired with that CLI — the build-time runtime only; the Cottontail
bundled into an app is pinned by the Electrobun release's devkit manifest,
exactly like the bundled Bun. A wrapping distribution (the `electrobun` npm
package) may supply its paired CLI and Electrobun versions through
`HUTCH_DEFAULT_CLI` and `HUTCH_DEFAULT_ELECTROBUN`; those are defaults,
not overrides — an explicit pragma or config pin always wins.
Electrobun projects may also omit `electrobun.version` entirely: the project
then uses an npm-supplied paired version when present. Otherwise it floats on
the Electrobun release channel: `hutch electrobun sync` advances it to the
current channel head, and every other command reuses the release recorded in
`.hutch/devkit` so builds stay stable between syncs.

`hutch self pin` and `hutch cottontail pin` rewrite the nearest config's pragma
in place. Without a selector they pin the exact version currently selected for
the active channel; an explicit selector — including the floating `latest` — is
written as given. `--recursive` instead walks the tree below the current
directory and moves every config whose pragma already pins an exact version or
build, leaving channel-tracking and pragma-free configs alone — one command
bumps a whole monorepo of templates after a release. `hutch status` reports the
current directory's pragma, what it resolves to, and the active channel's
version side by side, and `hutch upgrade` points out when the directory's
pin keeps it behind the selection it just advanced.

## Package Managers

Hutch ships a minimal built-in npm-compatible resolver and uses it by
default: it downloads registry tarballs, verifies sha512 integrity, caches
under `~/.hutch/cache/npm`, materializes `node_modules`, and writes Hutch's
own deterministic lockfile, `hutch.lock` — the only lockfile Hutch reads;
foreign lockfiles are ignored, never migrated. It installs registry, `file:`,
and git dependencies (`github:owner/repo#ref` and `git+<url>#ref`, pinned to
exact commits in the lockfile and installed as checked out — lifecycle
scripts, including `prepare`, never run). Workspaces remain external-manager
territory. Standalone Cottontail scripts get launch-time auto-installation of
their package imports.

Explicit choices always win. Projects can select `npm`, `bun`, `pnpm`, or
`yarn` in `hutch.config.ts`, or provide an explicit executable:

```ts
export default {
  packageManager: "pnpm",
  // Or: packageManager: { name: "pnpm", executable: "/opt/tools/pnpm" },
  scripts: {
    install: ["hutch", "install"],
  },
};
```

`hutch install [args...]` resolves with the built-in resolver, or runs
`<package-manager> install [args...]` when one is selected. With the built-in
resolver, `hutch pm` shows help and `hutch pm exec [--] <command> [args...]`
runs only a matching executable from the nearest package project's
`node_modules/.bin`; it never downloads a package or falls back to `PATH`.
`hutch pm --version` reports the Hutch version. With an external manager
selected, `hutch pm [args...]` instead passes every argument through unchanged,
so its native operations remain available (`hutch pm add three`, for example).

`hutch.config.ts` is the only external-manager selection channel. Without a
`packageManager` there, the built-in resolver runs — foreign lockfiles (`bun.lock`,
`package-lock.json`, `pnpm-lock.yaml`, `yarn.lock`) are ignored entirely:
never read, migrated, or modified. Hutch resolves from `package.json` and
creates `hutch.lock`; projects that want their previous tool declare it
explicitly. In a generic project, selecting `bun` resolves exact Bun 1.4.0,
reusing an exact PATH match or installing it as a managed toolchain. An
Electrobun project instead resolves the exact managed Bun pin from its devkit,
the same binary that `mainProcess: "bun"` apps bundle, so PATH tooling is not
required in either mode.

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
managed toolchain it needs are already installed. JavaScript dependencies must
also already be materialized by the built-in resolver or the explicitly
selected external package manager.

## Updates

```sh
hutch upgrade
```

Cottontail is paired with the Hutch release: an unpinned project runs the
Cottontail version this launcher was built and tested with, and
`hutch upgrade` advances both together (`hutch self update` is the explicit
long form). There is no separate `hutch cottontail update`; a project that
needs a different Cottontail pins one with the pragma or
`hutch cottontail pin`.

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

Run the managed deployment checks against those local executables:

```sh
node scripts/test-managed-deploys.mjs
```

This runs native upload/publish HTTP tests, the JavaScript helper tests, and
Zig inventory, timeout, configuration, and static-host compatibility tests.
It fails if the local launcher, engine, or Zig is missing, and uses an isolated
Hutch store. `HUTCH_BINARY`, `HUTCH_ENGINE_BINARY`, and `ZIG_BINARY` can select
other local builds. No Cloudflare credentials or JavaScript app runner are
needed. CI runs this suite on macOS, Linux, and Windows and before release
publication. The installed-app lifecycle against the real local Cloud Worker,
R2, D1, and Insights queue is maintained in the sibling `dash-cloud` repository.

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

For Electrobun app bundles, build-time overrides alone do not replace the
devkit-pinned runtime. In `--env=dev` only, set
`HUTCH_ELECTROBUN_COTTONTAIL_BINARY` to an absolute local executable path, or
use `DASH_USE_LOCAL_COTTONTAIL=1` to bundle the selected build-time Cottontail.
The explicit executable takes precedence. Both forms require the sibling core
and capability artifacts and record local executable SHA-256 provenance in
`build.json`, without claiming the published app-runtime version. Canary and
stable builds reject either local mode; unset these variables before release.

## Electrobun Projects

Run `hutch electrobun init` to choose a release template interactively, then
accept or replace its suggested project name. The chosen name controls the
created directory and the printed next steps. After preparing the project,
init runs its `install` task from `hutch.config.ts` when one is configured.
Pass `--skip-install` to leave that step to another orchestrator. Init requires
network access to fetch the current catalog and chosen template. Only
`--skip-install` prints `hutch run --if-configured install` as the explicit next
step.
The single, dependency-free Electrobun npm package delegates
`npx electrobun init` and `bunx electrobun init` to `hutch electrobun init`.
When its exact paired Hutch is not cached, the bootstrap downloads and verifies
the host archive published on that Electrobun version's GitHub Release. Init
also ensures a compatible global launcher is present for the generated
project's direct `hutch` tasks while running the initializer through the exact
private cache. Starter templates come from the selected production or canary
Electrobun catalog rather than from an npm package bundle.

An exact Electrobun pin in `hutch.config.ts` is optional and always wins over
the npm-supplied or channel default:

```ts
export default {
  electrobun: { version: "2.0.0-beta.1" },
  // scripts, package-manager compatibility, and other tool configuration...
};
```

Without that pin, an npm-launched command uses the version paired with the
installed `electrobun` package. A direct Hutch invocation instead reuses the
version already projected into `.hutch/devkit`; an explicit
`hutch electrobun sync` advances a floating project to the active channel head.
`electrobun.config.ts` owns application, build, packaging, and release settings;
it cannot select the Electrobun framework or SDK version.

`hutch electrobun update` resolves the latest stable release, safely rewrites
the exact `electrobun.version` string literal in the nearest parent
`hutch.config.ts`, and then runs `sync` for the current app. It requires network
access and fails closed rather than rewriting a computed, missing, or ambiguous
version field.

`hutch electrobun init` prepares the extracted project before reporting
success. `hutch electrobun prepare` repeats that work without advancing an
existing floating projection, while `hutch electrobun sync` deliberately
selects the current default or channel release. All three resolve the exact core
and SDK release, optional CEF payload, and the native compiler required by
`build.mainProcess`. They atomically generate the package-shaped editor/build
facade at `.hutch/devkit`; projects should ignore
`.hutch/` by default and may extend `./.hutch/devkit/tsconfig.json`. The project
facade is generated state owned by Hutch; direct edits and committing it are
not supported workflows, and a later sync may replace it. The optional
`electrobun` devDependency is only a command bootstrap; runtime and SDK imports
come from the projected devkit rather than `node_modules/electrobun`.
Third-party JavaScript dependencies use Hutch's built-in resolver by default,
or an external package manager selected explicitly in `hutch.config.ts`.
Cottontail runtime components are a separate graph: Hutch scans the bundled
application for component roots, reads the exact runtime release's
`cottontail-stdlib/capabilities.json`, and includes the transitive `requires`
closure. The selected JavaScript package manager never resolves those private
runtime components.

For development against an unpublished local core, set
`HUTCH_ELECTROBUN_DEVKIT_ROOT` to its absolute directory containing the exact
version/host `native-devkit.json`. Local syncs always refresh the facade so SDK
edits are visible immediately.

## Electrobun Packaging

`hutch electrobun build --env=dev` creates a runnable inner application bundle.
Canary and stable builds also create the self-extracting outer wrapper,
compressed full-update archive, optional delta patch, platform installer, and
`<channel>-<os>-<arch>-update.json` in the configured artifact folder:

```sh
hutch electrobun build --env=canary
hutch electrobun build --env=stable
```

The update document keeps the Electrobun 1.x `version`, `hash`, `platform`,
and `arch` fields and adds schema, app identity, and the exact compressed
artifact filename. Those additive fields let compatible v1.18.1+ apps
transition to a 2.0 release. Keep the app name, identifier, and existing update
base URL unchanged for that bridge release.

Updater protocol files use `stable-<os>-<arch>-` or
`canary-<os>-<arch>-`: the update JSON, compressed archive, and conventional
`<fromHash>.patch`. Hutch generates one patch from the previously published
bundle; retain older hash-named patch files so clients can follow the chain.

Stable app names are unsuffixed. Stable installers use `<os>-<arch>-...`
filenames, while canary updater files and installers keep the
`canary-<os>-<arch>-...` prefix. macOS produces a DMG unless
`build.mac.createDmg` is false. Windows produces a Setup ZIP, and Linux
produces a self-extracting installer tarball.
Set `release.baseUrl` to the published artifact root to generate a delta from
the previous release, or set `release.generatePatch` to false to skip it.

### Electrobun Managed Deploys

Set the app ID from your Dash dashboard in `electrobun.config.ts`:

```ts
release: {
  managed: { appId: "your-app-id" },
},
insights: { appId: "your-app-id" },
```

The service URL is automatic. Managed builds use one stable folder at
`/v1/electrobun/apps/<appId>/updates/` for the ordinary
`<channel>-<os>-<arch>-update.json`, `<channel>-<os>-<arch>-<fromHash>.patch`,
and full-archive filenames. Hutch reads the previous release from that folder
when generating a patch. The Worker serves that published artifact folder
through D1 routing; app update requests contain no release ID. Artifact bytes
remain grouped in R2 at
`accounts/<account>/apps/<app>/releases/<channel>/<version>/<filename>`.
Release metadata, publication state, and upload bookkeeping live in D1; the
version folder contains only the generated artifact files. Registered prerelease
installs can receive a selected prerelease from the same flat URLs.
A shared, persisted Electrobun installation ID identifies the
install for managed updates and Insights; Insights remains independently opt-in.
Applications can show `app.getInstallationId()` in About, Help, or settings so
developers and early adopters can enroll an installation in the prerelease group.
Omit `release.managed` to keep using any static artifact host through
`release.baseUrl`, with the existing artifact layout and updater behavior.
Insights is independent of the updater.
Future externally distributed builds can set `release.updateAuthority` to
`"external"` or `"none"` to disable direct update downloads while retaining Insights.

A custom domain is optional. After registering and verifying its hostname in
Dash, set it alongside the managed app ID:

```ts
release: {
  managed: { appId: "your-app-id" },
  baseUrl: "https://updates.example.com",
},
insights: { appId: "your-app-id" },
```

Managed update filenames are requested directly beneath that origin. Insights
for the same app defaults to its `/insights` endpoint; an explicit Insights
`apiUrl` remains an override. Insights collection is still off unless enabled.
DNS CNAME records identify hostnames, not URL folders: Dash must bind the custom
hostname to this app and configure TLS before it can serve requests. Upload and
publish continue using the control API; the custom download hostname does not
receive deployment credentials.

Keep the base app name and identifier in `app`. Hutch names canary bundles
automatically and appends `.canary` to managed canary identifiers, so stable and
canary installs can coexist. The dashboard uses that same convention; there is
no separate canary identity to configure. Existing static-hosted applications
retain their configured identifiers.

After building, provide an app-scoped API key through `ELECTROBUN_API_KEY` (or
`--api-key`) and stage the existing artifact directory:

```sh
hutch electrobun build --env=canary
hutch electrobun upload --dry-run
hutch electrobun upload
```

Upload discovers the channel, version, and platforms from the artifact names and
update manifests. Hutch's Zig core validates the manifests, hashes files, and
uploads 8 MiB parts directly to R2 using short-lived, checksum-bound signed URLs.
The API authorizes and completes uploads; artifact bytes do not pass through it.
Retry the same command to resume an interrupted upload. Each runner
uploads its generated artifacts; the service accumulates the platforms as they
arrive. No platform list or upload environment is required.

The generated `<channel>-<platform>-<arch>-update.json` carries the archive name
and tar integrity metadata. Upload validates those integrity fields together when
present, and also accepts older `update.json` files without those optional fields.

Upload and publish require only the Hutch binary. They do not run JavaScript,
install packages, or evaluate `electrobun.config.ts`. A managed build saves public
defaults (`appId`, `apiUrl`, and `artifactFolder`) in `.hutch/managed-deploy.json`
and includes `managed-deploy.json` in its artifact folder. No credentials are
written to these files. When copying artifacts to another runner, retain that
file and select the copied folder with `--artifacts=<folder>`. Explicit `--app`
or `ELECTROBUN_APP_ID` can supply the app ID when no build metadata is available.

Release IDs are `<channel>-<version>`, so a canary build of app version
`1.2.3` stages into `canary-1.2.3` on every runner. If a folder contains both
canary and stable artifacts, upload stages each channel into its own release.
An optional `--release=<id>` must match the inferred channel and version; it
cannot create an alternate release for the same version. Canary and stable may
use the same version because their artifact folders remain separate.

Upload never publishes. In CI, make a separate publish job depend on all build
and upload jobs succeeding. That job reads the accumulated release from the
server, verifies its files, and publishes it without needing local artifacts:

```sh
hutch electrobun publish --app=your-app-id --release=canary-1.2.3 --audience=prerelease --dry-run
hutch electrobun publish --app=your-app-id --release=canary-1.2.3 --audience=prerelease
# When ready, publish the same uploaded files to public:
hutch electrobun publish --app=your-app-id --release=canary-1.2.3 --audience=public
```

The publish dry run inspects the release and prints the intended audience without
changing routing. `--audience=prerelease` publishes to installation IDs enrolled
in the app's prerelease group in Dash. `--audience=public` publishes to all installs
and is the default when the flag is omitted. Membership in the prerelease group
persists after public publication. Publishing a public release also leaves an
independently selected later prerelease in place. You can review files and
publish to either audience from the dashboard. The service checks the uploaded
files; CI's job dependencies determine when every
intended runner has finished. Canary and stable are the supported channels; dev
builds do not create release artifacts. The final publish job needs the Hutch
binary and API key, with no local artifacts, project checkout, or build sidecar.

Publication changes D1 routing selections without copying or renaming artifacts.
Uploaded files remain in their channel/version folder. D1 maps ordinary
hash-named patch requests to retained release folders, including older published
patches needed to follow a chain. Prerelease patches are selected only for
registered prerelease installs. Hutch's build-time patch generation always fetches
the public release. A release's files become read-only once published to either
audience; a different build needs a new
version. This managed-hosting rule does not change the existing hash-based
update behavior for static hosts.

`hutch electrobun deploy` remains an alias for upload. Use `--artifacts` for a
different directory, `--app` to override the configured app, or `--api-url` to
select staging. App-scoped API keys authorize uploads and publication. Keep them
in CI secrets or the shell environment, never in bundled app configuration.

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

The GitHub Actions matrix builds macOS ARM64, Linux x64/ARM64, and Windows x64/ARM64.
Windows ARM64 uses the native ARM64 Zig 0.17 compiler and runs the resulting
ARM64 binaries and tests natively. Projects pinned to older Zig versions retain
their x64 compiler fallback. Odin main-process builds are unavailable on Windows
ARM64.
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
manifest. Every published object remains under the `hutch/` bucket prefix.
Pull requests and manual runs validate the full matrix; only version tags publish.

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
- `hutch install [args...]`
- `hutch pm exec [--] <command> [args...]`
- `hutch build [args...]`
- `hutch electrobun <init|update|config|prepare|sync|build|upload|publish|run|dev> [args...]`
- `hutch upgrade [selector]`
- `hutch self <path|version|update|pin> [selector] [--recursive]`
- `hutch cottontail <path|version|pin> [selector] [--recursive]`
- `hutch status [--json]`
- `hutch prune [--dry-run]`
- `hutch reset`

Scripts resolve exclusively from the nearest `hutch.config.ts`. A string is
command text parsed and executed by the selected runtime's Bun.$
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

On macOS and Linux, Ctrl-C reaches the foreground command and Hutch waits for
it to finish, including asynchronous shutdown handlers. Nested named scripts
preserve this behavior. Automation should send SIGINT to the command's process
group, as a terminal does; Hutch does not forward an interrupt sent only to the
outer orchestrator, which could otherwise deliver a terminal interrupt twice.

Hutch does not inspect `package.json`, add `node_modules/.bin` to `PATH`, or
emulate npm lifecycle variables when running these tasks. Invoke a local binary
explicitly with `hutch pm exec`, or select and call an external package manager.
Hutch defaults to Bun for JavaScript/TypeScript scripts and tests. Internal
config loading and Electrobun bundling still use the paired Cottontail.
Set `HUTCH_RUNTIME=cottontail` to use the experimental script runner, or
`HUTCH_RUNTIME=bun` to select Bun even with local Cottontail overrides.
A Cottontail version pragma alone does not select the script runner.

`hutch run --if-configured <script-name>` uses the same config-only lookup but
exits successfully when the task is absent. It is intended for generic setup
seams such as Electrobun init's optional `install` task; it never infers an
installer or package manager from project files.
