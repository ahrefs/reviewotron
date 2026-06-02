type t =
  | Diff_too_large_remote of string
  | Fetch_failed of string
  | Too_many_lines of {
      actual : int;
      limit : int;
    }
  | Too_many_files of {
      actual : int;
      limit : int;
    }

(** Markers GitHub uses when it refuses to serve an oversized diff (HTTP 406). *)
module Remote_too_large = struct
  let markers = [ "too_large"; "exceeded the maximum number of files" ]
  let matches msg = List.exists (fun marker -> CCString.mem ~sub:marker msg) markers
end

let classify_fetch_error msg =
  match Remote_too_large.matches msg with
  | true -> Diff_too_large_remote msg
  | false -> Fetch_failed msg

let prefix = ":robot: **reviewotron** couldn't review this PR."

(** A failure body that quotes the raw error in a collapsed [<details>] block. *)
let with_details ~explanation detail =
  Printf.sprintf "%s\n\n%s\n\n<details><summary>Details</summary>\n\n```\n%s\n```\n\n</details>" prefix explanation
    detail

let to_comment = function
  | Diff_too_large_remote detail ->
    with_details detail
      ~explanation:
        "The diff is too large for the GitHub API to serve, so I couldn't fetch the changes to review. Consider \
         splitting this into smaller PRs."
  | Fetch_failed detail -> with_details detail ~explanation:"I couldn't fetch the diff from GitHub."
  | Too_many_lines { actual; limit } ->
    Printf.sprintf
      "%s\n\n\
       The diff is %d lines, which is over reviewotron's limit of %d. Consider splitting this into smaller PRs, or \
       raise `max_diff_lines` in the repo config."
      prefix actual limit
  | Too_many_files { actual; limit } ->
    Printf.sprintf
      "%s\n\n\
       The diff touches %d files, which is over reviewotron's limit of %d. Consider splitting this into smaller PRs, \
       or raise `max_files` in the repo config."
      prefix actual limit
