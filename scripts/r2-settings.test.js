import assert from "node:assert/strict";
import test from "node:test";

import { accountIdFromEndpoint, r2Setting } from "./r2-settings.js";

test("prefers Hutch artifact credentials", () => {
  assert.equal(r2Setting("R2_ACCESS_KEY_ID", {
    HUTCH_R2_ACCESS_KEY_ID: "hutch",
    DASH_CLI_R2_ACCESS_KEY_ID: "dash-cli",
    COTTONTAIL_R2_ACCESS_KEY_ID: "cottontail",
    R2_ACCESS_KEY_ID: "generic",
  }), "hutch");
});

test("accepts existing artifact credentials before generic deployment credentials", () => {
  assert.equal(r2Setting("R2_ACCESS_KEY_ID", {
    DASH_CLI_R2_ACCESS_KEY_ID: "dash-cli",
    R2_ACCESS_KEY_ID: "generic",
  }), "dash-cli");
  assert.equal(r2Setting("R2_SECRET_ACCESS_KEY", {
    COTTONTAIL_R2_SECRET_ACCESS_KEY: "cottontail",
    R2_SECRET_ACCESS_KEY: "generic",
  }), "cottontail");
});

test("falls back to generic settings and derives the account ID", () => {
  const endpoint = "https://0123456789abcdef.r2.cloudflarestorage.com";
  assert.equal(accountIdFromEndpoint(endpoint), "0123456789abcdef");
  assert.equal(r2Setting("R2_ACCOUNT_ID", { R2_ENDPOINT: endpoint }), "0123456789abcdef");
  assert.equal(r2Setting("R2_ACCESS_KEY_ID", { R2_ACCESS_KEY_ID: "generic" }), "generic");
});

test("defaults the public URL to the Hutch custom domain", () => {
  assert.equal(r2Setting("R2_PUBLIC_BASE_URL", {}), "https://hutch.blackboard.sh");
});
