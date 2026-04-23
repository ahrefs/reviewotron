(** Unified diff parser. *)

(** A single line within a diff hunk. *)
type diff_line =
  | Context of string  (** Line present in both old and new *)
  | Addition of string  (** Line added in new *)
  | Deletion of string  (** Line removed from old *)

(** A contiguous range of changes within a file diff. *)
type hunk = {
  old_start : int;
  old_count : int;
  new_start : int;
  new_count : int;
  lines : diff_line list;
}

(** The status of a file in a diff. *)
type file_status =
  | Added
  | Deleted
  | Modified
  | Renamed

(** The diff for a single file. *)
type file_diff = {
  path : string;
  old_path : string option;
  status : file_status;
  hunks : hunk list;
}

(** A parsed unified diff: a list of per-file diffs. *)
type t = file_diff list

(** Parse a unified diff string into structured file diffs.
    Splits on [diff --git] boundaries, extracts paths from [--- a/] and [+++ b/],
    and classifies each line as {!Context}, {!Addition}, or {!Deletion}. *)
val parse : string -> t

(** Total number of diff lines across all files (hunk headers not counted). *)
val total_lines : t -> int

(** Remove file diffs whose path matches any of the ignored glob patterns. *)
val filter_paths : t -> ignored:string list -> t

(** Reconstruct a unified diff string from parsed file diffs.
    Produces output suitable for sending to code review tools. *)
val to_string : t -> string

(** Rough token estimate for the diff text (~4 chars per token). *)
val estimate_tokens : t -> int
