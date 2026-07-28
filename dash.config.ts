// @dash cli=0.2.0-canary.4 cottontail=0.1.1-canary.2
export default {
  scripts: {
    smoke: "examples/smoke.js",
    echo: "echo hutch config script",
    "push:canary": "node scripts/tag-release.js canary",
    "push:production": "node scripts/tag-release.js production",
  },
};
