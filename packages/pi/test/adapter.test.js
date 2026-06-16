import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildReviewotronCommand,
  clearConfigSchemaCache,
  formatReviewResult,
  FULL_REVIEW_CONFIG,
  fullReviewConfigForSchema,
  runReviewotron,
} from "../src/adapter.js";
import {
  configHelpRequest,
  fullCommandRequest,
  requestFromToolParams,
  reviewCommandRequest,
} from "../src/extension-core.js";

async function fakeBinary(contents) {
  const dir = await mkdtemp(join(tmpdir(), "reviewotron-pi-"));
  const path = join(dir, "reviewotron");
  await writeFile(path, contents, { mode: 0o755 });
  return path;
}

test("quick worktree diff maps to review-diff with no security state by default", () => {
  const command = buildReviewotronCommand({
    mode: "worktree_diff",
    profile: "quick",
    root: "/repo",
    base: "origin/main",
    title: "Quick review",
  });

  assert.equal(command.bin, "reviewotron");
  assert.deepEqual(command.args, [
    "review-diff",
    "--root",
    "/repo",
    "--base",
    "origin/main",
    "--title",
    "Quick review",
    "--no-security",
    "--output",
    "json",
  ]);
  assert.equal(command.stdin, "");
});

test("full path review raises limits and keeps security enabled", () => {
  const command = buildReviewotronCommand({
    mode: "path",
    profile: "full",
    path: "@src",
  });

  assert.deepEqual(command.args, [
    "review-path",
    "--config",
    JSON.stringify(FULL_REVIEW_CONFIG),
    "--output",
    "json",
    "src",
  ]);
});

test("schema-aware full review config only uses fields advertised by config-help", () => {
  assert.deepEqual(fullReviewConfigForSchema(undefined), FULL_REVIEW_CONFIG);
  assert.deepEqual(
    fullReviewConfigForSchema({
      properties: {
        max_diff_lines: {},
      },
    }),
    { max_diff_lines: FULL_REVIEW_CONFIG.max_diff_lines },
  );
  assert.equal(
    fullReviewConfigForSchema({
      properties: {
        unrelated: {},
      },
    }),
    undefined,
  );

  const command = buildReviewotronCommand(
    {
      mode: "path",
      profile: "full",
      path: "src",
    },
    {
      configSchema: {
        properties: {
          max_diff_lines: {},
        },
      },
    },
  );

  assert.deepEqual(command.args, [
    "review-path",
    "--config",
    JSON.stringify({ max_diff_lines: FULL_REVIEW_CONFIG.max_diff_lines }),
    "--output",
    "json",
    "src",
  ]);
});

test("stdin diff maps to review-diff --diff - and writes stdin", () => {
  const diff = "diff --git a/a.txt b/a.txt\n";
  const command = buildReviewotronCommand({
    mode: "stdin_diff",
    profile: "quick",
    diff,
    root: "/repo",
  });

  assert.deepEqual(command.args, ["review-diff", "--root", "/repo", "--diff", "-", "--no-security", "--output", "json"]);
  assert.equal(command.stdin, diff);
});

