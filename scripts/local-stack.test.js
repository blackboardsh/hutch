#!/usr/bin/env node

import assert from "node:assert/strict";
import { forceEnvironment, parseArgs } from "./local-stack.js";

assert.deepEqual(parseArgs([], {}), {
	through: "electrobun",
	noDeps: false,
	forceLayer: null,
});
assert.deepEqual(parseArgs(["--through=hutch", "--no-deps"], {}), {
	through: "hutch",
	noDeps: true,
	forceLayer: null,
});
assert.equal(
	parseArgs([], { DASH_LOCAL_REBUILD_COTTONTAIL: "yes" }).forceLayer,
	"cottontail",
);
assert.equal(parseArgs(["--force=jsc"], {}).forceLayer, "jsc");
assert.throws(() => parseArgs(["--through=desktop"], {}), /--through/);
assert.throws(() => parseArgs(["--force=desktop"], {}), /--force/);

assert.deepEqual(forceEnvironment(null), {});
assert.deepEqual(forceEnvironment("electrobun"), {
	DASH_LOCAL_REBUILD_ELECTROBUN: "1",
});
assert.deepEqual(forceEnvironment("hutch"), {
	DASH_LOCAL_REBUILD_HUTCH: "1",
	DASH_LOCAL_REBUILD_ELECTROBUN: "1",
});
assert.deepEqual(forceEnvironment("cottontail"), {
	DASH_LOCAL_REBUILD_COTTONTAIL: "1",
	DASH_LOCAL_REBUILD_HUTCH: "1",
	DASH_LOCAL_REBUILD_ELECTROBUN: "1",
});
assert.deepEqual(forceEnvironment("jsc"), {
	DASH_LOCAL_REBUILD_JSC: "1",
	DASH_LOCAL_REBUILD_COTTONTAIL: "1",
	DASH_LOCAL_REBUILD_HUTCH: "1",
	DASH_LOCAL_REBUILD_ELECTROBUN: "1",
});
assert.deepEqual(forceEnvironment("all"), forceEnvironment("jsc"));

console.log("Local stack argument and force plan passed");
