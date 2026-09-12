// @hutch cli=0.27.0-canary.3 cottontail=0.7.0-canary.4
export default {
  scripts: {
    smoke: ["hutch", "examples/smoke.js"],
    "smoke:bun-toolchain": ["hutch", "scripts/bun-toolchain-smoke.js"],
    echo: "echo hutch config script",
    "push:canary": "node scripts/tag-release.js canary",
    "push:production": "node scripts/tag-release.js production",
  },
};
