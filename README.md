# Hutch

Hutch is the native build and workspace CLI for Electrobun projects. Its global
installation has two parts:

- `hutch`, a small launcher that reads an optional project version pragma.
- `hutch-engine`, the versioned engine that owns scripts, builds, package management,
  toolchains, and Electrobun orchestration.

Cottontail is an independently released runtime. Hutch resolves it from the same
global content store when JavaScript execution or package management is needed;
it is not embedded in or version-locked to a Hutch release.

The intended build/runtime ownership and migration path are documented in
[docs/cottontail-runtime-boundary.md](docs/cottontail-runtime-boundary.md).

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

## Updates

```sh
hutch self update
hutch cottontail update
```

Interactive use checks for newer active-channel releases at most every six
hours. The prompt can update, skip that specific revision, or defer. CI,
non-interactive commands, and `HUTCH_NO_UPDATE_CHECK=1` never prompt.

Use `hutch self path`, `hutch self version`, `hutch cottontail path`, and
`hutch cottontail version` to inspect the selected installations. Each command
also accepts an explicit selector.

## Development

```sh
bash scripts/setup.sh
./vendors/zig/zig build test
./vendors/zig/zig build
./zig-out/bin/hutch --version
node scripts/run-bun-package-manager-tests.js --check
node scripts/run-local-package-manager-tests.js --all
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
Run `node scripts/run-bun-package-manager-tests.js --all --jobs 4` for the
complete 103-file copied compatibility suite. The ownership boundary and
measured compatibility accounting are documented in
[docs/cottontail-runtime-boundary.md](docs/cottontail-runtime-boundary.md).

## Electrobun Projects

Run `hutch electrobun init` to choose a release template interactively, then
accept or replace its suggested project name. The chosen name controls the
created directory and the printed next steps. The following spelling is a
direct alias and does not install the Electrobun npm package:

```sh
hutch x electrobun init
```

The published Electrobun npm package also delegates `npx electrobun init` and
`bunx electrobun init` to this command, installing the matching Hutch channel
when needed. Starter templates always come from the latest production or
canary Electrobun catalog rather than from an npm package version.

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
mutable channel pointer is written after every immutable archive and manifest.
Every published object remains under the `hutch/` bucket prefix. Tags are the
only workflow trigger.

The GitHub repository requires `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, and
`R2_SECRET_ACCESS_KEY` Actions secrets. Those credentials must have object-write
access to the `electrobun-artifacts` bucket. The public URL defaults to
`https://hutch.blackboard.sh` and can be overridden independently with
`HUTCH_PUBLIC_BASE_URL` for local publishing. No public-URL secret is required
for the release workflow.

## Commands

- `hutch <entrypoint.js|entrypoint.ts> [args...]`
- `hutch <script-name> [args...]`
- `hutch run [script-name] [args...]`
- `hutch install|add|remove|update [args...]`
- `hutch init|create|x [args...]`
- `hutch build [args...]`
- `hutch electrobun <init|build|run|dev> [args...]`
- `hutch self <path|version|update> [selector]`
- `hutch cottontail <path|version|update> [selector]`

Scripts resolve exclusively from the nearest `hutch.config.ts`. A script may
be a shell command string or a non-empty argv array; invocation arguments are
appended to either form:

```ts
export default {
  scripts: {
    dev: ["npm", "run", "dev"],
    deps: ["pnpm", "install"],
    lint: "eslint .",
  },
};
```

Hutch does not inspect `package.json`, add `node_modules/.bin` to `PATH`, or
emulate npm lifecycle variables when running these tasks. The configured
package manager owns those semantics. Hutch's existing package-management
commands remain available during the package-manager extraction.
