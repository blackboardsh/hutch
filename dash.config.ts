// @dash cli=0.3.0-canary.1 cottontail=0.2.0-canary.1
export default {
  scripts: {
    smoke: "examples/smoke.js",
    echo: "echo hutch config script",
    "push:canary": "node scripts/tag-release.js canary",
    "push:production": "node scripts/tag-release.js production",
  },
};
