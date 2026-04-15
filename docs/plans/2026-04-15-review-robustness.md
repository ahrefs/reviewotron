# Review Robustness Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure reviewotron always posts feedback on PRs, even when individual agents or plugins fail. A silent failure is worse than a visible error message — it leaves the developer waiting for a review that will never arrive.

**Architecture:** Modify `reviewer.ml` to decouple the general review plugin from the decision to post a review. When the general plugin fails, post a degraded review containing only security findings (if any) and a visible error notice. When posting fails, retry once. When the security plugin fails, add a note to the review body.

**Tech Stack:** OCaml, `lib/reviewer.ml`, `test/test.ml` (golden-file tests with `Api_local` mocks)

---

### Task 1: Make `execute_and_post_review` resilient to general plugin failure

**Files:**
- Modify: `lib/reviewer.ml` — `execute_and_post_review` function (lines 205-236)

**What to change:**

Currently, when `general_result = None`, the function logs an error and returns without posting anything. Change it to:

1. When `general_result = None` and there ARE security findings: post a review with only the security findings and a body that says the general review failed.
2. When `general_result = None` and there are NO security findings: post a minimal review comment saying the review failed and the user should re-trigger.
3. When `general_result = Some review`: current behavior (no change).

The degraded review body should be something like:
```
⚠️ **Review partially failed** — the general code review agent encountered an error. Security findings (if any) are shown below. You may want to re-trigger the review.
```

Or when both fail with no findings:
```
⚠️ **Review failed** — the code review encountered an error and could not produce results. Please re-trigger the review. If this persists, check the service logs.
```

**Step 1: Write a failing test**

Add a test in `test/test.ml` that configures `Api_local.Agent_runner` to return an error for the general review agent, verifies that `create_pr_review` is still called, and checks the review body contains the failure notice.

**Step 2: Implement the fix**

Refactor `execute_and_post_review` so the `match general_result` no longer gates the entire post path. Extract the review body construction into a helper that handles both `Some review` and `None` cases.

**Step 3: Run tests**

Run `dune runtest` — all existing tests must pass, new test must pass.

**Step 4: Commit**

---

### Task 2: Add security plugin failure notice to review body

**Files:**
- Modify: `lib/reviewer.ml` — `run_plugins` function
- Modify: `lib/reviewer.ml` — `execute_and_post_review` function

**What to change:**

`run_plugins` currently swallows security plugin errors silently (the plugin returns `([], costs)` on failure). Thread a `security_failed: bool` flag through to `execute_and_post_review` so it can append a note like:

```
_Note: The security review plugin encountered an error. Security analysis may be incomplete._
```

**Step 1: Write a failing test**

Mock the security agent to fail, verify the review body contains the security failure note.

**Step 2: Implement**

Add a `security_error` field to the return of `run_plugins`. In `execute_and_post_review`, append the note when set.

**Step 3: Run tests, commit**

---

### Task 3: Retry on GitHub API post failure

**Files:**
- Modify: `lib/reviewer.ml` — the `create_pr_review` call site (line 229)

**What to change:**

When `create_pr_review` returns `Error`, retry once after a 1-second delay. If the retry also fails, log the error (current behavior). This handles transient GitHub API errors (502s, rate limits).

**Step 1: Write a test**

Mock `create_pr_review` to fail on first call, succeed on second. Verify review is posted.

**Step 2: Implement**

Simple retry wrapper around the `create_pr_review` call.

**Step 3: Run tests, commit**
