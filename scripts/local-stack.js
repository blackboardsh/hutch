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
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const hutchRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const dashCloudRoot = dirname(hutchRoot);
const projectsRoot = resolve(
	process.env.DASH_LOCAL_PROJECTS_ROOT || dirname(dashCloudRoot),
);
const cottontailRoot = resolve(
	process.env.DASH_LOCAL_COTTONTAIL_ROOT ||
		process.env.COTTONTAIL_ROOT ||
		join(projectsRoot, "cottontail"),
);
const electrobunRoot = resolve(
	process.env.DASH_LOCAL_ELECTROBUN_ROOT ||
		join(projectsRoot, "electrobun"),
);
const electrobunPackageRoot = join(electrobunRoot, "package");
const binaryExtension = process.platform === "win32" ? ".exe" : "";
const nodeBinary = process.env.NODE_BINARY || "node";
const cottontailBinary = join(
	cottontailRoot,
	"zig-out",
	"bin",
	`cottontail${binaryExtension}`,
);
const hutchBinary = join(
	hutchRoot,
	"zig-out",
	"bin",
	`hutch${binaryExtension}`,
);
const hutchEngineBinary = join(
	hutchRoot,
	"zig-out",
	"bin",
	`hutch-engine${binaryExtension}`,
);

function fail(message) {
	throw new Error(`[local-stack] ${message}`);
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

function addRepositoryPaths(hash, repository, pathspecs) {
	const tracked = run("git", ["ls-files", "-z", "--", ...pathspecs], {
		cwd: repository,
		capture: true,
	});
	const untracked = run(
		"git",
		["ls-files", "--others", "--exclude-standard", "-z", "--", ...pathspecs],
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

function electrobunFingerprint(hutchState) {
	const hash = createHash("sha256");
	hash.update(`electrobun-local-build-v1\0${process.platform}-${process.arch}\0`);
	hash.update(hutchState.fingerprint);
	hash.update("\0");
	hash.update(hutchState.cottontailFingerprint);
	hash.update("\0");
	addRepositoryPaths(hash, electrobunRoot, ["package", "templates"]);
	return hash.digest("hex");
}

function electrobunStateIsCurrent(statePath, expectedFingerprint) {
	const requiredOutputs = [
		join(electrobunPackageRoot, "dist"),
		join(electrobunPackageRoot, "dist", "main.js"),
	];
	if (
		!existsSync(statePath) ||
		requiredOutputs.some((output) => !existsSync(output))
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

function localEnvironment() {
	return {
		...process.env,
		DASH_LOCAL_STACK_ACTIVE: "1",
		DASH_LOCAL_PROJECTS_ROOT: projectsRoot,
		DASH_USE_LOCAL_COTTONTAIL: "1",
		DASH_LOCAL_COTTONTAIL_ROOT: cottontailRoot,
		COTTONTAIL_ROOT: cottontailRoot,
		DASH_COTTONTAIL: cottontailBinary,
		COTTONTAIL_BINARY: cottontailBinary,
		HUTCH_ROOT: hutchRoot,
		HUTCH_ENGINE_BINARY: hutchEngineBinary,
		HUTCH_BINARY: hutchBinary,
		DASH_USE_LOCAL_ELECTROBUN: "1",
		DASH_LOCAL_ELECTROBUN_ROOT: electrobunRoot,
	};
}

export function forceEnvironment(forceLayer) {
	const forceFrom = forceLayer === "all" ? "jsc" : forceLayer;
	const order = ["jsc", "cottontail", "hutch", "electrobun"];
	const firstForcedIndex = forceFrom === null ? order.length : order.indexOf(forceFrom);
	const forces = (layer) => firstForcedIndex <= order.indexOf(layer);
	return {
		...(forces("jsc")
			? { DASH_LOCAL_REBUILD_JSC: "1" }
			: {}),
		...(forces("cottontail")
			? { DASH_LOCAL_REBUILD_COTTONTAIL: "1" }
			: {}),
		...(forces("hutch")
			? { DASH_LOCAL_REBUILD_HUTCH: "1" }
			: {}),
		...(forces("electrobun")
			? { DASH_LOCAL_REBUILD_ELECTROBUN: "1" }
			: {}),
	};
}

function buildHutchDependencies(noDeps, forceLayer) {
	const buildScript = join(hutchRoot, "scripts", "build-local.js");
	if (!existsSync(buildScript)) fail(`Hutch local build script is missing: ${buildScript}`);
	const args = [buildScript];
	if (noDeps) args.push("--no-deps");
	if (
		forceLayer === "all" ||
		forceLayer === "jsc" ||
		forceLayer === "cottontail" ||
		forceLayer === "hutch"
	) {
		args.push("--force");
	}
	run(nodeBinary, args, {
		cwd: hutchRoot,
		env: {
			...process.env,
			...forceEnvironment(forceLayer),
			DASH_LOCAL_PROJECTS_ROOT: projectsRoot,
			DASH_LOCAL_COTTONTAIL_ROOT: cottontailRoot,
			COTTONTAIL_ROOT: cottontailRoot,
		},
	});
}

function buildElectrobun(force) {
	if (!existsSync(join(electrobunPackageRoot, "build.ts"))) {
		fail(`sibling Electrobun package is missing: ${electrobunPackageRoot}`);
	}
	const hutchStatePath = join(hutchRoot, "zig-out", "local-build.json");
	if (
		!existsSync(hutchStatePath) ||
		!existsSync(hutchBinary) ||
		!existsSync(hutchEngineBinary)
	) {
		fail(`local Hutch output is missing after its build step`);
	}
	const hutchState = readJson(hutchStatePath);
	const expectedFingerprint = electrobunFingerprint(hutchState);
	const statePath = join(
		electrobunPackageRoot,
		"vendors",
		".local-stack-build.json",
	);
	if (!force && electrobunStateIsCurrent(statePath, expectedFingerprint)) {
		console.log(`[local-stack] Using cached Electrobun package`);
		return;
	}

	console.log(`[local-stack] Building Electrobun with ${hutchBinary}`);
	run(hutchBinary, [join(electrobunPackageRoot, "build.ts")], {
		cwd: electrobunPackageRoot,
		env: localEnvironment(),
	});

	const completedFingerprint = electrobunFingerprint(hutchState);
	mkdirSync(dirname(statePath), { recursive: true });
	writeFileSync(
		statePath,
		`${JSON.stringify(
			{
				schema: 1,
				platform: `${process.platform}-${process.arch}`,
				fingerprint: completedFingerprint,
				hutchFingerprint: hutchState.fingerprint,
				cottontailFingerprint: hutchState.cottontailFingerprint,
				builtAt: new Date().toISOString(),
			},
			null,
			2,
		)}\n`,
	);
}

export function parseArgs(
	args = process.argv.slice(2),
	environment = process.env,
) {
	let through = "electrobun";
	let noDeps = false;
	let forceLayer = null;
	for (const arg of args) {
		if (arg.startsWith("--through=")) {
			through = arg.slice("--through=".length);
		} else if (arg === "--no-deps") {
			noDeps = true;
		} else if (arg === "--force") {
			forceLayer = "all";
		} else if (arg.startsWith("--force=")) {
			forceLayer = arg.slice("--force=".length);
		} else {
			fail(`unknown option: ${arg}`);
		}
	}
	if (!["hutch", "electrobun"].includes(through)) {
		fail(`--through must be hutch or electrobun`);
	}
	if (
		forceLayer !== null &&
		!["jsc", "cottontail", "hutch", "electrobun", "all"].includes(forceLayer)
	) {
		fail(`--force must name jsc, cottontail, hutch, electrobun, or all`);
	}
	if (forceLayer === null) {
		for (const [layer, variable] of [
			["jsc", "DASH_LOCAL_REBUILD_JSC"],
			["cottontail", "DASH_LOCAL_REBUILD_COTTONTAIL"],
			["hutch", "DASH_LOCAL_REBUILD_HUTCH"],
			["electrobun", "DASH_LOCAL_REBUILD_ELECTROBUN"],
		]) {
			if (
				["1", "true", "yes"].includes(
					String(environment[variable] || "").toLowerCase(),
				)
			) {
				forceLayer = layer;
				break;
			}
		}
	}
	return { through, noDeps, forceLayer };
}

function main() {
	const { through, noDeps, forceLayer } = parseArgs();
	buildHutchDependencies(noDeps, forceLayer);
	const forceElectrobun =
		forceLayer !== null ||
		["1", "true", "yes"].includes(
			String(process.env.DASH_LOCAL_REBUILD_ELECTROBUN || "").toLowerCase(),
		);
	if (through === "electrobun") buildElectrobun(forceElectrobun);
	console.log(
		JSON.stringify({
			projectsRoot,
			cottontailRoot,
			cottontailBinary,
			hutchRoot,
			hutchBinary,
			hutchEngineBinary,
			electrobunRoot,
			electrobunPackageRoot,
			through,
		}),
	);
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
	try {
		main();
	} catch (error) {
		console.error(error instanceof Error ? error.message : String(error));
		process.exit(1);
	}
}
