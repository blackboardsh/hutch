// @hutch cli=0.5.0-canary.12 cottontail=0.2.3
export default {
  scripts: {
    smoke: "examples/smoke.js",
    echo: "echo hutch config script",
    "push:canary": "node scripts/tag-release.js canary",
    "push:production": "node scripts/tag-release.js production",
  },
};
