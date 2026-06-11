open Reviewotron_lib

let test_repo_url = "https://github.com/org/monorepo"

(** Shared config fixture for tests that exercise the automatic-review code
    paths.  All four [auto_review_*] / [review_pushes_to_develop] flags are
    set to [true], because the production defaults flipped to [false] and a
    test that constructs a default config silently skips every review.

    Tests that assert on skip-reasons {e other than} "auto-review disabled"
    (draft, closed, ignored author, etc.) should use this fixture so the
    skip they care about is the one actually under test. *)
let auto_review_enabled_config =
  Config_types.config_of_json
    (Melange_json.of_string
       {|{"auto_review_pr_open": true, "auto_review_pr_sync": true, "review_pushes_to_develop": true}|})

(** Create a test context with default config and mock secrets.
    Pre-populates the repo config cache so tests don't need to fetch from GitHub. *)
let make_test_context ?state ?(config = Config_types.config_of_json (Melange_json.of_string "{}")) () =
  let secrets : Config_types.secrets =
    {
      repos = [ { url = test_repo_url; auth = Some (GH_token "test-token"); gh_hook_secret = None } ];
      anthropic_api_key = "sk-test";
      slack_access_token = None;
    }
  in
  let ctx = Context.make ~secrets ?state () in
  Context.set_config ctx ~repo_key:test_repo_url config;
  ctx

(** Reset all mock state between tests. *)
let reset_test_state () =
  Api_local.clear_write_log ();
  Api_local.clear_slack_messages ();
  Api_local.reset_agent_response_path ();
  Api_local.clear_agent_response_map ();
  Api_local.reset_reactions ()

(** Build a minimal repository JSON object. *)
let repo_json ?(name = "monorepo") ?(full_name = "org/monorepo") ?(url = "https://github.com/org/monorepo") () =
  Printf.sprintf
    {|{
    "name": %S,
    "full_name": %S,
    "html_url": %S,
    "commits_url": "%s/commits{/sha}",
    "contents_url": "%s/contents/{+path}",
    "pulls_url": "%s/pulls{/number}",
    "issues_url": "%s/issues{/number}",
    "compare_url": "%s/compare/{base}...{head}"
  }|}
    name full_name url url url url url url

(** Build a minimal github_user JSON object. *)
let user_json ?(login = "developer1") ?(id = 12345) () =
  Printf.sprintf
    {|{
    "login": %S,
    "id": %d,
    "url": "https://api.github.com/users/%s",
    "html_url": "https://github.com/%s",
    "avatar_url": "https://avatars.githubusercontent.com/u/%d?v=4"
  }|}
    login id login login id

(** Build a PR branch JSON object. *)
let branch_json ?(sha = "abc123def456789012345678901234567890abcd") ?(ref_ = "feature/test")
  ?(label = "org:feature/test") () =
  Printf.sprintf
    {|{
    "sha": %S,
    "ref": %S,
    "label": %S,
    "repo": %s,
    "user": %s
  }|}
    sha ref_ label (repo_json ()) (user_json ())

(** Build a PR webhook payload JSON string with sensible defaults. *)
let make_pr_payload ?(action = "opened") ?(number = 42) ?(title = "Add feature X to the dashboard")
  ?(body = "Test PR description") ?(author = "developer1") ?(head_sha = "abc123def456789012345678901234567890abcd")
  ?(base_ref = "develop") ?(draft = false) ?(additions = 150) ?(deletions = 30) ?(changed_files = 5) () =
  Printf.sprintf
    {|{
  "action": %S,
  "number": %d,
  "pull_request": {
    "number": %d,
    "title": %S,
    "body": %S,
    "html_url": "https://github.com/org/monorepo/pull/%d",
    "diff_url": "https://github.com/org/monorepo/pull/%d.diff",
    "state": "open",
    "draft": %s,
    "merged": false,
    "labels": [],
    "comments": 0,
    "user": %s,
    "head": %s,
    "base": %s,
    "additions": %d,
    "deletions": %d,
    "changed_files": %d
  },
  "repository": %s,
  "sender": %s
}|}
    action number number title body number number
    (if draft then "true" else "false")
    (user_json ~login:author ())
    (branch_json ~sha:head_sha ~ref_:"feature/test" ~label:"org:feature/test" ())
    (branch_json ~sha:"def456789012345678901234567890abcdef1234" ~ref_:base_ref
       ~label:(Printf.sprintf "org:%s" base_ref) ())
    additions deletions changed_files (repo_json ()) (user_json ~login:author ())

(** Build a push webhook payload JSON string with sensible defaults. *)
let make_push_payload ?(ref_ = "refs/heads/develop") ?(before = "fb245e2a6d52d10025c8bd4f36f6e3134d85ae18")
  ?(after = "e2173f38ae43865433a182c1fc1b5442d9763b54") ?(created = false) ?(deleted = false)
  ?(pusher_name = "developer2") ?(sender_login = "developer2") () =
  let commit_json =
    Printf.sprintf
      {|{
      "id": %S,
      "distinct": true,
      "message": "Test commit message",
      "timestamp": "2026-03-20T14:30:00+00:00",
      "url": "https://github.com/org/monorepo/commit/%s",
      "author": {"name": "Test Dev", "email": "test@example.com", "username": "testdev"},
      "committer": {"name": "Test Dev", "email": "test@example.com", "username": "testdev"},
      "added": [],
      "removed": [],
      "modified": ["test.ml"]
    }|}
      after after
  in
  Printf.sprintf
    {|{
  "ref": %S,
  "before": %S,
  "after": %S,
  "base_ref": null,
  "created": %s,
  "deleted": %s,
  "forced": false,
  "commits": [%s],
  "head_commit": %s,
  "repository": %s,
  "compare": "https://github.com/org/monorepo/compare/%s...%s",
  "pusher": {"name": %S, "email": "test@example.com"},
  "sender": %s
}|}
    ref_ before after
    (if created then "true" else "false")
    (if deleted then "true" else "false")
    commit_json commit_json (repo_json ()) before after pusher_name (user_json ~login:sender_login ())

(** Build an [issue_comment] webhook payload with sensible defaults.

    Defaults model a [REVIEW] comment posted by [reviewer1] on PR #42 of the
    test repo.  Override [is_pr] to [false] to model a comment on a regular
    issue (the [pull_request] sub-field becomes [null]).  Override [state],
    [action], [body], or [sender_login] to construct the various skip-reason
    test cases. *)
let make_issue_comment_payload ?(action = "created") ?(number = 42) ?(title = "Add feature X to the dashboard")
  ?(state = "open") ?(is_pr = true) ?(body = "REVIEW") ?(sender_login = "reviewer1") ?(sender_id = 99999) () =
  let pr_marker =
    if is_pr then
      Printf.sprintf
        {|{"url": "https://api.github.com/repos/org/monorepo/pulls/%d", "html_url": "https://github.com/org/monorepo/pull/%d", "diff_url": "https://github.com/org/monorepo/pull/%d.diff", "patch_url": "https://github.com/org/monorepo/pull/%d.patch", "merged_at": null}|}
        number number number number
    else "null"
  in
  Printf.sprintf
    {|{
  "action": %S,
  "issue": {
    "number": %d,
    "title": %S,
    "state": %S,
    "html_url": "https://github.com/org/monorepo/issues/%d",
    "user": %s,
    "pull_request": %s
  },
  "comment": {
    "id": 9001,
    "body": %S,
    "html_url": "https://github.com/org/monorepo/issues/%d#issuecomment-9001",
    "user": %s
  },
  "repository": %s,
  "sender": %s
}|}
    action number title state number (user_json ~login:"developer1" ()) pr_marker body number
    (user_json ~login:sender_login ~id:sender_id ())
    (repo_json ())
    (user_json ~login:sender_login ~id:sender_id ())

(** Parse a webhook event, failing with a clear message on error. *)
let parse_event_exn ~event_type ~body =
  match Github.parse_event ~event_type ~body with
  | Ok ev -> ev
  | Error msg -> Alcotest.fail (Printf.sprintf "failed to parse %s event: %s" event_type msg)
