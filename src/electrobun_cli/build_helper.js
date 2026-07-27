import { mkdirSync } from "node:fs";
import { basename, dirname, join } from "node:path";

const specPath = process.argv[2];
if (!specPath) {
  console.error("hutch: missing Cottontail build specification");
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
if (outfile) delete options.outdir;
else if (outdir) options.outdir = outdir;

try {
  const result = await Bun.build(options);
  if (!result.success) {
    for (const log of result.logs ?? []) console.error(log.rendered ?? String(log));
    process.exit(1);
  }

  if (outfile) {
    mkdirSync(dirname(outfile), { recursive: true });
    const entryOutput = result.outputs.find((output) => output.kind === "entry-point") ?? result.outputs[0];
    if (!entryOutput) throw new Error("Cottontail build produced no entry-point output");
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
