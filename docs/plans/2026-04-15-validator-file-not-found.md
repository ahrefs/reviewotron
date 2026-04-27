# Validator File-Not-Found Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the validator agent rejecting legitimate findings when `get_file_content` returns not-found for files visible in the diff.

**Architecture:** Prompt-only fix in `validator_agent.ml`. Add guidance to the Tool Usage section explaining that files in the diff may not be fetchable (new files, synthetic test corpus, PR branch not merged yet) and that the diff itself is the primary evidence source. The validator should only use `get_file_content` for files NOT in the diff (e.g., tracing a flow into an imported module).

**Tech Stack:** OCaml, string literal edit in `lib/validator_agent.ml`

---

### Task 1: Update the validator prompt

**Files:**
- Modify: `lib/validator_agent.ml:55-63` (the `## Tool Usage` section of `system_prompt`)

**Step 1: Edit the Tool Usage section**

In `lib/validator_agent.ml`, in the `system_prompt` string, find the `## Tool Usage` section (lines 55-63) and add a paragraph after the existing bullet list but before "Do NOT use the tool..." that reads:

```
**Important**: `get_file_content` fetches files from the repository's default branch. It may return empty or not-found for files that exist only in the PR branch (new files, renamed files) or for files in the diff that haven't been merged yet. **The diff provided to you IS the primary source of truth.** If a finding references a file and line that are visible in the diff, the diff content is sufficient evidence — do not reject a finding solely because `get_file_content` could not fetch the file. Only use the tool for files NOT visible in the diff (e.g., to check an imported module's implementation or verify framework-level sanitization).
```

**Step 2: Build and run quick tests**

Run: `make clean build && dune runtest`
Expected: 137 tests pass (prompt change doesn't affect unit tests)

**Step 3: Run the two previously-failing corpus tests**

Run from `_build/default/test`:
```
ANTHROPIC_API_KEY=... ./test_security_corpus.exe test -e "corpus_pipeline" 5,8
```
Expected: Both `command_injection/exec_user_input` and `authz/missing_ownership_check` pass.

**Step 4: Commit**

```bash
git add lib/validator_agent.ml
git commit -m "fix: validator prompt — don't reject findings when get_file_content returns not-found for diff files"
```
