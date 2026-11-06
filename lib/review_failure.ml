type t =
  | Diff_too_large_remote of string
  | Fetch_failed of string
  | Invalid_target of string
  | No_reviewable_files
  | Too_many_lines of {
      actual : int;
      limit : int;
    }
  | Too_many_files of {
      actual : int;
      limit : int;
    }
  | Publish_failed of string

let classify_fetch_error (error : Http_util.error) =
  (* GitHub answers the diff media type with HTTP 406 when the diff is too
     large to serve.  Branch on the structured status code rather than parsing
     the error text. *)
  match error with
  | Http_util.Status (406, _) -> Diff_too_large_remote (Http_util.error_to_string error)
  | Http_util.Status _ | Http_util.Transport _ | Http_util.Local _ -> Fetch_failed (Http_util.error_to_string error)

let prefix = ":robot: **reviewotron** couldn't review this PR."

(** A failure body that quotes the raw error in an open [<details>] block. *)
let with_details ~explanation detail =
  Printf.sprintf "%s\n\n%s\n\n<details open><summary>Details</summary>\n\n```\n%s\n```\n\n</details>" prefix explanation
    detail

let to_comment = function
  | Diff_too_large_remote detail ->
    with_details detail
      ~explanation:
        "The diff is too large for the GitHub API to serve, so I couldn't fetch it. Split this into smaller PRs to get \
         a review."
  | Fetch_failed detail -> with_details detail ~explanation:"I couldn't fetch the diff from GitHub."
  | Invalid_target detail ->
    Printf.sprintf "%s\n\nI couldn't select the requested commit for this PR.\n\n%s" prefix detail
  | No_reviewable_files ->
    Printf.sprintf
      ":robot: **reviewotron** skipped this review.\n\n\
       The path, file-regex, and generated-file filters excluded every changed file, so nothing was reviewed or \
       approved."
  | Too_many_lines { actual; limit } ->
    Printf.sprintf
      "%s\n\n\
       The diff has %d lines, over the limit of %d. Split this into smaller PRs, or raise `max_diff_lines` in the repo \
       config."
      prefix actual limit
  | Too_many_files { actual; limit } ->
    Printf.sprintf
      "%s\n\n\
       The diff touches %d files, over the limit of %d. Split this into smaller PRs, or raise `max_files` in the repo \
       config."
      prefix actual limit
  | Publish_failed detail ->
    with_details detail
      ~explanation:
        "GitHub rejected the review I tried to post. Re-trigger the review. If it fails again, check the service logs."
