#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { appendFileSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { RELEASE_PLATFORMS, validateReleaseTag, validateRevision } from "./release-contract.js";

export function validateCoordinates({ repository, releaseTag, buildRunId }) {
  for (const value of [repository, releaseTag, buildRunId]) {
    assert.ok(typeof value === "string" && !/\s/.test(value), "release coordinates must be nonempty strings without whitespace");
  }
  assert.match(repository, /^[A-Za-z0-9][A-Za-z0-9_.-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/, "invalid repository");
  assert.match(buildRunId ?? "", /^[1-9][0-9]*$/, "invalid build run ID");
  assert.ok(Number.isSafeInteger(Number(buildRunId)), "build run ID exceeds integer range");
  assert.ok(typeof releaseTag === "string" && releaseTag.startsWith("v"), "invalid release tag");
  validateReleaseTag(releaseTag, releaseTag.slice(1));
}

export function validatePublicationSource({ repository, releaseTag, buildRunId, version, revision, run, jobs, artifacts }) {
  validateCoordinates({ repository, releaseTag, buildRunId });
  validateReleaseTag(releaseTag, version);
  validateRevision(revision);
  assert.equal(run.id, Number(buildRunId), "wrong source run");
  assert.equal(run.repository?.full_name, repository, "source run belongs to another repository");
  assert.equal(run.head_repository?.full_name, repository, "source run came from another repository");
  assert.ok(Number.isSafeInteger(run.repository?.id), "source repository ID is missing");
  assert.equal(run.event, "push", "source run must be a tag push");
  assert.equal(run.path, ".github/workflows/release.yml", "source run must use release.yml");
  assert.equal(run.head_branch, releaseTag, "source run must be for the requested tag");
  assert.equal(run.head_sha, revision, "source run does not match the immutable tag checkout");
  assert.equal(run.status, "completed", "source run must have finished");

  // Rerunning only publication may leave successful build jobs on an earlier
  // attempt. The API must include filter=all; inspect the newest job per name.
  for (const name of ["Validate release", ...RELEASE_PLATFORMS.map(platform => `Build ${platform}`)]) {
    const candidates = jobs.filter(job => job.name === name).sort((a, b) =>
      (b.run_attempt - a.run_attempt) || (b.id - a.id));
    const job = candidates[0];
    assert.ok(job, `missing successful job: ${name}`);
    assert.equal(job.head_sha, revision, `${name} used a different source revision`);
    assert.equal(job.status, "completed", `${name} has not completed`);
    assert.equal(job.conclusion, "success", `${name} did not succeed on its latest attempt`);
  }

  const artifactIds = RELEASE_PLATFORMS.map(platform => {
    const name = `hutch-release-${platform}`;
    const matches = artifacts.filter(artifact => artifact.name === name);
    assert.equal(matches.length, 1, `expected exactly one artifact: ${name}`);
    const artifact = matches[0];
    assert.equal(artifact.expired, false, `${name} has expired`);
    assert.ok(Number.isSafeInteger(artifact.id) && artifact.id > 0, `${name} has invalid ID`);
    assert.ok(Number.isSafeInteger(artifact.size_in_bytes) && artifact.size_in_bytes > 0, `${name} is empty`);
    assert.equal(artifact.workflow_run?.id, Number(buildRunId), `${name} belongs to another run`);
    assert.equal(artifact.workflow_run?.head_sha, revision, `${name} used a different source revision`);
    assert.equal(artifact.workflow_run?.repository_id, run.repository.id, `${name} belongs to another repository`);
    assert.equal(artifact.workflow_run?.head_repository_id, run.repository.id, `${name} came from another repository`);
    return artifact.id;
  });
  assert.equal(new Set(artifactIds).size, RELEASE_PLATFORMS.length, "duplicate artifact IDs");
  return { source_sha: revision, release_tag: releaseTag, build_run_id: buildRunId, artifact_ids: artifactIds.join(",") };
}

async function githubJson(path, token) {
  const response = await fetch(`https://api.github.com/${path}`, {
    headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" },
    signal: AbortSignal.timeout(30_000),
  });
  assert.ok(response.ok, `GitHub ${path}: HTTP ${response.status}`);
  return response.json();
}

async function listPages(path, field, token) {
  const items = [];
  for (let page = 1; page <= 100; page += 1) {
    const document = await githubJson(`${path}${path.includes("?") ? "&" : "?"}per_page=100&page=${page}`, token);
    assert.ok(Array.isArray(document[field]), `GitHub response is missing ${field}`);
    items.push(...document[field]);
    if (document[field].length < 100) return items;
  }
  throw new Error(`Too many GitHub ${field} pages`);
}

export async function main(environment = process.env) {
  const coordinates = { repository: environment.GITHUB_REPOSITORY, releaseTag: environment.RELEASE_TAG, buildRunId: environment.BUILD_RUN_ID };
  validateCoordinates(coordinates);
  assert.ok(environment.GITHUB_TOKEN, "GITHUB_TOKEN is required for source verification");
  assert.ok(environment.RELEASE_SOURCE_DIR, "RELEASE_SOURCE_DIR is required");
  const source = resolve(environment.RELEASE_SOURCE_DIR);
  const git = (...args) => execFileSync("git", args, { cwd: source, encoding: "utf8" }).trim();
  const revision = git("rev-parse", "--verify", `refs/tags/${coordinates.releaseTag}^{commit}`);
  assert.equal(git("rev-parse", "HEAD"), revision, "checkout is not at the requested release tag");
  assert.equal(git("status", "--porcelain"), "", "tag checkout must be clean before recovery");
  const { version } = JSON.parse(readFileSync(join(source, "package.json"), "utf8"));
  validateReleaseTag(coordinates.releaseTag, version);
  const path = `repos/${coordinates.repository}/actions/runs/${coordinates.buildRunId}`;
  const [run, jobs, artifacts] = await Promise.all([
    githubJson(path, environment.GITHUB_TOKEN),
    listPages(`${path}/jobs?filter=all`, "jobs", environment.GITHUB_TOKEN),
    listPages(`${path}/artifacts`, "artifacts", environment.GITHUB_TOKEN),
  ]);
  const outputs = validatePublicationSource({ ...coordinates, version, revision, run, jobs, artifacts });
  if (environment.GITHUB_OUTPUT) appendFileSync(environment.GITHUB_OUTPUT, Object.entries(outputs).map(([key, value]) => `${key}=${value}\n`).join(""));
  console.log(JSON.stringify(outputs, null, 2));
  return outputs;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