test("full review queries config-help once per binary and uses current schema", async () => {
  clearConfigSchemaCache();
  const logPath = join(tmpdir(), `reviewotron-pi-log-${Date.now()}-${Math.random()}`);
  const bin = await fakeBinary(`#!/usr/bin/env node
const fs = require("node:fs");
fs.appendFileSync(${JSON.stringify(logPath)}, JSON.stringify(process.argv.slice(2)) + "\\n");
if (process.argv[2] === "config-help") {
  console.log(JSON.stringify({ properties: { max_diff_lines: {} } }));
} else {
  console.log(JSON.stringify({ schema_version: 1, review_status: "completed", summary: "", findings: [] }));
}
`);

  const first = await runReviewotron({ mode: "path", profile: "full", path: "src", bin });
  const second = await runReviewotron({ mode: "path", profile: "full", path: "src", bin });
  const calls = (await readFile(logPath, "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));

  assert.equal(first.ok, true);
  assert.equal(second.ok, true);
  assert.equal(calls.length, 3);
  assert.deepEqual(calls[0], ["config-help"]);
  assert.deepEqual(calls[1], [
    "review-path",
    "--config",
    JSON.stringify({ max_diff_lines: FULL_REVIEW_CONFIG.max_diff_lines }),
    "--output",
    "json",
    "src",
  ]);
  assert.deepEqual(calls[2], calls[1]);
});

test("explicit config skips config-help discovery", async () => {
  clearConfigSchemaCache();
  const logPath = join(tmpdir(), `reviewotron-pi-explicit-${Date.now()}-${Math.random()}`);
  const explicitConfig = { max_files: 12, custom_future_field: true };
  const bin = await fakeBinary(`#!/usr/bin/env node
const fs = require("node:fs");
fs.appendFileSync(${JSON.stringify(logPath)}, JSON.stringify(process.argv.slice(2)) + "\\n");
if (process.argv[2] === "config-help") {
  console.log(JSON.stringify({ error: "config-help should not run" }));
  process.exit(7);
} else {
  console.log(JSON.stringify({ schema_version: 1, review_status: "completed", summary: "", findings: [] }));
}
`);

  const result = await runReviewotron({
    mode: "path",
    profile: "full",
    path: "src",
    bin,
    config: explicitConfig,
  });
  const calls = (await readFile(logPath, "utf8"))
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));

  assert.equal(result.ok, true);
  assert.deepEqual(calls, [["review-path", "--config", JSON.stringify(explicitConfig), "--output", "json", "src"]]);
});

test("extension command helpers choose expected request profiles", () => {
  assert.deepEqual(reviewCommandRequest(), {
    mode: "worktree_diff",
    profile: "quick",
    title: "Pi quick review",
  });
  assert.deepEqual(fullCommandRequest("app"), {
    mode: "path",
    profile: "full",
    path: "app",
    title: "Pi full review for app",
  });
  assert.deepEqual(configHelpRequest(), {
    mode: "config_help",
    timeoutMs: 30000,
  });
  assert.deepEqual(requestFromToolParams({ path: "lib" }).mode, "path");
});

test("fake reviewotron JSON is normalized", async () => {
  const bin = await fakeBinary(`#!/usr/bin/env node
console.log(JSON.stringify({
  schema_version: 1,
  review_status: "completed",
  reviewed_root: "/repo",
  change_key: "abc",
  summary: "Looks good",
  findings: [{ file: "a.js", line: 2, level: "warning", category: "bug", summary: "Bug", failure_scenario: "Fails" }]
}));
`);

  const result = await runReviewotron({ mode: "worktree_diff", bin });

  assert.equal(result.ok, true);
  assert.equal(result.report.schemaVersion, 1);
  assert.equal(result.report.status, "completed");
  assert.equal(result.report.findings.length, 1);
  assert.match(formatReviewResult(result), /a\.js:2 Bug/);
});

test("malformed JSON is reported", async () => {
  const bin = await fakeBinary(`#!/usr/bin/env node
console.log("not json");
`);

  const result = await runReviewotron({ mode: "worktree_diff", bin });

  assert.equal(result.ok, false);
  assert.equal(result.kind, "malformed_json");
  assert.match(result.error, /valid JSON/);
});

test("non-zero JSON error is reported", async () => {
  const bin = await fakeBinary(`#!/usr/bin/env node
console.log(JSON.stringify({ error: "bad path" }));
process.exit(2);
`);

  const result = await runReviewotron({ mode: "path", path: "missing", bin });

  assert.equal(result.ok, false);
  assert.equal(result.kind, "reviewotron_error");
  assert.equal(result.error, "bad path");
});

test("timeout kills the process and reports timeout", async () => {
  const bin = await fakeBinary(`#!/usr/bin/env node
setTimeout(() => {}, 10000);
`);

  const result = await runReviewotron({ mode: "worktree_diff", bin, timeoutMs: 20 });

  assert.equal(result.ok, false);
  assert.equal(result.kind, "timeout");
});

test("missing binary reports setup guidance", async () => {
  const result = await runReviewotron({ mode: "worktree_diff", bin: "/no/such/reviewotron" });

  assert.equal(result.ok, false);
  assert.equal(result.kind, "missing_binary");
  assert.match(formatReviewResult(result), /REVIEWOTRON_BIN/);
});
