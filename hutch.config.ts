// @hutch cli=0.18.0 cottontail=0.5.0
export default {
  scripts: {
    smoke: ["hutch", "examples/smoke.js"],
    "smoke:bun-toolchain": ["hutch", "scripts/bun-toolchain-smoke.js"],
    echo: "echo hutch config script",
    "push:canary": "node scripts/tag-release.js canary",
    "push:production": "node scripts/tag-release.js production",
  },
};
