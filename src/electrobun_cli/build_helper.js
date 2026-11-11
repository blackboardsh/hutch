import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { isBuiltin } from "node:module";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";

// Run in an isolated Bun process: nested Bun.build calls from onResolve can
// deadlock. Capture the native build resolver's selected file without loading
// its contents or executing any package code.
async function probePackageAlias({ specifier, root, target, conditions, tsconfig, kind }) {
  const namespace = "hutch-alias-probe";
  const entry = `${namespace}:${root}/__alias_probe__.js`;
  let resolved;
  const result = await Bun.build({
    root, target, conditions, tsconfig, entrypoints: [entry], format: "esm", write: false,
    plugins: [{
      name: namespace,
      setup(build) {
        build.onResolve({ filter: /.*/ }, ({ path }) => path === entry
          ? { path: entry.slice(namespace.length + 1), namespace }
          : undefined);
        build.onLoad({ filter: /.*/, namespace }, () => ({
          contents: kind.startsWith("require")
            ? `console.log(require(${JSON.stringify(specifier)}));`
            : `import * as value from ${JSON.stringify(specifier)}; console.log(value);`,
          loader: "js", resolveDir: root,
        }));
        build.onLoad({ filter: /.*/, namespace: "file" }, ({ path }) => {
          resolved = path;
          return { contents: "", loader: "js" };
        });
      },
    }],
  });
  if (!result.success) {
    throw new Error((result.logs ?? []).map(String).join("\n") || `Could not resolve alias target "${specifier}"`);
  }
  // Browser builtins and disabled browser mappings can resolve successfully
  // without a file. Let the parent bundler preserve those native modules.
  return { path: resolved ?? null };
}

