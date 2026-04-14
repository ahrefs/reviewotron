(** Unified diff parser with line-to-position mapping for GitHub's PR review API. *)

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

(** Which side of a diff a line belongs to. *)
type side =
  | Left
  | Right

(** Parse a unified diff string into structured file diffs.
    Splits on [diff --git] boundaries, extracts paths from [--- a/] and [+++ b/],
    and classifies each line as {!Context}, {!Addition}, or {!Deletion}. *)
val parse : string -> t

(** Convert an absolute line number to a diff position for GitHub's API.
    Position 1 is the first [@@] hunk header. Each subsequent line increments
    position by 1. For multi-hunk files, positions are continuous across hunks. *)
val line_to_position : file_diff -> line:int -> side:side -> int option

(** Reverse mapping: diff position to absolute line number and side. *)
val position_to_line : file_diff -> position:int -> (int * side) option

(** Total number of diff lines across all files (hunk headers not counted). *)
val total_lines : t -> int

(** Remove file diffs whose path matches any of the ignored glob patterns. *)
val filter_paths : t -> ignored:string list -> t

(** Reconstruct a unified diff string from parsed file diffs.
    Produces output suitable for sending to code review tools. *)
val to_string : t -> string

(** Rough token estimate for the diff text (~4 chars per token). *)
val estimate_tokens : t -> int
