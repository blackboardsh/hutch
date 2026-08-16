// @hutch cli=0.11.0 cottontail=0.5.0
export default {
  scripts: {
    smoke: ["hutch", "examples/smoke.js"],
    echo: "echo hutch config script",
    "push:canary": "node scripts/tag-release.js canary",
    "push:production": "node scripts/tag-release.js production",
  },
};
