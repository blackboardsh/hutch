# Hutch

Hutch is the native build and workspace CLI for Electrobun projects. Its global
installation has two parts:

- `hutch`, a small launcher that reads an optional project version pragma.
- `hutch-engine`, the versioned engine that owns scripts, builds, package management,
  toolchains, and Electrobun orchestration.

Cottontail is an independently released runtime. Hutch resolves it from the same
global content store when JavaScript execution or package management is needed;
it is not embedded in or version-locked to a Hutch release.

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
side under `~/.dash/products`. The installer atomically refreshes the native
channel launcher, while `hutch self update` advances the engine pointer used on
the next invocation. The Unix installer adds `~/.dash/bin` to the detected
zsh, bash, fish, or POSIX shell profile and prints the command that activates it
in the current terminal. Pass `--no-modify-path` to only print that command.

## Project Pins

The first line of `dash.config.ts` can pin either layer:

```ts
// @dash cli=0.4.1 cottontail=0.2.3
```

Accepted selectors are `production`, `canary`, an exact semantic version, or
`build:<full-git-revision>`. The same pragma works in a directly invoked
JavaScript or TypeScript entrypoint. An entrypoint field overrides the matching
config field; omitted fields continue to use the invocation channel.

Malformed pragmas and unavailable releases are hard errors. A project pin never
replaces the global production or canary selection.

## Updates

```sh
hutch self update
hutch cottontail update
hutch update
```

Interactive use checks for newer active-channel releases at most every six
hours. The prompt can update, skip that specific revision, or defer. CI,
non-interactive commands, and `HUTCH_NO_UPDATE_CHECK=1` never prompt.

Use `hutch self path`, `hutch self version`, `hutch cottontail path`, and
`hutch cottontail version` to inspect the selected installations. Each command
also accepts an explicit selector.

## Development

```sh
bash hutch/scripts/setup.sh
cd hutch
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
`HUTCH_ENGINE_BINARY` overrides the engine (not the launcher). `DASH_HOME` changes
the global store and must remain set when a non-default install root is used.
`DASH_ARTIFACTS_BASE_URL` selects another trusted artifact origin.

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
`-canary`. macOS produces a DMG unless `build.mac.createDmg` is false. Windows
produces a Setup ZIP, and Linux produces a self-extracting installer tarball.
Set `release.baseUrl` to the published artifact root to generate a delta from
the previous release, or set `release.generatePatch` to false to skip it.

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

Hutch releases use product-scoped tags because this is a monorepo:

- `hutch-vX.Y.Z` advances `hutch/channels/production.json`.
- `hutch-vX.Y.Z-canary.N` advances `hutch/channels/canary.json`.

Run `hutch push:canary` to propose the next `canary.N` release, or
`hutch push:production` to propose a production version. Both commands allow
editing the proposed semantic version before they commit, tag, and atomically
push `main` and the product-scoped tag.

The CircleCI matrix builds macOS ARM64, Linux x64/ARM64, and Windows x64.
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
mutable channel pointer is written after every immutable archive and manifest.
Every published object remains under the `hutch/` bucket prefix. Tags are the
only workflow trigger.

The R2 publisher uses the Dash Cloud CircleCI project's shared `R2_ENDPOINT`,
`R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` settings. Those credentials must
have object-write access to the `electrobun-artifacts` bucket. The account ID is
derived from the endpoint unless `R2_ACCOUNT_ID` is set explicitly. The public
URL defaults to `https://hutch.blackboard.sh` and can be overridden independently
with `HUTCH_PUBLIC_BASE_URL`.

## Commands

- `hutch <entrypoint.js|entrypoint.ts> [args...]`
- `hutch <script-name> [args...]`
- `hutch run [script-name] [args...]`
- `hutch install [args...]`
- `hutch electrobun <init|build|run|dev> [args...]`
- `hutch self <path|version|update> [selector]`
- `hutch cottontail <path|version|update> [selector]`
- `hutch update`

Scripts resolve from the nearest `dash.config.ts` first and then
`package.json`. Package-manager and JavaScript commands are delegated to the
selected Cottontail release.
