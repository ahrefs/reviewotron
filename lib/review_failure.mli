(** Why a PR review could not be produced, and how to explain it on the PR.

    These are the cases where reviewotron gives up before posting a review and
    instead leaves the author an issue comment with context: GitHub refused to
    serve the diff (external limit), or the diff is larger than reviewotron's
    own limits (internal limit). *)

type t =
  | Diff_too_large_remote of string
    (** GitHub refused to serve the diff because it is too large (HTTP 406 /
          [too_large]).  Carries the raw error for the comment detail. *)
  | Fetch_failed of string  (** Any other diff-fetch failure.  Carries the raw error. *)
  | Too_many_lines of {
      actual : int;
      limit : int;
    }  (** The filtered diff exceeds [Config_types.max_diff_lines]. *)
  | Too_many_files of {
      actual : int;
      limit : int;
    }  (** The filtered diff touches more files than [Config_types.max_files]. *)

(** Classify a diff-fetch error into [Diff_too_large_remote] (GitHub answered the
    diff media type with HTTP 406, meaning the diff is too large to serve) or
    [Fetch_failed] (any other status or a transport error). *)
val classify_fetch_error : Http_util.error -> t

(** Render a Markdown issue-comment body explaining the failure to the PR author. *)
val to_comment : t -> string
