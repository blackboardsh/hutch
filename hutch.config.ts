// @hutch cli=0.9.1 cottontail=0.4.1
export default {
  scripts: {
    smoke: ["hutch", "examples/smoke.js"],
    echo: "echo hutch config script",
    "push:canary": "node scripts/tag-release.js canary",
    "push:production": "node scripts/tag-release.js production",
  },
};
