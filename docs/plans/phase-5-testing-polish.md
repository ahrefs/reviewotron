# Phase 5: Testing Polish

## Goal
Build test helper infrastructure that reduces boilerplate, expand the test suite to cover edge cases, and ensure all golden file tests are auto-promotable. At the end of this phase, we have a comprehensive, maintainable test suite.

## Prerequisites
- Phase 4 complete and passing QA
- Read `.cursor/rules/backend-developer.mdc` for code style
- Use serena to study monorobot's `test/test.ml` for golden file patterns

## Tasks

### 5.1 Implement `test_helpers.ml`

Builder functions that eliminate boilerplate when creating test payloads and contexts:

```ocaml
(** Create a test context with default config and mock secrets *)
val make_test_context :
  ?config:Config_t.config ->
  ?state_filepath:string ->
  ?repo_url:string ->
  unit -> Context.t

(** Build a PR webhook payload JSON string with sensible defaults *)
val make_pr_payload :
  ?action:string ->
  ?number:int ->
  ?title:string ->
  ?body:string ->
  ?author:string ->
  ?head_sha:string ->
  ?base_ref:string ->
  ?repo_name:string ->
  ?repo_url:string ->
  ?additions:int ->
  ?deletions:int ->
  ?changed_files:int ->
  unit -> string

(** Build a push webhook payload JSON string with sensible defaults *)
val make_push_payload :
  ?ref_:string ->
  ?before:string ->
  ?after:string ->
  ?commits:Github_types_t.commit list ->
  ?pusher_name:string ->
  ?repo_name:string ->
  ?repo_url:string ->
  unit -> string

(** Read a mock payload file from the test directory *)
val read_mock_payload : string -> string

(** Read a mock API response file *)
val read_mock_response : string -> string

(** Assert that actual output matches golden file. If GOLDEN_UPDATE=1, update the file. *)
val assert_golden :
  expected:string ->
  actual:string ->
  unit

(** Register a standard test case from a payload file *)
val test_of_payload :
  name:string ->
  event_type:string ->
  payload_file:string ->
  ?mock_dir:string ->
  expected_file:string ->
  unit test_case
```

**Key design decisions:**
- All builders use labeled optional arguments with sensible defaults (per backend-developer.mdc)
- `assert_golden` compares with `expected/` files and supports auto-promotion via dune's `(diff ...)` rule
- Default test context has mock secrets with a dummy API key and a test repo config

### 5.2 Set up dune auto-promotable golden tests

In `test/dune`, configure diff-based golden file testing:

```lisp
(test
 (name test)
 (libraries reviewotron_lib alcotest lwt lwt.unix)
 (deps
  (glob_files mock_payloads/*.json)
  (glob_files mock_api_responses/**/*.json)
  (glob_files mock_api_responses/**/*.diff)
  (glob_files expected/*.json)
  (glob_files mock_states/*.json)))

;; For each golden file test, add a rule like:
(rule
 (alias runtest)
 (action
  (diff expected/pr_opened_review.json actual/pr_opened_review.json)))
```

This allows `dune runtest --auto-promote` to update expected files when output changes intentionally.

### 5.3 Refactor existing tests to use helpers

Update all tests from Phases 1-4 to use `test_helpers.ml`:

**Before:**
```ocaml
let test_pr_opened () =
  let secrets = { repos = [{ url = "https://..."; gh_token = "..."; ... }]; ... } in
  let config = Config_j.config_of_string (read_file "test_config.json") in
  let state = State.create () in
  let ctx = { secrets; config; state } in
  let payload = read_file "mock_payloads/pr_opened.json" in
  ...
```

**After:**
```ocaml
let test_pr_opened () =
  let ctx = Test_helpers.make_test_context () in
  let event = Github.parse_event ~event_type:"pull_request"
    ~body:(Test_helpers.read_mock_payload "pr_opened.json") |> Result.get_ok in
  let%lwt () = R_test.process_event ctx ~event in
  Test_helpers.assert_golden
    ~expected:"expected/pr_opened_review.json"
    ~actual:(Api_local.Github_local.get_posted_reviews_json ())
```

### 5.4 Add edge case tests

Create additional test cases for:

| Test | Payload | Expected Behavior |
|------|---------|-------------------|
| PR with no code changes | Only .md files modified | Review posted (unless .md is in ignored_paths) |
| Very large PR | Over max_diff_lines | Skipped, no review posted |
| PR with too many files | Over max_files | Skipped, no review posted |
| PR from ignored author | dependabot | Skipped |
| PR with all ignored paths | Only vendor/* files | Skipped |
| Push with create=true | New branch push | Skipped (only review develop) |
| Push with deleted=true | Branch deletion | Skipped |
| Push to non-develop branch | feature/xyz | Skipped |
| PR synchronize event | Updated PR | Review posted on new SHA |
| Duplicate PR same SHA | Same PR+SHA twice | Second skipped |
| Claude returns empty findings | Clean code | Review posted with "looks good" summary |
| Claude returns only praise | Good code | Review posted, only positive comments |
| Invalid webhook signature | Bad HMAC | Rejected with 400 |
| Missing event header | No X-Github-Event | Rejected with 400 |

### 5.5 Create mock payloads for edge cases

For each edge case test above, create the necessary:
- `mock_payloads/{test_name}.json`
- `mock_api_responses/github/{test_name}_*.json` or `.diff`
- `mock_api_responses/claude/{test_name}_response.json` (if Claude is called)
- `expected/{test_name}.json`

**Use `test_helpers.make_pr_payload`** for programmatic payload generation where possible, reserving file-based payloads for complex cases.

### 5.6 Add diff parser edge case tests

Expand `test_diff_parser.ml`:

1. **Empty diff** → empty list
2. **Binary file** → skipped in parsing
3. **Renamed file** → old_path populated
4. **New file (no --- line)** → handled correctly
5. **Deleted file (no +++ line)** → handled correctly
6. **File with no hunks** → permission change only, skipped
7. **Very long hunk** → position mapping works for position > 100
8. **Multiple hunks with gaps** → positions are continuous
9. **Unicode in diff** → handled correctly
10. **Diff with "No newline at end of file"** → handled

### 5.7 Add review_prompt unit tests

Test prompt construction:
1. Default system prompt is well-formed
2. Override system prompt replaces default
3. User message includes diff and PR description
4. User message handles missing PR description gracefully
5. Token estimation is roughly accurate (within 2x)

### 5.8 Verify all tests pass

Run the full test suite and ensure:
- All golden file tests pass
- All unit tests pass
- `dune runtest --auto-promote` works correctly
- No flaky tests (run 3 times)

## Verification

1. `dune build` compiles
2. `dune runtest` — all tests pass (0 failures)
3. `dune runtest --auto-promote` — correctly updates golden files
4. Run tests 3 times to verify no flakiness
5. Code coverage: all major code paths have at least one test

## QA Checklist
- [ ] Test helpers use labeled arguments with sensible defaults
- [ ] All golden files are auto-promotable via dune diff rules
- [ ] Edge cases cover all skip conditions (size, author, paths, branch)
- [ ] Diff parser handles all standard git diff formats
- [ ] No test depends on external state or network
- [ ] Test names are descriptive and follow a consistent pattern
- [ ] Mock data is realistic (based on actual GitHub payloads)
