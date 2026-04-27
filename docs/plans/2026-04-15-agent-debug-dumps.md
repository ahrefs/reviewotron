# Agent Debug Dumps Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** When structured output parsing fails, write the raw model response to a debug dump file at `debug/{repo_slug}/{commit_sha}/{agent_name}.txt` so failures are diagnosable without bloating the main app log.

**Architecture:** Add `?debug_dir:string` optional parameter to `Agent_runner.run_agent` and `Api.Agent_runner.run`. On parse failure, write step-by-step text to `{debug_dir}/{agent_name}.txt`. The caller (`reviewer.ml`) constructs the debug_dir from repo_url + head_sha. Plugins forward the parameter. A one-line `log#warn` with the dump file path replaces verbose inline logging.

**Tech Stack:** OCaml, `Devkit.Log`, file I/O

---

### Task 1: Add `?debug_dir` to `Agent_runner.run_agent` and write dump on failure

**Files:**
- Modify: `lib/agent_runner.ml` — add `?debug_dir` param, write dump file on parse failure
- Modify: `lib/agent_runner.mli` — add `?debug_dir` to signature

**Step 1: Add the dump-writing logic**

In `agent_runner.ml`, add a helper function `write_debug_dump` that:
- Takes `~debug_dir`, `~agent_name`, `~finish_reason`, `~steps` (the result steps list), `~usage`
- Creates the directory (mkdir -p) if it doesn't exist
- Writes to `{debug_dir}/{agent_name}.txt`
- Content format:
  ```
  Agent: {agent_name}
  Finish reason: {finish_reason}
  Tokens: {input} input, {output} output
  Steps: {count}

  === Step 0 (text={n} chars, tool_calls={m}) ===
  {step text, first 2000 chars}

  === Step 1 ... ===
  ...
  ```
- Catches all exceptions (file I/O failure must not crash the review)

Add `?debug_dir:string` to `run_agent` and to the `.mli`. In the `None` branch of the output match (parse failure), call `write_debug_dump` when `debug_dir` is `Some dir`.

Log a single line: `log#warn "agent %s: parse failed, debug dump at %s" config.name path`

**Step 2: Build and test**

Run: `dune build` — must succeed
Run: `dune runtest` — 146 tests must pass (no callers pass `~debug_dir` yet, so behavior is unchanged)

---

### Task 2: Thread `?debug_dir` through `Api.Agent_runner` and implementations

**Files:**
- Modify: `lib/api.ml` — add `?debug_dir:string` to `Agent_runner.run` signature
- Modify: `lib/api_remote.ml` — accept and forward `?debug_dir`
- Modify: `lib/api_local.ml` — accept and ignore `?debug_dir`

**Step 1: Update the module type and implementations**

In `lib/api.ml`, add `?debug_dir:string ->` to the `run` signature.

In `lib/api_remote.ml` `Agent_runner.run`, accept `?debug_dir` and forward to `Agent_runner.run_agent`.

In `lib/api_local.ml` `Agent_runner.run`, accept `?debug_dir:_` and ignore it (mock doesn't write dumps).

**Step 2: Build and test**

Run: `dune build && dune runtest` — 146 tests pass

---

### Task 3: Construct debug_dir in reviewer.ml and pass through plugins

**Files:**
- Modify: `lib/reviewer.ml` — construct debug_dir, pass to plugin calls
- Modify: `lib/security_review_plugin.ml` — accept and forward debug_dir to AI.run calls
- Modify: `lib/general_review_plugin.ml` — accept and forward debug_dir to AI.run call

**Step 1: Construct debug_dir in reviewer.ml**

In `execute_and_post_review`, before calling `run_plugins`, construct:
```ocaml
let debug_dir =
  let slug = Security_memory.repo_slug repo_url in
  let sha_prefix = String.sub head_sha 0 (min 8 (String.length head_sha)) in
  Printf.sprintf "debug/%s/%s" slug sha_prefix
```

Pass `~debug_dir` to `run_plugins`, which passes it to `General_plugin.run_review` and `Security_plugin.run`.

For `review_push`, use `push.after` instead of `head_sha`.

**Step 2: Update plugin signatures to accept and forward debug_dir**

In `security_review_plugin.ml`:
- Add `?debug_dir` to `run`, `run_triage`, `run_single_analysis`, `run_validator`, `process_memory_queue`
- Forward to each `AI.run` call

In `general_review_plugin.ml`:
- Add `?debug_dir` to `run_review`
- Forward to the `AI.run` call

**Step 3: Build and test**

Run: `dune build && dune runtest` — 146 tests pass
Run: `dune fmt` — apply formatting

---

### Task 4: Add a unit test for dump file creation

**Files:**
- Modify: `test/test.ml` — add test that verifies dump file is written on agent failure

**Step 1: Write the test**

Create a test that:
1. Sets up a temp directory as debug_dir
2. Configures `Api_local.Agent_runner` to return an error (bad mock path)
3. Triggers a PR review with `debug_dir` set
4. Verifies a `.txt` file was created under the debug_dir
5. Verifies the file contains the agent name and "Finish reason"
6. Cleans up the temp directory

Note: Since `Api_local.Agent_runner` returns `Error` before reaching the dump logic (it fails at the mock level, not at parse), we need to test via `Agent_runner.run_agent` directly. Create a test that calls `run_agent` with a model that returns unparseable output — but that requires a real model.

Alternative: test `write_debug_dump` directly as a unit test by extracting it and exposing it in the mli.

Simplest: expose `write_debug_dump` in `agent_runner.mli` and write a unit test that calls it directly, verifying file creation and content.

**Step 2: Build and test**

Run: `dune build && dune runtest` — 147 tests pass

**Step 3: Commit**

```
git add lib/agent_runner.ml lib/agent_runner.mli lib/api.ml lib/api_remote.ml lib/api_local.ml lib/reviewer.ml lib/security_review_plugin.ml lib/general_review_plugin.ml test/test.ml
git commit -m "Add debug dump files for agent structured output parse failures"
```
