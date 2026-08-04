#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
	existsSync,
	mkdirSync,
	readFileSync,
	statSync,
	writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const hutchRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const projectsRoot = resolve(
	process.env.DASH_LOCAL_PROJECTS_ROOT || dirname(hutchRoot),
);
const nodeBinary = process.env.NODE_BINARY || "node";
const cottontailRoot = resolve(
	process.env.DASH_LOCAL_COTTONTAIL_ROOT ||
		process.env.COTTONTAIL_ROOT ||
		join(projectsRoot, "cottontail"),
);
const cottontailBinary = join(
	cottontailRoot,
	"zig-out",
	"bin",
	process.platform === "win32" ? "cottontail.exe" : "cottontail",
);
const hutchBinary = join(
	hutchRoot,
	"zig-out",
	"bin",
	process.platform === "win32" ? "hutch.exe" : "hutch",
);
const hutchEngineBinary = join(
	hutchRoot,
	"zig-out",
	"bin",
	process.platform === "win32" ? "hutch-engine.exe" : "hutch-engine",
);

function fail(message) {
	throw new Error(`[local-hutch] ${message}`);
}

function run(command, args, options = {}) {
	const result = spawnSync(command, args, {
		cwd: options.cwd || hutchRoot,
		env: options.env || process.env,
		encoding: options.capture ? "utf8" : undefined,
		stdio: options.capture ? ["ignore", "pipe", "pipe"] : "inherit",
	});
	if (result.error) fail(`could not start ${command}: ${result.error.message}`);
	if (result.status !== 0) {
		const detail = options.capture
			? `\n${String(result.stderr || result.stdout || "").trim()}`
			: "";
		fail(`${command} exited with status ${result.status ?? 1}${detail}`);
	}
	return options.capture ? String(result.stdout).trim() : "";
}

function readJson(path) {
	return JSON.parse(readFileSync(path, "utf8"));
}

function addHutchSource(hash) {
	const repository = run("git", ["rev-parse", "--show-toplevel"], {
		cwd: hutchRoot,
		capture: true,
	});
	const pathspec = relative(repository, hutchRoot).replaceAll("\\", "/");
	const inputs = [
		`${pathspec}/build.zig`,
		`${pathspec}/src`,
		`${pathspec}/scripts/build-local.js`,
		`${pathspec}/scripts/build.sh`,
		`${pathspec}/scripts/setup.sh`,
		`${pathspec}/scripts/zig.sh`,
	];
	const tracked = run("git", ["ls-files", "-z", "--", ...inputs], {
		cwd: repository,
		capture: true,
	});
	const untracked = run(
		"git",
		["ls-files", "--others", "--exclude-standard", "-z", "--", ...inputs],
		{ cwd: repository, capture: true },
	);
	const paths = new Set(
		`${tracked}\0${untracked}`.split("\0").filter(Boolean),
	);
	for (const relativePath of [...paths].sort()) {
		const path = join(repository, relativePath);
		hash.update(relativePath);
		hash.update("\0");
		if (!existsSync(path) || !statSync(path).isFile()) {
			hash.update("missing");
		} else {
			hash.update(readFileSync(path));
		}
		hash.update("\0");
	}
}

function fingerprint(cottontailFingerprint) {
	const hash = createHash("sha256");
	hash.update(`hutch-local-build-v1\0${process.platform}-${process.arch}\0`);
	hash.update(cottontailFingerprint);
	hash.update("\0");
	addHutchSource(hash);
	return hash.digest("hex");
}

function stateIsCurrent(statePath, expectedFingerprint) {
	if (
		!existsSync(statePath) ||
		!existsSync(hutchBinary) ||
		!existsSync(hutchEngineBinary)
	) {
		return false;
	}
	try {
		const state = readJson(statePath);
		return state.schema === 1 && state.fingerprint === expectedFingerprint;
	} catch {
		return false;
	}
}

function main() {
	const cottontailBuildScript = join(
		cottontailRoot,
		"scripts",
		"build-local.js",
	);
	if (!existsSync(cottontailBuildScript)) {
		fail(`local Cottontail checkout is missing: ${cottontailRoot}`);
	}
	if (!process.argv.includes("--no-deps")) {
		run(nodeBinary, [cottontailBuildScript], {
			cwd: cottontailRoot,
			env: {
				...process.env,
				COTTONTAIL_ROOT: cottontailRoot,
			},
		});
	}

	const cottontailStatePath = join(
		cottontailRoot,
		"zig-out",
		"local-build.json",
	);
	if (!existsSync(cottontailStatePath) || !existsSync(cottontailBinary)) {
		fail(
			`local Cottontail output is missing; run ${cottontailBuildScript} first`,
		);
	}
	const cottontailState = readJson(cottontailStatePath);
	const expectedFingerprint = fingerprint(cottontailState.fingerprint);
	const statePath = join(hutchRoot, "zig-out", "local-build.json");
	const force =
		process.argv.includes("--force") ||
		["1", "true", "yes"].includes(
			String(process.env.DASH_LOCAL_REBUILD_HUTCH || "").toLowerCase(),
		);
	if (!force && stateIsCurrent(statePath, expectedFingerprint)) {
		console.log(`[local-hutch] Using cached ${hutchBinary}`);
		console.log(
			JSON.stringify({
				binaryPath: hutchBinary,
				enginePath: hutchEngineBinary,
				cottontailBinary,
				fingerprint: expectedFingerprint,
			}),
		);
		return;
	}

	const env = {
		...process.env,
		DASH_SKIP_COTTONTAIL_SETUP: "1",
		DASH_USE_LOCAL_COTTONTAIL: "1",
		DASH_LOCAL_COTTONTAIL_ROOT: cottontailRoot,
		COTTONTAIL_ROOT: cottontailRoot,
		COTTONTAIL_BINARY: cottontailBinary,
	};
	console.log(`[local-hutch] Building against ${cottontailBinary}`);
	run("bash", [join(hutchRoot, "scripts", "build.sh"), "build"], { env });

	const completedFingerprint = fingerprint(cottontailState.fingerprint);
	mkdirSync(dirname(statePath), { recursive: true });
	writeFileSync(
		statePath,
		`${JSON.stringify(
			{
				schema: 1,
				platform: `${process.platform}-${process.arch}`,
				fingerprint: completedFingerprint,
				cottontailFingerprint: cottontailState.fingerprint,
				cottontailBinary,
				binaryPath: hutchBinary,
				enginePath: hutchEngineBinary,
				builtAt: new Date().toISOString(),
			},
			null,
			2,
		)}\n`,
	);
	console.log(
		JSON.stringify({
			binaryPath: hutchBinary,
			enginePath: hutchEngineBinary,
			cottontailBinary,
			fingerprint: completedFingerprint,
		}),
	);
}

try {
	main();
} catch (error) {
	console.error(error instanceof Error ? error.message : String(error));
	process.exit(1);
}
