import assert from "node:assert/strict";
import test from "node:test";
import { RELEASE_PLATFORMS } from "./release-contract.js";
import { validateCoordinates, validatePublicationSource } from "./resume-release-publication.js";

function fixture() {
  const revision = "a".repeat(40);
  return {
    repository: "blackboardsh/hutch", releaseTag: "v0.29.0", buildRunId: "123", version: "0.29.0", revision,
    run: { id: 123, repository: { full_name: "blackboardsh/hutch", id: 456 }, head_repository: { full_name: "blackboardsh/hutch" }, event: "push", path: ".github/workflows/release.yml", head_branch: "v0.29.0", head_sha: revision, status: "completed", conclusion: "failure", run_attempt: 2 },
    jobs: ["Validate release", ...RELEASE_PLATFORMS.map(platform => `Build ${platform}`)].map((name, index) => ({ id: index + 1, name, head_sha: revision, status: "completed", conclusion: "success", run_attempt: 1 })),
    artifacts: RELEASE_PLATFORMS.map((platform, index) => ({ id: index + 20, name: `hutch-release-${platform}`, expired: false, size_in_bytes: 100, workflow_run: { id: 123, head_sha: revision, repository_id: 456, head_repository_id: 456 } })),
  };
}

test("a failed publish rerun can reuse the complete successful original build matrix", () => {
  const source = fixture();
  assert.deepEqual(validatePublicationSource(source), {
    source_sha: source.revision, release_tag: "v0.29.0", build_run_id: "123", artifact_ids: "20,21,22,23,24,25",
  });
});

test("publication inputs must be exact release coordinates", () => {
  for (const change of [{ repository: "../hutch" }, { buildRunId: "123?foo=bar" }, { buildRunId: "9007199254740992" }, { releaseTag: "main" }, { releaseTag: "v0.29.0\nINJECTED=value" }]) {
    assert.throws(() => validateCoordinates({ ...fixture(), ...change }));
  }
  assert.throws(() => validatePublicationSource({ ...fixture(), version: "0.29.1" }), /does not match/);
});

test("rejects an unrelated, mutable, or unfinished source run", () => {
  for (const change of [
    { id: 124 }, { repository: { full_name: "someone/hutch", id: 456 } }, { head_repository: { full_name: "someone/hutch" } },
    { event: "workflow_dispatch" }, { event: "pull_request" }, { path: ".github/workflows/other.yml" },
    { head_branch: "main" }, { head_sha: "b".repeat(40) }, { status: "in_progress" },
  ]) {
    const source = fixture(); source.run = { ...source.run, ...change };
    assert.throws(() => validatePublicationSource(source));
  }
});

test("requires all successful matrix jobs at the tagged revision", () => {
  for (const edit of [
    source => source.jobs.pop(),
    source => { source.jobs[1].conclusion = "failure"; },
    source => { source.jobs[1].status = "in_progress"; },
    source => { source.jobs[1].head_sha = "b".repeat(40); },
  ]) {
    const source = fixture(); edit(source);
    assert.throws(() => validatePublicationSource(source));
  }
});

test("uses the latest attempt per build instead of accepting stale successful jobs", () => {
  const source = fixture();
  source.jobs.push({ ...source.jobs[1], id: 100, run_attempt: 2, conclusion: "failure" });
  assert.throws(() => validatePublicationSource(source), /latest attempt/);
  source.jobs.push({ ...source.jobs[1], id: 101, run_attempt: 3 });
  assert.doesNotThrow(() => validatePublicationSource(source));
});

test("requires exactly six live artifacts tied to the source run, repository, and revision", () => {
  for (const edit of [
    source => source.artifacts.pop(),
    source => source.artifacts.push({ ...source.artifacts[0], id: 999 }),
    source => { source.artifacts[0].expired = true; },
    source => { source.artifacts[0].size_in_bytes = 0; },
    source => { source.artifacts[0].id = source.artifacts[1].id; },
    source => { source.artifacts[0].workflow_run.id = 999; },
    source => { source.artifacts[0].workflow_run.head_sha = "b".repeat(40); },
    source => { source.artifacts[0].workflow_run.repository_id = 999; },
    source => { source.artifacts[0].workflow_run.head_repository_id = 999; },
  ]) {
    const source = fixture(); edit(source);
    assert.throws(() => validatePublicationSource(source));
  }
});
