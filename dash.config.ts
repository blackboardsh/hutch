// @dash cli=0.3.0-canary.2 cottontail=0.2.2
export default {
  scripts: {
    smoke: "examples/smoke.js",
    echo: "echo hutch config script",
    "push:canary": "node scripts/tag-release.js canary",
    "push:production": "node scripts/tag-release.js production",
  },
};
