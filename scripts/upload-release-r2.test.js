import assert from "node:assert/strict";
import test from "node:test";

import {
  existingPublishedAt,
  getObject,
  objectExists,
  objectMatches,
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
    arrayBuffer: async () => Buffer.from(body),
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
        if (options.method === "GET") return response(200, "different manifest");
        request = { url, options };
        return response(412, "PreconditionFailed");
      },
    }),
    /immutable object already exists; refusing to overwrite/,
  );

  assert.equal(request.options.headers["If-None-Match"], "*");
  assert.match(request.options.headers.Authorization, /SignedHeaders=[^,]*if-none-match/);
});

test("partial release resumes only missing objects after every existing object matches", async () => {
  const objects = ["archive", "checksum", "build-manifest", "release-manifest"]
    .map((key) => ({ key, body: Buffer.from(key) }));
  const events = [];
  await publishObjectPlan({
    immutableObjects: objects,
    mutableObjects: [{ key: "installer" }, { key: "channel" }],
    objectExistsFn: async ({ key }) => {
      events.push(`HEAD ${key}`);
      return key === "archive" || key === "checksum";
    },
    objectMatchesFn: async ({ key }) => {
      events.push(`GET ${key}`);
      return true;
    },
    putObjectFn: async ({ key }, { ifAbsent }) => events.push(`PUT ${key} ${ifAbsent}`),
  });
  assert.deepEqual(events, [
    "HEAD archive", "GET archive", "HEAD checksum", "GET checksum",
    "HEAD build-manifest", "HEAD release-manifest",
    "PUT build-manifest true", "PUT release-manifest true",
    "PUT installer false", "PUT channel false",
  ]);
});

test("a later differing object prevents all writes after missing and matching objects", async () => {
  const checked = [], writes = [];
  await assert.rejects(publishObjectPlan({
    immutableObjects: ["missing", "matching", "conflicting", "last"].map((key) => ({ key })),
    mutableObjects: [{ key: "channel" }],
    objectExistsFn: async ({ key }) => { checked.push(key); return key !== "missing"; },
    objectMatchesFn: async ({ key }) => key !== "conflicting",
    putObjectFn: async ({ key }) => writes.push(key),
  }), /refusing to overwrite: conflicting/);
  assert.deepEqual(checked, ["missing", "matching", "conflicting", "last"]);
  assert.deepEqual(writes, []);
});

test("existing objects are compared by complete bytes using a signed GET", async () => {
  for (const [body, matches] of [["same", true], ["sAme", false], ["same-extra", false]]) {
    const actual = await objectMatches(config, { key: "archive", body: Buffer.from("same") }, {
      fetchImpl: async (url, options) => {
        assert.equal(options.method, "GET");
        assert.equal(options.body, undefined);
        assert.match(options.headers.Authorization, /SignedHeaders=host;x-amz-content-sha256;x-amz-date/);
        return response(200, body);
      },
    });
    assert.equal(actual, matches);
  }
  assert.equal(await objectMatches(config, { key: "missing", body: Buffer.from("same") }, {
    fetchImpl: async () => response(404),
  }), false);
});

test("transient network, HTTP500 and HTTP429 errors retry with bounded backoff", async () => {
  let requests = 0;
  const waits = [];
  const signals = [];
  const body = await getObject(config, "archive", {
    fetchImpl: async (url, options) => {
      signals.push(options.signal);
      requests++;
      if (requests === 1) throw new TypeError("connection reset");
      return response(requests === 2 ? 500 : requests === 3 ? 429 : 200, "complete");
    },
    sleepImpl: async (ms) => waits.push(ms), log: () => {},
  });
  assert.equal(body.toString(), "complete");
  assert.deepEqual(waits, [500, 1000, 2000]);
  assert.equal(new Set(signals).size, 4);
  assert.ok(signals.every((signal) => signal instanceof AbortSignal));
});

test("a broken response body is retried and cannot count as matching content", async () => {
  let requests = 0;
  assert.equal(await objectMatches(config, { key: "archive", body: Buffer.from("complete") }, {
    fetchImpl: async () => {
      requests++;
      if (requests === 1) return { ...response(200), arrayBuffer: async () => { throw new TypeError("body reset"); } };
      return response(200, "complete");
    },
    sleepImpl: async () => {}, log: () => {},
  }), true);
  assert.equal(requests, 2);
});

test("persistent transient errors stop after four attempts and auth errors are not retried", async () => {
  for (const [status, expectedRequests] of [[503, 4], [401, 1], [403, 1]]) {
    let requests = 0;
    await assert.rejects(getObject(config, "archive", {
      fetchImpl: async () => { requests++; return response(status, "failed"); },
      sleepImpl: async () => {}, log: () => {},
    }), new RegExp(String(status)));
    assert.equal(requests, expectedRequests);
  }
});

test("every network attempt has a finite timeout", async () => {
  let requests = 0;
  await assert.rejects(getObject(config, "archive", {
    timeoutMs: 2,
    fetchImpl: async (url, { signal }) => {
      requests++;
      return new Promise((resolve, reject) => {
        const watchdog = setTimeout(() => reject(new Error("request was not aborted")), 1000);
        signal.addEventListener("abort", () => { clearTimeout(watchdog); reject(signal.reason); }, { once: true });
      });
    },
    sleepImpl: async () => {}, log: () => {},
  }), (error) => error.name === "TimeoutError");
  assert.equal(requests, 4);
});

test("an uncertain conditional PUT success is accepted only after an exact GET match", async () => {
  for (const matches of [true, false]) {
    const requests = [];
    const operation = putObject(config, { key: "archive", body: Buffer.from("complete") }, {
      ifAbsent: true,
      fetchImpl: async (url, options) => {
        requests.push(options.method);
        if (options.method === "GET") return response(200, matches ? "complete" : "conflict");
        assert.equal(options.headers["If-None-Match"], "*");
        return response(requests.length === 1 ? 500 : 412);
      },
      sleepImpl: async () => {}, log: () => {},
    });
    if (matches) await operation;
    else await assert.rejects(operation, /refusing to overwrite/);
    assert.deepEqual(requests, ["PUT", "PUT", "GET"]);
  }
});

test("resuming after an immutable manifest upload preserves its original timestamp", async () => {
  const stamp = "2026-11-04T21:00:00.000Z";
  for (const bodies of [[null, null], [{ publishedAt: stamp }, null], [null, { publishedAt: stamp }],
    [{ publishedAt: stamp }, { publishedAt: stamp }]]) {
    let index = 0;
    const actual = await existingPublishedAt(config, ["build", "release"], {
      fetchImpl: async () => {
        const body = bodies[index++];
        return body === null ? response(404) : response(200, JSON.stringify(body));
      },
    });
    assert.equal(actual, bodies.every((body) => body === null) ? undefined : stamp);
  }
});

test("malformed or conflicting immutable timestamps fail before a resume plan is made", async () => {
  for (const bodies of [
    [{ publishedAt: "bad" }], [{}],
    [{ publishedAt: "2026-11-04T21:00:00.000Z" }, { publishedAt: "2026-11-04T22:00:00.000Z" }],
  ]) {
    let index = 0;
    await assert.rejects(existingPublishedAt(config, bodies.map((_, i) => String(i)), {
      fetchImpl: async () => response(200, JSON.stringify(bodies[index++])),
    }), /publishedAt/);
  }
});
