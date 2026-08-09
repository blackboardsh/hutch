import { existsSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

function positiveInteger(name, value) {
  if (!Number.isSafeInteger(value) || value < 1 || value > 2_147_483_647) {
    throw new TypeError(
      `${name} must be a positive safe integer no greater than 2147483647`,
    );
  }
  return value;
}

function packedReference(gitDirectory, reference) {
  const packedRefsPath = join(gitDirectory, "packed-refs");
  if (!existsSync(packedRefsPath)) return null;
  const record = readFileSync(packedRefsPath, "utf8")
    .split(/\r?\n/)
    .find(line => line.endsWith(` ${reference}`));
  return record?.split(" ", 1)[0] ?? null;
}

export function readGitHeadCommit(repositoryRoot) {
  const dotGitPath = join(repositoryRoot, ".git");
  let worktreeGitDirectory = dotGitPath;
  if (statSync(dotGitPath).isFile()) {
    const pointer = readFileSync(dotGitPath, "utf8").trim();
    const match = pointer.match(/^gitdir:\s*(.+)$/i);
    if (!match) throw new Error(`could not read Git directory pointer: ${dotGitPath}`);
    worktreeGitDirectory = resolve(repositoryRoot, match[1]);
  }
  const commonDirectoryPath = join(worktreeGitDirectory, "commondir");
  const commonGitDirectory = existsSync(commonDirectoryPath)
    ? resolve(worktreeGitDirectory, readFileSync(commonDirectoryPath, "utf8").trim())
    : worktreeGitDirectory;
  const gitDirectories = [...new Set([worktreeGitDirectory, commonGitDirectory])];

  const head = readFileSync(join(worktreeGitDirectory, "HEAD"), "utf8").trim();
  let commit = head;
  if (head.startsWith("ref: ")) {
    const reference = head.slice("ref: ".length);
    commit = "";
    for (const gitDirectory of gitDirectories) {
      const looseReference = join(gitDirectory, ...reference.split("/"));
      if (existsSync(looseReference)) {
        commit = readFileSync(looseReference, "utf8").trim();
        break;
      }
      commit = packedReference(gitDirectory, reference) ?? "";
      if (commit) break;
    }
  }
  if (!/^[0-9a-f]{40}$/.test(commit)) {
    throw new Error(`invalid Git HEAD commit: ${commit}`);
  }
  return commit;
}

export function createTestInvocation(entry, preloadPath, options) {
  const {
    defaultInnerTimeoutMs,
    defaultOuterTimeoutMs,
    defaultOuterMarginMs,
    overrideOuterMarginMs,
  } = options;
  positiveInteger("defaultInnerTimeoutMs", defaultInnerTimeoutMs);
  positiveInteger("defaultOuterTimeoutMs", defaultOuterTimeoutMs);
  positiveInteger("defaultOuterMarginMs", defaultOuterMarginMs);
  positiveInteger("overrideOuterMarginMs", overrideOuterMarginMs);

  if (!entry || typeof entry.path !== "string" || entry.path.length === 0) {
    throw new TypeError("test entry must have a path");
  }
  if (!Array.isArray(entry.args ?? [])) {
    throw new TypeError(`test args must be an array for ${entry.path}`);
  }

  const entryArgs = (entry.args ?? []).map(String);
  const argsWithoutTimeout = [];
  let innerTimeoutMs = null;
  for (let index = 0; index < entryArgs.length; index += 1) {
    const arg = entryArgs[index];
    let timeoutValue = null;
    if (arg === "--timeout") {
      if (index + 1 >= entryArgs.length) {
        throw new TypeError(`missing test timeout for ${entry.path}`);
      }
      timeoutValue = entryArgs[index + 1];
      index += 1;
    } else if (arg.startsWith("--timeout=")) {
      timeoutValue = arg.slice("--timeout=".length);
    } else {
      argsWithoutTimeout.push(arg);
      continue;
    }

    const parsedTimeout = Number(timeoutValue);
    positiveInteger(`test timeout for ${entry.path}`, parsedTimeout);
    if (innerTimeoutMs != null) {
      throw new TypeError(`multiple test timeouts configured for ${entry.path}`);
    }
    innerTimeoutMs = parsedTimeout;
  }

  const hasInnerOverride = innerTimeoutMs != null;
  innerTimeoutMs ??= defaultInnerTimeoutMs;
  let outerTimeoutMs = Number(entry.timeoutMs ?? defaultOuterTimeoutMs);
  if (!hasInnerOverride) {
    outerTimeoutMs = Math.max(
      outerTimeoutMs,
      innerTimeoutMs + defaultOuterMarginMs,
    );
  }
  positiveInteger(`outer timeout for ${entry.path}`, outerTimeoutMs);
  const requiredMarginMs = hasInnerOverride
    ? overrideOuterMarginMs
    : defaultOuterMarginMs;
  if (outerTimeoutMs - innerTimeoutMs < requiredMarginMs) {
    throw new TypeError(
      `outer timeout for ${entry.path} must exceed its ` +
      `${hasInnerOverride ? "overridden" : "default"} inner timeout by at least ` +
      `${requiredMarginMs}ms (${outerTimeoutMs}ms outer, ${innerTimeoutMs}ms inner)`,
    );
  }

  return {
    args: [
      "--preload",
      preloadPath,
      "test",
      `--timeout=${innerTimeoutMs}`,
      entry.path,
      ...argsWithoutTimeout,
    ],
    hasInnerOverride,
    innerTimeoutMs,
    outerTimeoutMs,
  };
}
