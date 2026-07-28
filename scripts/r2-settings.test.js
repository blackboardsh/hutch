import assert from "node:assert/strict";
import test from "node:test";

import { accountIdFromEndpoint, r2Setting } from "./r2-settings.js";

test("uses the shared R2 credentials", () => {
  assert.equal(r2Setting("R2_ACCESS_KEY_ID", {
    R2_ACCESS_KEY_ID: "generic",
  }), "generic");
});

test("does not select legacy product-prefixed credentials", () => {
  assert.equal(r2Setting("R2_ACCESS_KEY_ID", {
    HUTCH_R2_ACCESS_KEY_ID: "hutch",
    DASH_CLI_R2_ACCESS_KEY_ID: "dash-cli",
    COTTONTAIL_R2_ACCESS_KEY_ID: "cottontail",
    R2_ACCESS_KEY_ID: "generic",
  }), "generic");
});

test("falls back to generic settings and derives the account ID", () => {
  const endpoint = "https://0123456789abcdef.r2.cloudflarestorage.com";
  assert.equal(accountIdFromEndpoint(endpoint), "0123456789abcdef");
  assert.equal(r2Setting("R2_ACCOUNT_ID", { R2_ENDPOINT: endpoint }), "0123456789abcdef");
  assert.equal(r2Setting("R2_ACCESS_KEY_ID", { R2_ACCESS_KEY_ID: "generic" }), "generic");
});

test("keeps the Hutch public URL independent from R2 API settings", () => {
  assert.equal(r2Setting("R2_PUBLIC_BASE_URL", {}), "https://hutch.blackboard.sh");
  assert.equal(r2Setting("R2_PUBLIC_BASE_URL", {
    HUTCH_PUBLIC_BASE_URL: "https://preview.hutch.example",
    R2_PUBLIC_BASE_URL: "https://dash-data.example",
  }), "https://preview.hutch.example");
});
