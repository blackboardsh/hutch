import { realpathSync } from "node:fs";
import { resolve } from "node:path";
import { setDefaultTimeout } from "bun:test";
import { install_test_helpers } from "bun:internal-for-testing";

const hutchPath = process.env.HUTCH_COMPAT_CLI;
const cottontailPath = process.env.HUTCH_COMPAT_COTTONTAIL ?? process.env.COTTONTAIL_BINARY;

if (!hutchPath) {
  throw new Error("HUTCH_COMPAT_CLI is required by the Hutch package-manager test preload");
}
if (!cottontailPath) {
  throw new Error("HUTCH_COMPAT_COTTONTAIL is required by the Hutch package-manager test preload");
}

const hutchExecutable = realpathSync.native(resolve(hutchPath));
const cottontailExecutable = realpathSync.native(resolve(cottontailPath));
if (hutchExecutable === cottontailExecutable) {
  throw new Error("Hutch child CLI and Cottontail test runtime must be different executables");
}

const preloadKey = Symbol.for("hutch.bunPackageManagerCompatPreload");
const previous = (globalThis as any)[preloadKey];
if (previous && previous !== hutchExecutable) {
  throw new Error(`Hutch package-manager preload already selected a different CLI: ${previous}`);
}

Object.defineProperty(globalThis, preloadKey, {
  configurable: false,
  enumerable: false,
  value: hutchExecutable,
});

// Bun's harness implements bunExe() with process.execPath. Only the outer
// Cottontail test process is rewritten; Hutch receives the original runtime
// path through COTTONTAIL_BINARY and forwards runtime commands to it.
Object.defineProperty(process, "execPath", {
  configurable: true,
  enumerable: true,
  value: hutchExecutable,
  writable: true,
});

process.env.COTTONTAIL_BINARY = cottontailExecutable;
process.env.DASH_COTTONTAIL = cottontailExecutable;

// Cottontail's captured subprocess streams can report the currently buffered
// bytes before the child closes its pipe. Bun's streams settle at EOF. Preserve
// that contract for Hutch child commands so upstream package-manager tests do
// not race a still-running engine process.
const nativeSpawn = Bun.spawn.bind(Bun);
const activePackageManagerMutations = new Set<Promise<number>>();
const waitForCapturedText = (stream: any, exited: Promise<number>) => {
  if (!stream || typeof stream.text !== "function") return;
  let settled: Promise<string> | undefined;
  stream.text = () => {
    settled ??= (async () => {
      const reader = stream.getReader();
      const decoder = new TextDecoder();
      let output = "";
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        output += typeof value === "string" ? value : decoder.decode(value, { stream: true });
      }
      output += decoder.decode();
      await exited;
      return output;
    })();
    return settled;
  };
};

Bun.spawn = ((...args: any[]) => {
  const subprocess = nativeSpawn(...args);
  const command = Array.isArray(args[0]) ? args[0] : args[0]?.cmd;
  if (Array.isArray(command) && command.length > 0) {
    let executable: string | undefined;
    try {
      executable = realpathSync.native(resolve(String(command[0])));
    } catch {}
    if (executable === hutchExecutable) {
      const exited = Promise.resolve(subprocess.exited);
      activePackageManagerMutations.add(exited);
      void exited.then(
        () => activePackageManagerMutations.delete(exited),
        () => activePackageManagerMutations.delete(exited),
      );
      waitForCapturedText(subprocess.stdout, subprocess.exited);
      waitForCapturedText(subprocess.stderr, subprocess.exited);
    }
  }
  return subprocess;
}) as typeof Bun.spawn;

const nativeFile = Bun.file.bind(Bun);
const mutationDependentFileMethods = new Set(["arrayBuffer", "bytes", "exists", "json", "text"]);
Bun.file = ((...args: any[]) => {
  const file = nativeFile(...args);
  return new Proxy(file, {
    get(target, property, receiver) {
      const value = Reflect.get(target, property, receiver);
      if (typeof value !== "function") return value;
      if (!mutationDependentFileMethods.has(String(property))) return value.bind(target);
      return async (...methodArgs: any[]) => {
        const pending = [...activePackageManagerMutations];
        if (pending.length > 0) await Promise.allSettled(pending);
        return value.apply(target, methodArgs);
      };
    },
  });
}) as typeof Bun.file;

// Cottontail's newer lockfile debug formatter hydrates a bare `workspace:`
// dependency from its resolved package. Bun v1.3.10 exposed the empty protocol
// suffix in parseLockfile(), so retain that versioned internal-test contract.
const nativeParseLockfile = install_test_helpers.parseLockfile.bind(install_test_helpers);
install_test_helpers.parseLockfile = (cwd: string) => {
  const lockfile = nativeParseLockfile(cwd);
  for (const dependency of lockfile?.dependencies ?? []) {
    if (dependency?.literal === "workspace:" && "workspace" in dependency) {
      dependency.workspace = "";
    }
  }
  return lockfile;
};

const testTimeout = Number(process.env.HUTCH_COMPAT_TEST_TIMEOUT_MS);
if (Number.isFinite(testTimeout) && testTimeout > 0) {
  setDefaultTimeout(testTimeout);
}