async function resolvePackageAlias(request) {
  const directory = mkdtempSync(join(tmpdir(), "hutch-alias-"));
  try {
    const bunfig = join(directory, "bunfig.toml");
    writeFileSync(bunfig, "", { mode: 0o600 });
    const environment = { ...process.env };
    delete environment.BUN_OPTIONS;
    delete environment.NODE_OPTIONS;
    const source = `(${probePackageAlias.toString()})(${JSON.stringify(request)})` +
      ".then(value => console.log(JSON.stringify(value))).catch(error => { console.error(error); process.exitCode = 1; });";
    const child = Bun.spawn([process.execPath, "--no-env-file", `--config=${bunfig}`, "--eval", source], {
      cwd: request.root, env: environment, stdout: "pipe", stderr: "pipe",
    });
    const [status, output, errors] = await Promise.all([
      child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
    ]);
    if (status !== 0) throw new Error(errors || `Could not resolve alias target "${request.specifier}"`);
    return JSON.parse(output);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

const specPath = process.argv[2];
if (!specPath) {
  console.error("hutch: missing JavaScript build specification");
  process.exit(2);
}

const input = JSON.parse(await Bun.file(specPath).text());
const outfile = input.outfile ? String(input.outfile) : null;
const outdir = input.outdir ? String(input.outdir) : null;
const platform = String(input.platform ?? "neutral");
const requestedTarget = typeof input.target === "string" ? input.target : null;
const runtimeTarget = ["browser", "bun", "node"].includes(requestedTarget)
  ? requestedTarget
  : platform === "browser"
    ? "browser"
    : platform === "node"
      ? "node"
      : "bun";

const options = {
  ...input,
  entrypoints: input.entrypoints ?? input.entryPoints ?? [],
  target: runtimeTarget,
  write: false,
};
delete options.entryPoints;
delete options.outfile;
delete options.platform;
if (Array.isArray(input.target) || (requestedTarget && !["browser", "bun", "node"].includes(requestedTarget))) {
  options.target = runtimeTarget;
}

// Bun.build writes whenever outdir is present. Keep outfile builds in memory so
// Hutch can preserve the exact destination filename expected by Electrobun.
if (outfile) {
  delete options.outdir;
  // Keep generated source-map references consistent with Hutch's exact output
  // filename, including main entrypoints that are not named index.ts.
  options.naming = {
    ...(typeof options.naming === "object" ? options.naming : {}),
    entry: basename(outfile),
  };
} else if (outdir) options.outdir = outdir;

try {
  // Bun.build ignores esbuild's alias option, while Cottontail handles it
  // natively. Alias replacements resolve from the project directory,
  // independent of the importing module's location.
  if (!process.versions.cottontail && options.alias) {
    const workingDirectory = process.cwd();
    for (const [name, replacement] of Object.entries(options.alias)) {
      if (!name || typeof replacement !== "string" || !replacement) {
        throw new TypeError("JavaScript build aliases must have nonempty string names and replacements");
      }
      if (replacement.startsWith(".")) options.alias[name] = resolve(workingDirectory, replacement);
    }
    const aliases = Object.entries(options.alias).sort(([left], [right]) => right.length - left.length);
    const externalPatterns = (options.external ?? []).map((pattern) => {
      const normalized = pattern.startsWith(".") ? resolve(workingDirectory, pattern) : pattern;
      const escaped = normalized.split("*").map((part) => part.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*");
      return new RegExp(`^${escaped}${isAbsolute(normalized) ? "$" : "(?:/.*)?$"}`);
    });
    const packageResolutions = new Map();
    const virtualAliases = new Map();
    const virtualNamespace = "hutch-native-alias";
    delete options.alias;
    options.plugins = [...(options.plugins ?? []), {
      name: "hutch-build-aliases",
      setup(build) {
        build.onLoad({ filter: /.*/, namespace: virtualNamespace }, ({ path }) => {
          const { specifier, kind } = virtualAliases.get(path);
          const quoted = JSON.stringify(specifier);
          return {
            contents: kind.startsWith("require")
              ? `module.exports = require(${quoted});`
              : `export * from ${quoted}; export { default } from ${quoted};`,
            loader: "js", resolveDir: workingDirectory,
          };
        });
        build.onResolve({ filter: /.*/ }, async ({ path, kind, namespace }) => {
          // The forwarding module must resolve the replacement natively,
          // rather than applying aliases again to the substituted specifier.
          if (namespace === virtualNamespace) return;
          const alias = aliases.find(([name]) => path === name || path.startsWith(`${name}/`));
          if (!alias) return;
          const replacement = `${alias[1]}${path.slice(alias[0].length)}`;
          const target = replacement.startsWith(".") ? resolve(workingDirectory, replacement) : replacement;
          if (externalPatterns.some((pattern) => pattern.test(target)) ||
              (runtimeTarget !== "browser" && (isBuiltin(target) || target.startsWith("bun:")))) {
            return { path: target, external: true };
          }
          let resolved;
          if (isAbsolute(target)) {
            resolved = Bun.resolveSync(target, workingDirectory);
          } else {
            // Runtime resolution always uses Bun's conditions. Package aliases
            // must instead use the browser/node/bun target of this bundle.
            const request = {
              specifier: target, root: workingDirectory, target: runtimeTarget,
              conditions: options.conditions, tsconfig: options.tsconfig, kind,
            };
            const key = JSON.stringify(request);
            if (!packageResolutions.has(key)) {
              packageResolutions.set(key, resolvePackageAlias(request).then((result) => {
                if (result.path !== null) return result;
                const path = `alias-${virtualAliases.size}`;
                virtualAliases.set(path, request);
                return { path, namespace: virtualNamespace };
              }));
            }
            const result = await packageResolutions.get(key);
            if (result.namespace) return result;
            resolved = result.path;
          }
          const external = externalPatterns.some((pattern) => pattern.test(resolved));
          return { path: resolved, external };
        });
      },
    }];
  }
  const result = await Bun.build(options);
  if (!result.success) {
    for (const log of result.logs ?? []) console.error(log.rendered ?? String(log));
    process.exit(1);
  }

  if (outfile) {
    mkdirSync(dirname(outfile), { recursive: true });
    const entryOutput = result.outputs.find((output) => output.kind === "entry-point") ?? result.outputs[0];
    if (!entryOutput) throw new Error("JavaScript build produced no entry-point output");
    await Bun.write(outfile, entryOutput);

    for (const output of result.outputs) {
      if (output === entryOutput) continue;
      const outputName = basename(output.path);
      const destination = outputName.endsWith(".js.map")
        ? `${outfile}.map`
        : join(dirname(outfile), outputName);
      await Bun.write(destination, output);
    }
  }
} catch (error) {
  if (error instanceof AggregateError) {
    for (const buildError of error.errors ?? []) {
      console.error(buildError?.rendered ?? buildError?.stack ?? String(buildError));
    }
  } else {
    console.error(error?.stack ?? String(error));
  }
  process.exit(1);
}
