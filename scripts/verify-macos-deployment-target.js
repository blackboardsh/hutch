#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";

export function compareVersions(left, right) {
  const leftParts = left.split(".").map(Number);
  const rightParts = right.split(".").map(Number);
  const length = Math.max(leftParts.length, rightParts.length);
  for (let index = 0; index < length; index += 1) {
    const difference = (leftParts[index] ?? 0) - (rightParts[index] ?? 0);
    if (difference !== 0) return Math.sign(difference);
  }
  return 0;
}

export function deploymentTargets(otoolOutput) {
  const targets = [];
  let command = null;

  for (const line of otoolOutput.split(/\r?\n/)) {
    const commandMatch = line.match(
      /^\s*cmd\s+(LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX)\s*$/,
    );
    if (commandMatch) {
      command = commandMatch[1];
      continue;
    }
    if (/^\s*(?:Load command \d+|cmd\s+)/.test(line)) {
      command = null;
      continue;
    }

    const targetMatch = command === "LC_BUILD_VERSION"
      ? line.match(/^\s*minos\s+(\d+(?:\.\d+){0,2})\s*$/)
      : command === "LC_VERSION_MIN_MACOSX"
        ? line.match(/^\s*version\s+(\d+(?:\.\d+){0,2})\s*$/)
        : null;
    if (targetMatch) {
      targets.push(targetMatch[1]);
      command = null;
    }
  }

  return targets;
}

export function verifyOtoolOutput(binaryPath, output, maximum) {
  if (!/^\d+(?:\.\d+){0,2}$/.test(maximum)) {
    throw new Error(`invalid maximum macOS deployment target: ${maximum}`);
  }

  const targets = deploymentTargets(output);
  if (targets.length === 0) {
    throw new Error(`${binaryPath} does not declare a macOS deployment target`);
  }
  const unsupported = targets.filter(
    (target) => compareVersions(target, maximum) > 0,
  );
  if (unsupported.length > 0) {
    unsupported.sort(compareVersions);
    throw new Error(
      `${binaryPath} requires macOS ${unsupported.at(-1)}, above macOS ${maximum}`,
    );
  }
  targets.sort(compareVersions);
  return targets.at(-1);
}

export function verifyMacosDeploymentTarget(binaryPath, maximum) {
  const result = spawnSync("otool", ["-l", binaryPath], {
    encoding: "utf8",
  });
  if (result.error) {
    throw new Error(`could not run otool for ${binaryPath}: ${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(
      `otool failed for ${binaryPath}: ${String(result.stderr || result.stdout).trim()}`,
    );
  }
  return verifyOtoolOutput(binaryPath, result.stdout, maximum);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [, , binaryPath, maximum] = process.argv;
  if (!binaryPath || !maximum) {
    console.error(
      "Usage: verify-macos-deployment-target.js <Mach-O path> <maximum version>",
    );
    process.exit(2);
  }
  try {
    const observed = verifyMacosDeploymentTarget(binaryPath, maximum);
    console.log(`OK ${binaryPath} requires at most macOS ${observed}`);
  } catch (error) {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  }
}
