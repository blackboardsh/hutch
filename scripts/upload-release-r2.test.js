import assert from "node:assert/strict";
import test from "node:test";

import {
  objectExists,
  publishObjectPlan,
  putObject,
} from "./upload-release-r2.js";

const config = {
  accountId: "test-account",
  accessKeyId: "test-access-key",
  secretAccessKey: "test-secret-key",
  bucket: "test-bucket",
};

function response(status, body = "") {
  return {
    status,
    ok: status >= 200 && status < 300,
    text: async () => body,
  };
}

test("immutable release preflight checks every key and performs no writes when one exists", async () => {
  const immutableObjects = ["archive", "checksum", "build-manifest", "release-manifest"]
    .map((key) => ({ key }));
  const checked = [];
  const writes = [];

  await assert.rejects(
    publishObjectPlan({
      immutableObjects,
      mutableObjects: [{ key: "channel" }],
      objectExistsFn: async (object) => {
        checked.push(object.key);
        return object.key === "checksum";
      },
      putObjectFn: async (object) => writes.push(object.key),
    }),
    /refusing to overwrite: checksum/,
  );

  assert.deepEqual(checked, immutableObjects.map(({ key }) => key));
  assert.deepEqual(writes, []);
});

test("immutable objects use conditional writes before mutable pointers", async () => {
  const events = [];
  const immutableObjects = [{ key: "archive" }, { key: "manifest" }];
  const mutableObjects = [{ key: "installer" }, { key: "channel" }];

  await publishObjectPlan({
    immutableObjects,
    mutableObjects,
    objectExistsFn: async (object) => {
      events.push(`HEAD ${object.key}`);
      return false;
    },
    putObjectFn: async (object, { ifAbsent }) => {
      events.push(`PUT ${object.key} ifAbsent=${ifAbsent}`);
    },
  });

  assert.deepEqual(events, [
    "HEAD archive",
    "HEAD manifest",
    "PUT archive ifAbsent=true",
    "PUT manifest ifAbsent=true",
    "PUT installer ifAbsent=false",
    "PUT channel ifAbsent=false",
  ]);
});

test("an immutable write failure prevents mutable pointer writes", async () => {
  const writes = [];

  await assert.rejects(
    publishObjectPlan({
      immutableObjects: [{ key: "archive" }, { key: "manifest" }],
      mutableObjects: [{ key: "channel" }],
      objectExistsFn: async () => false,
      putObjectFn: async (object) => {
        writes.push(object.key);
        if (object.key === "manifest") throw new Error("conditional write lost race");
      },
    }),
    /lost race/,
  );

  assert.deepEqual(writes, ["archive", "manifest"]);
});

test("R2 existence checks use a signed HEAD request", async () => {
  let request;
  const exists = await objectExists(config, "hutch/builds/revision/manifest.json", {
    fetchImpl: async (url, options) => {
      request = { url, options };
      return response(404);
    },
  });

  assert.equal(exists, false);
  assert.equal(request.options.method, "HEAD");
  assert.equal(request.options.body, undefined);
  assert.match(request.url, /^https:\/\/test-account\.r2\.cloudflarestorage\.com\/test-bucket\//);
  assert.match(
    request.options.headers.Authorization,
    /SignedHeaders=host;x-amz-content-sha256;x-amz-date/,
  );
});

test("immutable PUTs are conditional and report a raced object", async () => {
  let request;
  await assert.rejects(
    putObject(config, {
      key: "hutch/releases/1.2.3/manifest.json",
      body: Buffer.from("manifest"),
      contentType: "application/json",
      cacheControl: "immutable",
    }, {
      ifAbsent: true,
      fetchImpl: async (url, options) => {
        request = { url, options };
        return response(412, "PreconditionFailed");
      },
    }),
    /immutable object already exists; refusing to overwrite/,
  );

  assert.equal(request.options.headers["If-None-Match"], "*");
  assert.match(request.options.headers.Authorization, /SignedHeaders=[^,]*if-none-match/);
});
